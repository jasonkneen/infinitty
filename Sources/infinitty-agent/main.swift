import Darwin
import Foundation

// `infinitty-agent` is the provider-neutral edge for terminal agents. It has
// two deliberately small jobs:
//
//   context --format <plain|json|claude|codex>
//       Read the live, pane-bound Channel context for a hook or plugin.
//   run [options] -- <cli> [args...]
//       Register the CLI against the owning pane, then exec it in-place so
//       the managed registration remains owned by the real CLI PID.
//
// It is intentionally independent of InfinittyKit. Hooks and arbitrary CLIs
// must be able to use it without loading AppKit or a provider SDK.

signal(SIGPIPE, SIG_IGN)

private let defaultTimeoutMilliseconds = 250
private let maximumOutputBytes = 3_500

private enum OutputFormat: String {
    case plain
    case json
    case claude
    case codex
}

private struct AgentLaunchOptions {
    var provider: String?
    var name: String?
    var role: String = "terminal agent"
    var modelID: String?
    var sessionID: String?
    var required = false
    var command: String?
    var arguments: [String] = []
}

private func environmentValue(_ key: String) -> String? {
    let value = ProcessInfo.processInfo.environment[key]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
}

private func paneSocketPath() -> String? {
    environmentValue("INFINITTY_SOCKET")
        ?? environmentValue("TITERM_SOCKET")
}

private func openSocket(path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let valid = withUnsafeMutablePointer(to: &address.sun_path) { tuple -> Bool in
        tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            let bytes = Array(path.utf8)
            guard bytes.count < capacity else { return false }
            for (index, byte) in bytes.enumerated() {
                destination[index] = CChar(bitPattern: byte)
            }
            destination[bytes.count] = 0
            return true
        }
    }
    guard valid else {
        close(fd)
        return -1
    }

    let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, addressLength)
        }
    }
    guard connected == 0 else {
        close(fd)
        return -1
    }
    return fd
}

private func socketRequest(
    _ request: String,
    path: String,
    timeoutMilliseconds: Int = defaultTimeoutMilliseconds
) -> String? {
    guard !path.isEmpty else { return nil }
    let fd = openSocket(path: path)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    let milliseconds = max(timeoutMilliseconds, 1)
    var readTimeout = timeval(
        tv_sec: time_t(milliseconds / 1_000),
        tv_usec: Int32((milliseconds % 1_000) * 1_000))
    var writeTimeout = readTimeout
    setsockopt(
        fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout,
        socklen_t(MemoryLayout<timeval>.size))
    setsockopt(
        fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout,
        socklen_t(MemoryLayout<timeval>.size))

    let bytes = Array((request + "\n").utf8)
    let didWrite = bytes.withUnsafeBufferPointer { buffer -> Bool in
        guard let base = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let count = write(fd, base.advanced(by: offset), buffer.count - offset)
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
    guard didWrite else { return nil }

    var response = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while response.count <= maximumOutputBytes * 2 {
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            response.append(contentsOf: buffer[0..<count])
            continue
        }
        if count < 0, errno == EINTR { continue }
        if count < 0 { return nil }
        break
    }
    guard !response.isEmpty else { return nil }
    var text = String(decoding: response, as: UTF8.self)
    if text.hasSuffix("\n") { text.removeLast() }
    return text
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func encodedJSON(_ object: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
        return nil
    }
    return base64URL(data)
}

private func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func successfulResult(_ response: String) -> [String: Any]? {
    guard let envelope = jsonObject(response),
          envelope["ok"] as? Bool == true
    else { return nil }
    return envelope["result"] as? [String: Any]
}

private func bounded(_ value: String, maximum: Int = maximumOutputBytes) -> String {
    guard value.utf8.count > maximum else { return value }
    let prefix = String(value.prefix(maximum))
    return prefix + "\n[context truncated]"
}

private func contextResult() -> [String: Any]? {
    guard let socket = paneSocketPath(),
          let response = socketRequest("channel-context", path: socket)
    else { return nil }
    return successfulResult(response)
}

private func contextText(from result: [String: Any]) -> String? {
    if let modelContext = result["modelContext"] as? String,
       !modelContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        return bounded(modelContext, maximum: 1_600)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: result),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    return bounded(text)
}

private func hookPayload(
    format: OutputFormat,
    eventName: String
) -> String? {
    guard let result = contextResult(),
          let text = contextText(from: result)
    else { return nil }
    switch format {
    case .plain:
        return text
    case .json:
        guard let data = try? JSONSerialization.data(withJSONObject: result)
        else { return nil }
        return String(data: data, encoding: .utf8)
    case .claude, .codex:
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": eventName,
                "additionalContext": text,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private func displayName(for provider: String, endpointResult: [String: Any]?) -> String {
    if let explicit = environmentValue("INFINITTY_AGENT_NAME") { return explicit }
    let display: String
    switch provider.lowercased() {
    case "claude": display = "Claude"
    case "codex": display = "Codex"
    case "opencode": display = "OpenCode"
    case "gemini": display = "Gemini"
    case "amp": display = "Amp"
    case "grok": display = "Grok"
    case "aider": display = "Aider"
    default: display = provider.capitalized
    }
    if let endpoint = endpointResult?["endpoint"] as? [String: Any],
       let id = endpoint["id"] as? String,
       let ordinal = id.split(separator: ":").last,
       Int(ordinal) != nil
    {
        return "\(display) \(ordinal)"
    }
    return "\(display) Agent"
}

private func providerName(for command: String) -> String {
    if let explicit = environmentValue("INFINITTY_AGENT_PROVIDER") {
        return explicit
    }
    let basename = URL(fileURLWithPath: command).lastPathComponent
        .replacingOccurrences(of: ".js", with: "")
    return basename.isEmpty ? "terminal" : basename
}

private func parseLaunchOptions(_ arguments: [String]) -> AgentLaunchOptions {
    var options = AgentLaunchOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            index += 1
            break
        }
        func nextValue() -> String? {
            guard index + 1 < arguments.count else { return nil }
            index += 1
            return arguments[index]
        }
        switch argument {
        case "--provider": options.provider = nextValue()
        case "--name": options.name = nextValue()
        case "--role": options.role = nextValue() ?? options.role
        case "--model": options.modelID = nextValue()
        case "--session": options.sessionID = nextValue()
        case "--required": options.required = true
        default:
            if argument.hasPrefix("-") {
                // Unknown wrapper options are not forwarded accidentally.
                index += 1
                continue
            }
            break
        }
        index += 1
    }
    guard index < arguments.count else { return options }
    options.command = arguments[index]
    options.arguments = Array(arguments[(index + 1)...])
    return options
}

private func registerAndRun(_ rawArguments: [String]) -> Never {
    let options = parseLaunchOptions(rawArguments)
    guard let command = options.command else {
        fputs("infinitty-agent: expected `run [options] -- <command> [args…]`\n", stderr)
        exit(64)
    }

    let provider = options.provider
        ?? providerName(for: command)
    let sessionID = options.sessionID
        ?? environmentValue("INFINITTY_AGENT_SESSION_ID")
        ?? UUID().uuidString.lowercased()
    let endpointContext = contextResult()
    let name = options.name
        ?? displayName(for: provider, endpointResult: endpointContext)
    let lifetimeToken = UUID().uuidString.lowercased()
    var registration: [String: Any] = [
        "v": 1,
        "displayName": name,
        "role": options.role,
        "provider": provider,
        "sessionID": sessionID,
        "capabilities": ["channel.receive", "channel.send"],
        "managedLifetime": true,
        "lifetimeToken": lifetimeToken,
    ]
    if let modelID = options.modelID ?? environmentValue("INFINITTY_AGENT_MODEL") {
        registration["modelID"] = modelID
    }

    var registered = false
    if let socket = paneSocketPath(),
       let encoded = encodedJSON(registration),
       let response = socketRequest("channel-register \(encoded)", path: socket)
    {
        registered = successfulResult(response) != nil
        if !registered, options.required {
            fputs("infinitty-agent: Channel registration failed: \(response)\n", stderr)
            exit(70)
        }
    } else if options.required {
        fputs("infinitty-agent: no owning Infinitty pane socket\n", stderr)
        exit(70)
    }

    setenv("INFINITTY_AGENT_WRAPPED", "1", 1)
    setenv("INFINITTY_AGENT_PROVIDER", provider, 1)
    setenv("INFINITTY_AGENT_NAME", name, 1)
    setenv("INFINITTY_AGENT_SESSION_ID", sessionID, 1)
    if registered { setenv("INFINITTY_AGENT_LIFETIME_TOKEN", lifetimeToken, 1) }

    let strings = [command] + options.arguments
    var argv = strings.map { strdup($0) }
    argv.append(nil)
    defer {
        for pointer in argv.dropLast() {
            if let pointer { free(pointer) }
        }
    }
    argv.withUnsafeMutableBufferPointer { buffer in
        _ = execvp(buffer[0]!, buffer.baseAddress!)
    }
    fputs("infinitty-agent: could not execute \(command): \(String(cString: strerror(errno)) )\n", stderr)
    exit(127)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let subcommand = arguments.first else {
    fputs("usage: infinitty-agent context|run …\n", stderr)
    exit(64)
}

switch subcommand {
case "context":
    var format: OutputFormat = .plain
    var eventName = environmentValue("INFINITTY_AGENT_HOOK_EVENT") ?? "UserPromptSubmit"
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--format" where index + 1 < arguments.count:
            format = OutputFormat(rawValue: arguments[index + 1]) ?? .plain
            index += 1
        case "--event" where index + 1 < arguments.count:
            eventName = arguments[index + 1]
            index += 1
        default: break
        }
        index += 1
    }
    if let output = hookPayload(format: format, eventName: eventName) {
        print(output)
    }
case "run":
    registerAndRun(Array(arguments.dropFirst()))
default:
    fputs("infinitty-agent: unknown command \(subcommand)\n", stderr)
    exit(64)
}
