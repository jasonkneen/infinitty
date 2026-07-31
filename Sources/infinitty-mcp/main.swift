import Darwin
import Foundation

// infinitty-mcp: a dependency-free MCP stdio server that bridges tool calls to
// the infinitty app control socket. Register it with any MCP client:
//   claude mcp add infinitty -- /path/to/infinitty-mcp
// Discovery: $INFINITTY_APP_SOCKET, else /tmp/infinitty-current.sock.

// Ignore SIGPIPE: a control-socket or stdout write to a peer that has gone
// away must fail with EPIPE, not kill this process (the app does the same).
signal(SIGPIPE, SIG_IGN)

// MARK: - socket bridge

private func registeredInstanceObjects() -> [[String: Any]] {
    let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let directory = support
        .appendingPathComponent("Infinitty/instances", isDirectory: true)
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
    else { return [] }
    return files
        .filter { $0.pathExtension == "json" }
        .compactMap { url -> [String: Any]? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let pid = object["pid"] as? Int,
                  let socket = object["socketPath"] as? String,
                  pid > 0,
                  kill(pid_t(pid), 0) == 0 || errno == EPERM,
                  FileManager.default.fileExists(atPath: socket)
            else { return nil }
            return object
        }
        .sorted {
            ($0["startedAt"] as? Double ?? 0) < ($1["startedAt"] as? Double ?? 0)
        }
}

var appSocketPath: String {
    let environment = ProcessInfo.processInfo.environment
    if let explicit = environment["INFINITTY_APP_SOCKET"], !explicit.isEmpty {
        return explicit
    }
    if let requestedID = environment["INFINITTY_INSTANCE_ID"], !requestedID.isEmpty {
        return registeredInstanceObjects().first {
            $0["id"] as? String == requestedID
        }?["socketPath"] as? String
            ?? "/tmp/infinitty-requested-instance-unavailable.sock"
    }
    return "/tmp/infinitty-current.sock"
}

/// Connect to the app control socket. Returns -1 on failure.
func openAppSocket() -> Int32 {
    let path = appSocketPath
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let ok = withUnsafeMutablePointer(to: &addr.sun_path) { tuple -> Bool in
        tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
            let bytes = Array(path.utf8)
            guard bytes.count < capacity else { return false }
            for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
            dst[bytes.count] = 0
            return true
        }
    }
    guard ok else {
        close(fd)
        return -1
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connected == 0 else {
        close(fd)
        return -1
    }
    return fd
}

func infinittyRequest(_ line: String, timeout: Int32 = 130) -> String {
    let fd = openAppSocket()
    guard fd >= 0 else {
        return "error: infinitty is not running (no socket at \(appSocketPath))"
    }
    defer { close(fd) }
    var readTimeout = timeval(tv_sec: time_t(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
    var writeTimeout = timeval(tv_sec: time_t(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))

    let out = Array((line + "\n").utf8)
    let didWrite = out.withUnsafeBufferPointer { buffer -> Bool in
        guard let base = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, base.advanced(by: offset), buffer.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        return true
    }
    guard didWrite else {
        return "error: could not write request: \(String(cString: strerror(errno)))"
    }

    var response = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            response.append(contentsOf: buf[0..<n])
            continue
        }
        if n < 0, errno == EINTR { continue }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            return "error: timed out waiting for infinitty response"
        }
        if n < 0 { return "error: could not read response: \(String(cString: strerror(errno)))" }
        break
    }
    var text = String(decoding: response, as: UTF8.self)
    if text.hasSuffix("\n") { text.removeLast() }
    return text
}

// MARK: - event stream

/// Ring buffer of app events fed by a background `subscribe` connection.
/// Sequence numbers are monotonic for this MCP process's lifetime so a
/// client can page with sinceSeq and never miss or re-read an event while
/// it stays within the buffer window.
final class EventBuffer {
    struct Entry {
        let seq: Int
        let object: [String: Any]
    }

    private var entries: [Entry] = []
    private var nextSeq = 1
    private let condition = NSCondition()
    private let capacity = 1000

    func append(_ object: [String: Any]) {
        condition.lock()
        entries.append(Entry(seq: nextSeq, object: object))
        nextSeq += 1
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        condition.broadcast()
        condition.unlock()
    }

    var latestSeq: Int {
        condition.lock()
        defer { condition.unlock() }
        return nextSeq - 1
    }

    /// Matching events with seq > since; blocks until `deadline` for the
    /// first match when none are pending.
    func collect(since: Int, event: String?, pane: Int?, deadline: Date) -> [Entry] {
        condition.lock()
        defer { condition.unlock() }
        while true {
            let matches = entries.filter {
                $0.seq > since && Self.matches($0.object, event: event, pane: pane)
            }
            if !matches.isEmpty || Date() >= deadline { return matches }
            condition.wait(until: min(deadline, Date().addingTimeInterval(1)))
        }
    }

    private static func matches(_ object: [String: Any], event: String?, pane: Int?) -> Bool {
        if let event, !((object["event"] as? String) ?? "").contains(event) { return false }
        if let pane, (object["pane"] as? Int) != pane { return false }
        return true
    }
}

let eventBuffer = EventBuffer()

/// Hold one long-lived `subscribe` connection to the app and feed the ring
/// buffer. Reconnects (with a pause) whenever the app restarts or the
/// socket does not exist yet.
func startEventSubscriber() {
    let thread = Thread {
        while true {
            pumpEventsOnce()
            Thread.sleep(forTimeInterval: 2)
        }
    }
    thread.name = "infinitty-event-subscriber"
    thread.qualityOfService = .utility
    thread.start()
}

private func pumpEventsOnce() {
    let fd = openAppSocket()
    guard fd >= 0 else { return }
    defer { close(fd) }
    let request = Array("subscribe\n".utf8)
    let wrote = request.withUnsafeBufferPointer { buffer -> Bool in
        guard let base = buffer.baseAddress else { return false }
        var offset = 0
        while offset < buffer.count {
            let n = write(fd, base.advanced(by: offset), buffer.count - offset)
            if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return false }
        }
        return true
    }
    guard wrote else { return }

    var pending = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { return }
        pending.append(contentsOf: buf[0..<n])
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Array(pending[..<newline])
            pending.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line))
                as? [String: Any] else { continue }  // skips the "ok" ack too
            eventBuffer.append(object)
        }
    }
}

// MARK: - browser bridge

/// Browser commands travel as a base64url-encoded JSON object rather than as
/// space-delimited arguments. URLs, selectors, comments, and typed text can
/// therefore contain whitespace and arbitrary punctuation without changing the
/// app-control protocol's framing.
private let maximumBrowserRequestBytes = 48_000

func browserCall(
    _ operation: String,
    arguments: [String: Any] = [:],
    timeout: Int32 = 55
) -> String {
    var payload = arguments
    payload["v"] = 1
    payload["op"] = operation
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload) else {
        return "error: could not encode browser request"
    }
    guard data.count <= maximumBrowserRequestBytes else {
        return "error: browser request exceeds \(maximumBrowserRequestBytes) bytes"
    }
    let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return infinittyRequest("browser \(encoded)", timeout: timeout)
}

private let maximumChannelRequestBytes = 48_000

func channelCall(
    _ operation: String,
    arguments: [String: Any] = [:]
) -> String {
    var payload = arguments
    payload["v"] = 1
    payload["op"] = operation
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload) else {
        return "error: could not encode Channel request"
    }
    guard data.count <= maximumChannelRequestBytes else {
        return "error: Channel request exceeds \(maximumChannelRequestBytes) bytes"
    }
    let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return infinittyRequest("channel \(encoded)")
}

func channelPanelCall(
    _ operation: String,
    arguments: [String: Any] = [:]
) -> String {
    var payload = arguments
    payload["v"] = 1
    payload["op"] = operation
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload) else {
        return "error: could not encode Channel panel request"
    }
    guard data.count <= maximumChannelRequestBytes else {
        return "error: Channel panel request exceeds \(maximumChannelRequestBytes) bytes"
    }
    let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return infinittyRequest("channel-panel \(encoded)")
}

func chatCall(
    _ operation: String,
    arguments: [String: Any] = [:]
) -> String {
    var payload = arguments
    payload["v"] = 1
    payload["op"] = operation
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload)
    else {
        return "error: could not encode Chat request"
    }
    guard data.count <= maximumChannelRequestBytes else {
        return "error: Chat request exceeds \(maximumChannelRequestBytes) bytes"
    }
    let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return infinittyRequest("chat \(encoded)")
}

// MARK: - tool definitions

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let invoke: ([String: Any]) -> String
}

func paneArg(_ args: [String: Any]) -> String {
    if let n = args["pane"] as? Int { return String(n) }
    if let s = args["pane"] as? String { return s }
    return "0"
}

let paneProperty: [String: Any] = [
    "pane": ["type": "integer", "description": "Pane id from infinitty_list_panes"],
]

let browserIDProperty: [String: Any] = [
    "browserId": [
        "type": "string",
        "description": "Browser id returned by infinitty_browser_open or infinitty_browser_list",
    ],
]

let browserSnapshotProperty = browserIDProperty.merging([
    "snapshotId": [
        "type": "string",
        "description": "Fresh snapshot id returned by infinitty_browser_snapshot",
    ],
] as [String: Any]) { a, _ in a }

let channelActorSchema: [String: Any] = [
    "type": "object",
    "description": "Explicit actor responsible for this mutation.",
    "properties": [
        "id": ["type": "string"],
        "kind": ["type": "string", "enum": ["human", "agent", "system"]],
        "displayName": ["type": "string"],
    ],
    "required": ["id", "kind", "displayName"],
]

let channelEndpointSchema: [String: Any] = [
    "type": "object",
    "description": "Endpoint object returned in infinitty_list_panes.channelEndpoint.",
    "properties": [
        "id": ["type": "string"],
        "kind": ["type": "string"],
        "label": ["type": "string"],
        "participantID": ["type": "string"],
        "instanceID": ["type": "string"],
    ],
    "required": ["id", "kind", "label"],
]

let tools: [Tool] = [
    Tool(
        name: "infinitty_instances",
        description: "List every live infinitty app instance with its stable process-lifetime "
            + "instance id and direct socket. Set INFINITTY_INSTANCE_ID when launching this "
            + "MCP server to address one explicitly.",
        schema: ["type": "object", "properties": [:]],
        invoke: { _ in
            let instances = registeredInstanceObjects()
            let data = (try? JSONSerialization.data(withJSONObject: instances))
                ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    ),
    Tool(
        name: "infinitty_list_panes",
        description: "List every live infinitty pane, including terminals and named Chat "
            + "participants, with focus state and the endpoint object used to link a "
            + "collaboration Channel.",
        schema: ["type": "object", "properties": [:]],
        invoke: { _ in infinittyRequest("list") }
    ),
    Tool(
        name: "infinitty_channels",
        description: "Read the authoritative snapshot of Channels, connected endpoints, "
            + "participants and roles, responsibility claims, plans, and recent messages.",
        schema: ["type": "object", "properties": [:]],
        invoke: { _ in channelCall("snapshot") }
    ),
    Tool(
        name: "infinitty_channel_link",
        description: "Link two pane endpoints. It creates a Channel when neither endpoint "
            + "is linked, or extends the existing Channel. Merging two Channels is rejected "
            + "until explicit merge consent is implemented.",
        schema: [
            "type": "object",
            "properties": [
                "source": channelEndpointSchema,
                "target": channelEndpointSchema,
                "channelID": ["type": "string"],
                "actor": channelActorSchema,
                "idempotencyKey": ["type": "string"],
                "expectedRevision": ["type": "integer"],
                "causationID": ["type": "string"],
            ],
            "required": ["source", "target", "actor", "idempotencyKey"],
        ],
        invoke: { args in channelCall("link", arguments: args) }
    ),
    Tool(
        name: "infinitty_channel_apply",
        description: "Apply one typed Channel mutation: create, link_and_join, join, leave, "
            + "update_membership, claim, release, replace_plan, or post_message. "
            + "Supply the corresponding typed payload plus "
            + "an explicit actor and idempotency key. Returns the committed room snapshot.",
        schema: [
            "type": "object",
            "properties": [
                "op": [
                    "type": "string",
                    "enum": [
                        "create", "link_and_join", "join", "leave",
                        "update_membership",
                        "claim", "release",
                        "replace_plan", "post_message",
                    ],
                ] as [String: Any],
                "actor": channelActorSchema,
                "idempotencyKey": ["type": "string"],
                "expectedRevision": ["type": "integer"],
                "causationID": ["type": "string"],
                "channelID": ["type": "string"],
                "endpointID": ["type": "string"],
                "endpoint": channelEndpointSchema,
                "source": channelEndpointSchema,
                "target": channelEndpointSchema,
                "name": ["type": "string"],
                "colorHex": ["type": "string"],
                "participant": ["type": "object"],
                "participants": ["type": "array", "items": ["type": "object"]],
                "claim": ["type": "object"],
                "claimID": ["type": "string"],
                "plan": ["type": "array", "items": ["type": "object"]],
                "message": ["type": "object"],
            ],
            "required": ["op", "actor", "idempotencyKey"],
        ],
        invoke: { args in
            var payload = args
            let operation = payload.removeValue(forKey: "op") as? String ?? ""
            return channelCall(operation, arguments: payload)
        }
    ),
    Tool(
        name: "infinitty_room_propose",
        description: "Prepare an inert, permission-first multi-agent room proposal. "
            + "This records the exact objective, workspace, worktree policy, named "
            + "agents, providers, models, roles, capabilities, and file scopes, then "
            + "asks the human in native Infinitty UI. It does not create panes, "
            + "provider processes, worktrees, or agents and cannot approve itself.",
        schema: [
            "type": "object",
            "properties": [
                "proposalId": ["type": "string"],
                "channelId": ["type": "string"],
                "roomName": ["type": "string"],
                "objective": ["type": "string"],
                "workspaceRoot": [
                    "type": "string",
                    "description":
                        "Absolute checkout path bound into the approval digest.",
                ],
                "workspaceStrategy": [
                    "type": "string",
                    "enum": ["shared_checkout", "worktrees"],
                ] as [String: Any],
                "presentation": [
                    "type": "string",
                    "enum": ["visual", "headless"],
                    "description":
                        "Where approved Chat agents must run. Defaults to the addressed instance mode.",
                ] as [String: Any],
                "targetInstanceId": [
                    "type": "string",
                    "description":
                        "Exact live instance target; defaults to the instance addressed by this MCP server.",
                ],
                "agents": [
                    "type": "array",
                    "minItems": 1,
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string"],
                            "displayName": ["type": "string"],
                            "role": ["type": "string"],
                            "runtime": [
                                "type": "string",
                                "enum": ["local", "cloud"],
                            ] as [String: Any],
                            "provider": [
                                "type": "string",
                                "enum": [
                                    "auto", "claude", "codex",
                                    "opencode", "hermes", "amp",
                                    "apple",
                                ],
                            ] as [String: Any],
                            "modelID": [
                                "type": "string",
                                "description":
                                    "Opaque provider model identifier.",
                            ],
                            "responsibilityScopes": [
                                "type": "array",
                                "items": ["type": "string"],
                            ],
                            "capabilities": [
                                "type": "array",
                                "items": ["type": "string"],
                            ],
                        ],
                        "required": [
                            "id", "displayName", "role",
                            "runtime", "provider",
                        ],
                    ] as [String: Any],
                ],
                "requestedCapabilities": [
                    "type": "array",
                    "items": ["type": "string"],
                ],
                "expiresInSeconds": [
                    "type": "integer",
                    "minimum": 60,
                    "maximum": 3600,
                    "description": "Approval lifetime; defaults to 600 seconds.",
                ],
                "actor": channelActorSchema,
                "idempotencyKey": ["type": "string"],
                "causationID": ["type": "string"],
            ],
            "required": [
                "roomName", "objective", "workspaceRoot",
                "workspaceStrategy", "agents", "actor",
            ],
        ],
        invoke: { args in
            let proposalID = args["proposalId"] as? String
                ?? "proposal-\(UUID().uuidString.lowercased())"
            let channelID = args["channelId"] as? String
                ?? "channel-\(UUID().uuidString.lowercased())"
            let lifetime = min(
                max(args["expiresInSeconds"] as? Int ?? 600, 60),
                3_600)
            let instanceResponse = infinittyRequest("instance")
            let instance = instanceResponse.data(using: .utf8)
                .flatMap {
                    try? JSONSerialization.jsonObject(with: $0)
                        as? [String: Any]
                }
            let targetInstanceID =
                args["targetInstanceId"] as? String
                ?? instance?["id"] as? String
            guard let targetInstanceID,
                  !targetInstanceID.isEmpty
            else {
                return "error: could not resolve the target Infinitty instance"
            }
            let presentation =
                args["presentation"] as? String
                ?? ((instance?["mode"] as? String) == "headless"
                    ? "headless"
                    : "visual")
            let proposal: [String: Any] = [
                "id": proposalID,
                "channelID": channelID,
                "roomName": args["roomName"] as? String ?? "",
                "objective": args["objective"] as? String ?? "",
                "workspaceRoot": args["workspaceRoot"] as? String ?? "",
                "agents": args["agents"] as? [[String: Any]] ?? [],
                "workspaceStrategy":
                    args["workspaceStrategy"] as? String
                        ?? "shared_checkout",
                "presentation": presentation,
                "targetInstanceID": targetInstanceID,
                "requestedCapabilities":
                    args["requestedCapabilities"] as? [String] ?? [],
                "expiresAt":
                    Date().addingTimeInterval(TimeInterval(lifetime))
                        .timeIntervalSince1970 * 1_000,
            ]
            // Keep the payload shape explicit so no approval-only field can
            // accidentally cross this tool.
            var payload: [String: Any] = [
                "proposal": proposal,
                "actor": args["actor"] as? [String: Any] ?? [:],
                "idempotencyKey":
                    args["idempotencyKey"] as? String
                        ?? "prepare-\(proposalID)",
            ]
            if let causationID = args["causationID"] {
                payload["causationID"] = causationID
            }
            return channelCall(
                "prepare_proposal",
                arguments: payload)
        }
    ),
    Tool(
        name: "infinitty_chat",
        description: "Create and completely operate a named Chat pane. List, inspect, "
            + "focus, close, submit, cancel, rename, bind a workspace, and create or "
            + "select conversation threads. Provider model identifiers are passed "
            + "through to the installed provider without a hard-coded release list.",
        schema: [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": [
                        "list", "create", "snapshot", "focus", "close",
                        "submit", "cancel", "new_thread", "select_thread",
                        "rename", "set_workspace",
                    ],
                ] as [String: Any],
                "chatId": [
                    "type": "string",
                    "description": "Stable Chat id returned by create or list.",
                ],
                "name": ["type": "string"],
                "role": ["type": "string"],
                "provider": [
                    "type": "string",
                    "enum": [
                        "auto", "claude", "codex", "opencode", "hermes",
                        "amp", "apple",
                    ],
                ] as [String: Any],
                "model": [
                    "type": "string",
                    "description": "Opaque provider model id or visible model title.",
                ],
                "effort": ["type": "string"],
                "workspace": ["type": "string"],
                "threadId": ["type": "string"],
                "text": ["type": "string"],
            ],
            "required": ["action"],
        ],
        invoke: { args in
            var payload = args
            let action = payload.removeValue(forKey: "action") as? String
                ?? "list"
            return chatCall(action, arguments: payload)
        }
    ),
    Tool(
        name: "infinitty_channel_panel",
        description: "Control the first-class Channel workspace pane. List room panels; "
            + "open, focus, close, or inspect a room; select a delegation thread; "
            + "post a durable human message; or assign a connected participant's role.",
        schema: [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": [
                        "list", "open", "focus", "close", "snapshot",
                        "select_thread", "post_message", "assign_role",
                    ],
                ] as [String: Any],
                "channelId": [
                    "type": "string",
                    "description": "Channel id from infinitty_channels; omitted only for list.",
                ],
                "threadId": [
                    "type": ["string", "null"],
                    "description": "Delegation thread id, or null for the room conversation.",
                ] as [String: Any],
                "text": [
                    "type": "string",
                    "description": "Message text for post_message.",
                ],
                "participantId": [
                    "type": "string",
                    "description": "Participant id for assign_role.",
                ],
                "role": [
                    "type": "string",
                    "description": "Responsibility-focused role for assign_role.",
                ],
            ],
            "required": ["action"],
        ],
        invoke: { args in
            var payload = args
            let action = payload.removeValue(forKey: "action") as? String
                ?? "list"
            return channelPanelCall(action, arguments: payload)
        }
    ),
    Tool(
        name: "infinitty_toggle_quick_terminal",
        description: "Show or hide infinitty's persistent quick terminal.",
        schema: ["type": "object", "properties": [:]],
        invoke: { _ in infinittyRequest("toggle-quick-terminal") }
    ),
    Tool(
        name: "infinitty_sidebar",
        description: "Show, hide, or toggle infinitty's Files pane. The Files pane "
            + "contains the Files / Changes switch.",
        schema: [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["show", "hide", "toggle"],
                    "description": "show, hide, or toggle (default toggle)",
                ] as [String: Any],
            ],
        ],
        invoke: { args in infinittyRequest("sidebar \(args["action"] as? String ?? "toggle")") }
    ),
    Tool(
        name: "infinitty_sidebar_tab",
        description: "Open or focus a Files/Changes pane or the independent Chat pane.",
        schema: [
            "type": "object",
            "properties": [
                "tab": [
                    "type": "string",
                    "enum": ["files", "changes", "chat"],
                    "description": "Which panel content to show",
                ] as [String: Any],
            ],
            "required": ["tab"],
        ],
        invoke: { args in infinittyRequest("sidebar-tab \(args["tab"] as? String ?? "")") }
    ),
    Tool(
        name: "infinitty_chat_model",
        description: "Set the infinitty sidebar chat's model (e.g. \"Claude Sonnet 5\", "
            + "\"claude\", \"gpt\", \"auto\"). Opens the chat first.",
        schema: [
            "type": "object",
            "properties": [
                "model": [
                    "type": "string",
                    "description": "Model name or substring to select",
                ] as [String: Any],
            ],
            "required": ["model"],
        ],
        invoke: { args in infinittyRequest("chat-model \(args["model"] as? String ?? "")") }
    ),
    Tool(
        name: "infinitty_chat_effort",
        description: "Set the infinitty sidebar chat's reasoning effort: auto, low, "
            + "medium, or high. Opens the chat first.",
        schema: [
            "type": "object",
            "properties": [
                "effort": [
                    "type": "string",
                    "enum": ["auto", "low", "medium", "high"],
                    "description": "Reasoning effort level",
                ] as [String: Any],
            ],
            "required": ["effort"],
        ],
        invoke: { args in infinittyRequest("chat-effort \(args["effort"] as? String ?? "")") }
    ),
    Tool(
        name: "infinitty_run",
        description: "Run a shell command in a pane and wait for it to finish. "
            + "Returns JSON with exitCode and the command's exact output. "
            + "Requires infinitty shell integration (OSC 133) in that pane.",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "command": ["type": "string", "description": "Shell command to run"],
            ]) { a, _ in a },
            "required": ["pane", "command"],
        ],
        invoke: { args in
            infinittyRequest("run \(paneArg(args)) \(args["command"] as? String ?? "")")
        }
    ),
    Tool(
        name: "infinitty_screen",
        description: "Read a pane's visible screen as plain text.",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("screen \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_history",
        description: "Read the last N lines of a pane including scrollback.",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "lines": ["type": "integer", "description": "How many lines (default 100)"],
            ]) { a, _ in a },
            "required": ["pane"],
        ],
        invoke: { args in
            infinittyRequest("history \(paneArg(args)) \(args["lines"] as? Int ?? 100)")
        }
    ),
    Tool(
        name: "infinitty_send",
        description: "Type text into a pane. Set submit=false to type without pressing return "
            + "(for TUIs, partial input, or control sequences).",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "text": ["type": "string"],
                "submit": ["type": "boolean", "description": "Press return after (default true)"],
            ]) { a, _ in a },
            "required": ["pane", "text"],
        ],
        invoke: { args in
            let cmd = (args["submit"] as? Bool ?? true) ? "send-line" : "send"
            return infinittyRequest("\(cmd) \(paneArg(args)) \(args["text"] as? String ?? "")")
        }
    ),
    Tool(
        name: "infinitty_surface",
        description: "Open a display surface in infinitty: rendered markdown, raw HTML "
            + "(an MCP-UI text/html resource payload renders directly; text/uri-list "
            + "maps to kind=url), a web URL, or kind=ui — a Vercel json-render spec "
            + "rendered with a native-styled component registry. For kind=ui pass "
            + "`spec` = {root, elements, state?} (flat element map; element = {type, "
            + "props, children?, on?}). Components: Stack(direction,gap), Card(title,"
            + "description), Text(content,variant:title|heading|body|caption|code), "
            + "Badge(label,tone), Button(label,action,variant), Input(label,value:"
            + "{$bindState:\"/path\"}), Checkbox(label,checked), Progress(value,label), "
            + "List, ListItem(title,subtitle,done), Metric(label,value,delta), "
            + "CodeBlock(code), Image(src), Divider. Actions (Button.action or "
            + "on.press): submit|cancel|select|open|run|refresh|custom — clicks and "
            + "state changes stream back as \"ui\" events (infinitty_events). "
            + "target=split places the surface beside the pane at the given ratio "
            + "(e.g. 0.2 for an 80/20 split); target=window opens a standalone "
            + "window. Returns a surface id.",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "kind": [
                    "type": "string", "enum": ["markdown", "html", "url", "ui"],
                    "description": "What the content is",
                ] as [String: Any],
                "spec": [
                    "type": "object",
                    "description": "json-render spec {root, elements, state?} (kind=ui)",
                ] as [String: Any],
                "target": [
                    "type": "string", "enum": ["split", "window"],
                    "description": "split beside the pane (default) or a standalone window",
                ] as [String: Any],
                "direction": [
                    "type": "string", "enum": ["right", "left", "down", "up"],
                    "description": "Split side relative to the pane (default right)",
                ] as [String: Any],
                "ratio": [
                    "type": "number",
                    "description": "Fraction of the split for the surface, 0.15-0.85 (default 0.35)",
                ] as [String: Any],
                "title": ["type": "string", "description": "Header/window title"],
                "content": [
                    "type": "string",
                    "description": "Markdown or HTML content (kind=markdown|html)",
                ] as [String: Any],
                "url": ["type": "string", "description": "Absolute http(s) URL (kind=url)"],
            ]) { a, _ in a },
            "required": ["pane", "kind"],
        ],
        invoke: { args in
            var payload: [String: Any] = [:]
            for key in ["kind", "target", "direction", "ratio", "title", "content", "url", "spec"] {
                if let value = args[key] { payload[key] = value }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                return "error: invalid surface arguments"
            }
            let json = String(decoding: data, as: UTF8.self)
            return infinittyRequest("surface \(paneArg(args)) \(json)")
        }
    ),
    Tool(
        name: "infinitty_surface_close",
        description: "Close a surface previously opened with infinitty_surface "
            + "(works for both split panes and standalone windows).",
        schema: [
            "type": "object",
            "properties": [
                "surfaceId": [
                    "type": "string",
                    "description": "Surface id returned by infinitty_surface (e.g. \"surface-1\")",
                ] as [String: Any],
            ],
            "required": ["surfaceId"],
        ],
        invoke: { args in
            infinittyRequest("surface-close \(args["surfaceId"] as? String ?? "")")
        }
    ),
    Tool(
        name: "infinitty_todos",
        description: "Publish (or read) your current plan/todo list for a pane. "
            + "It appears behind a checklist icon in the pane header so the user "
            + "can follow progress. Call again with the full updated list whenever "
            + "an item's status changes; pass an empty list to clear it.",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "todos": [
                    "type": "array",
                    "description": "Full todo list, in order. Omit to read the current list.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "content": ["type": "string", "description": "The task"],
                            "status": [
                                "type": "string",
                                "enum": ["pending", "in_progress", "completed"],
                            ] as [String: Any],
                        ],
                        "required": ["content", "status"],
                    ] as [String: Any],
                ] as [String: Any],
            ]) { a, _ in a },
            "required": ["pane"],
        ],
        invoke: { args in
            guard let todos = args["todos"] else {
                return infinittyRequest("todos \(paneArg(args))")
            }
            guard JSONSerialization.isValidJSONObject(todos),
                  let data = try? JSONSerialization.data(withJSONObject: todos)
            else { return "error: todos must be a JSON array" }
            let json = String(decoding: data, as: UTF8.self)
            return infinittyRequest("todos \(paneArg(args)) \(json)")
        }
    ),
    Tool(
        name: "infinitty_last_output",
        description: "Exact output of the last completed command in a pane (OSC 133).",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("last-output \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_exit_code",
        description: "Exit code of the last completed command in a pane (OSC 133).",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("exit-code \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_new_tab",
        description: "Open a new infinitty tab. Returns the new pane id.",
        schema: [
            "type": "object",
            "properties": [
                "cwd": ["type": "string", "description": "Shell starting directory (absolute path)"],
            ],
        ],
        invoke: { args in
            let cwd = args["cwd"] as? String ?? ""
            return infinittyRequest(cwd.isEmpty ? "new-tab" : "new-tab \(cwd)")
        }
    ),
    Tool(
        name: "infinitty_new_window",
        description: "Open a new infinitty window. Returns the new pane id.",
        schema: [
            "type": "object",
            "properties": [
                "cwd": ["type": "string", "description": "Shell starting directory (absolute path)"],
            ],
        ],
        invoke: { args in
            let cwd = args["cwd"] as? String ?? ""
            return infinittyRequest(cwd.isEmpty ? "new-window" : "new-window \(cwd)")
        }
    ),
    Tool(
        name: "infinitty_split",
        description: "Split a pane. Returns the new pane id.",
        schema: [
            "type": "object",
            "properties": paneProperty.merging([
                "direction": [
                    "type": "string", "enum": ["right", "left", "down", "up"],
                ],
            ]) { a, _ in a },
            "required": ["pane", "direction"],
        ],
        invoke: { args in
            infinittyRequest("split \(paneArg(args)) \(args["direction"] as? String ?? "right")")
        }
    ),
    Tool(
        name: "infinitty_focus",
        description: "Raise and focus a pane.",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("focus \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_close",
        description: "Close a pane (terminates its shell).",
        schema: ["type": "object", "properties": paneProperty, "required": ["pane"]],
        invoke: { args in infinittyRequest("close \(paneArg(args))") }
    ),
    Tool(
        name: "infinitty_events",
        description: "Read live infinitty events so agents can react to terminal state changes. "
            + "Event types: pane-opened, pane-closed, title, marker, process, and browser-*. "
            + "marker events are OSC 133 shell round trips (kind C = command started, "
            + "kind D = command finished with its exit code). process events fire when a pane's "
            + "foreground process changes — e.g. an agent CLI like claude or codex starts, or the "
            + "pane returns to the shell prompt (empty name). Returns {latestSeq, events}; pass "
            + "sinceSeq from the previous response to read only newer events. Set waitSeconds to "
            + "long-poll: the call blocks until a matching event arrives or the wait expires.",
        schema: [
            "type": "object",
            "properties": [
                "sinceSeq": [
                    "type": "integer",
                    "description": "Only events after this sequence number (from the previous "
                        + "response's latestSeq). Omit to get the most recent events.",
                ] as [String: Any],
                "waitSeconds": [
                    "type": "integer", "minimum": 0, "maximum": 120,
                    "description": "Block up to this many seconds for the first matching event "
                        + "(default 0 = return immediately)",
                ] as [String: Any],
                "event": [
                    "type": "string",
                    "description": "Only events whose type contains this substring, "
                        + "e.g. \"marker\" or \"process\"",
                ] as [String: Any],
                "pane": [
                    "type": "integer",
                    "description": "Only events for this pane id",
                ] as [String: Any],
            ],
        ],
        invoke: { args in
            let since = args["sinceSeq"] as? Int ?? max(eventBuffer.latestSeq - 20, 0)
            let wait = min(max(args["waitSeconds"] as? Int ?? 0, 0), 120)
            let entries = eventBuffer.collect(
                since: since,
                event: args["event"] as? String,
                pane: args["pane"] as? Int,
                deadline: Date().addingTimeInterval(TimeInterval(wait)))
            let events = entries.map { entry -> [String: Any] in
                var object = entry.object
                object["seq"] = entry.seq
                return object
            }
            let payload: [String: Any] = ["latestSeq": eventBuffer.latestSeq, "events": events]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                return "error: could not encode events"
            }
            return String(decoding: data, as: UTF8.self)
        }
    ),
    Tool(
        name: "infinitty_activity",
        description: "Show a short status message in infinitty's notch live-activity widget.",
        schema: [
            "type": "object",
            "properties": ["text": ["type": "string"]],
            "required": ["text"],
        ],
        invoke: { args in infinittyRequest("activity \(args["text"] as? String ?? "")") }
    ),
    Tool(
        name: "infinitty_browser_open",
        description: "Open a native browser pane, or focus an existing one. By default this "
            + "focuses the most recently opened browser pane in the target tab (creating one "
            + "only if none exists); pass newPane=true to add another instance, or browserId "
            + "to target a specific instance. Optionally navigate it to a URL. "
            + "Use its browserId with the other infinitty_browser_* tools.",
        schema: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "Optional URL to load"],
                "anchorPane": [
                    "type": "integer",
                    "description": "Terminal pane whose tab should host the browser (default: key tab)",
                ],
                "browserId": [
                    "type": "string",
                    "description": "Focus this existing browser instance instead of the most recent one",
                ],
                "newPane": [
                    "type": "boolean",
                    "description": "Create an additional browser pane even if one already exists",
                ],
            ],
        ],
        invoke: { args in browserCall("open", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_list",
        description: "List all browser pane instances across every window, with each instance's "
            + "browserId, current URL, title, loading state, and viewport mode.",
        schema: ["type": "object", "properties": [:]],
        invoke: { _ in browserCall("list") }
    ),
    Tool(
        name: "infinitty_browser_navigate",
        description: "Navigate a browser panel to a URL and wait for the navigation result.",
        schema: [
            "type": "object",
            "properties": browserIDProperty.merging([
                "url": ["type": "string", "description": "Absolute URL, or a host/search-like URL"],
            ]) { a, _ in a },
            "required": ["browserId", "url"],
        ],
        invoke: { args in browserCall("navigate", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_snapshot",
        description: "Return a compact DOM-first snapshot of visible interactive elements. "
            + "Use the returned ref values for click, type, or press; take a new snapshot after navigation.",
        schema: [
            "type": "object",
            "properties": browserIDProperty.merging([
                "maxNodes": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 250,
                    "description": "Maximum interactive elements to return (default 80)",
                ],
            ]) { a, _ in a },
            "required": ["browserId"],
        ],
        invoke: { args in browserCall("snapshot", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_click",
        description: "Click an interactive element identified by a fresh browser snapshot ref.",
        schema: [
            "type": "object",
            "properties": browserSnapshotProperty.merging([
                "ref": ["type": "string", "description": "Element ref from infinitty_browser_snapshot"],
            ]) { a, _ in a },
            "required": ["browserId", "snapshotId", "ref"],
        ],
        invoke: { args in browserCall("click", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_type",
        description: "Set or append text in an input, textarea, or contenteditable element from a fresh snapshot.",
        schema: [
            "type": "object",
            "properties": browserSnapshotProperty.merging([
                "ref": ["type": "string", "description": "Element ref from infinitty_browser_snapshot"],
                "text": ["type": "string", "description": "Text to enter"],
                "mode": [
                    "type": "string",
                    "enum": ["replace", "append"],
                    "description": "Replace existing text (default) or append",
                ],
            ]) { a, _ in a },
            "required": ["browserId", "snapshotId", "ref", "text"],
        ],
        invoke: { args in browserCall("type", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_press",
        description: "Dispatch a key to the focused page element, or to an optional fresh snapshot ref and snapshotId.",
        schema: [
            "type": "object",
            "properties": browserSnapshotProperty.merging([
                "key": ["type": "string", "description": "Key name, e.g. Enter, Escape, ArrowDown"],
                "ref": ["type": "string", "description": "Optional focused-element ref from a fresh snapshot"],
            ]) { a, _ in a },
            "required": ["browserId", "key"],
        ],
        invoke: { args in browserCall("press", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_scroll",
        description: "Scroll a browser panel by CSS pixels; positive deltaY scrolls down.",
        schema: [
            "type": "object",
            "properties": browserIDProperty.merging([
                "deltaX": ["type": "number", "description": "Horizontal pixels (default 0)"],
                "deltaY": ["type": "number", "description": "Vertical pixels (default 500)"],
            ]) { a, _ in a },
            "required": ["browserId"],
        ],
        invoke: { args in browserCall("scroll", arguments: args) }
    ),
    Tool(
        name: "infinitty_browser_screenshot",
        description: "Capture the visible browser panel and return the local artifact path.",
        schema: ["type": "object", "properties": browserIDProperty, "required": ["browserId"]],
        invoke: { args in browserCall("screenshot", arguments: args) }
    ),
]

// MARK: - JSON-RPC over stdio (newline-delimited)

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func reply(id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func replyError(id: Any, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

/// Browser operations return structured `{ "ok": false, "error": … }`
/// replies from the app. Surface those as MCP tool errors just like the
/// established line-protocol `error:` responses.
func isToolError(_ text: String) -> Bool {
    guard !text.hasPrefix("error:") else { return true }
    guard let data = text.data(using: .utf8),
          let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ok = response["ok"] as? Bool else {
        return false
    }
    return !ok
}

startEventSubscriber()

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = msg["method"] as? String else { continue }
    let id = msg["id"]

    switch method {
    case "initialize":
        guard let id else { break }
        reply(id: id, result: [
            "protocolVersion": (msg["params"] as? [String: Any])?["protocolVersion"] as? String
                ?? "2024-11-05",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "infinitty", "version": "0.1"],
        ])
    case "notifications/initialized", "notifications/cancelled":
        break
    case "ping":
        if let id { reply(id: id, result: [:]) }
    case "tools/list":
        guard let id else { break }
        reply(id: id, result: [
            "tools": tools.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.schema]
            },
        ])
    case "tools/call":
        guard let id else { break }
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let tool = tools.first(where: { $0.name == name }) else {
            replyError(id: id, code: -32602, message: "unknown tool \(name)")
            continue
        }
        let text = tool.invoke(args)
        reply(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": isToolError(text),
        ])
    default:
        if let id { replyError(id: id, code: -32601, message: "method not found: \(method)") }
    }
}
