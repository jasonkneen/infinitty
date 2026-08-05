import Foundation
import Darwin

/// Best-effort bridge for the Sourcegraph Amp CLI.
///
/// Current Amp builds expose `--execute --stream-json` as their supported
/// non-interactive provider contract. The bridge still accepts plain text
/// output for older test fixtures and builds, but it never scrapes the
/// interactive TUI.
final class AmpBridge: @unchecked Sendable {
    static let shared = AmpBridge()

    private let executableURLOverride: URL?
    private let processLock = NSLock()
    private var processes: [String: Process] = [:]
    private var conversationGenerations: [String: UInt64] = [:]
    init(executableURL: URL? = nil) {
        self.executableURLOverride = executableURL
    }

    func turn(
        prompt: String,
        system: String = "",
        model: String? = nil,
        cwd: String? = nil,
        conversationID: String? = nil,
        timeout: TimeInterval =
            AssistantTurnTimeoutPolicy.defaultInactivitySeconds,
        onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        let conversationGeneration: UInt64?
        if let conversationID {
            let (generation, previous) = processLock.withLock {
                let generation =
                    (conversationGenerations[conversationID] ?? 0) &+ 1
                conversationGenerations[conversationID] = generation
                return (
                    generation,
                    processes.removeValue(forKey: conversationID))
            }
            if previous?.isRunning == true { previous?.terminate() }
            conversationGeneration = generation
        } else {
            conversationGeneration = nil
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let executable = self.executableURLOverride
                        ?? CLIExecutableResolver.resolve(.amp) else {
                    cont.resume(throwing: AmpBridgeError.processUnavailable(
                        "Amp CLI not found on PATH; install it or set INFINITTY_AMP_EXECUTABLE."))
                    return
                }
                let full = system.isEmpty ? prompt : system + "\n\n" + prompt
                let process = Process()
                process.executableURL = executable
                var arguments = [
                    "--no-ide",
                    "--no-notifications",
                    "--no-color",
                    "--execute",
                    full,
                    "--stream-json",
                ]
                if let model, !model.isEmpty {
                    // Amp's -m value is an agent mode discovered by the
                    // adapter, not a hard-coded model release identifier.
                    arguments += ["-m", model]
                }
                process.arguments = arguments
                let stdout = Pipe(), stderr = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = stdout
                process.standardError = stderr
                if let cwd, !cwd.isEmpty {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(
                        atPath: cwd, isDirectory: &isDirectory
                    ), isDirectory.boolValue {
                        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                    }
                }
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
                env["NO_COLOR"] = "1"
                env["TERM"] = "dumb"
                process.environment = env

                // Drain stderr on the side so a chatty child can't fill the
                // pipe and block before we've read stdout to EOF.
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    if handle.availableData.isEmpty { handle.readabilityHandler = nil }
                }
                let collector = AmpTurnOutputCollector(onPartial: onPartial)
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        collector.markEOF()
                    } else {
                        collector.append(chunk)
                    }
                }

                PetLog.log("AmpBridge.spawn (--execute --stream-json)")
                do {
                    try process.run()
                } catch {
                    if let conversationID, let conversationGeneration {
                        self.finishConversation(
                            conversationID,
                            generation: conversationGeneration,
                            process: nil)
                    }
                    cont.resume(throwing: AmpBridgeError.processUnavailable(
                        "Failed to launch amp: \(error.localizedDescription)"))
                    return
                }
                if let conversationID, let conversationGeneration {
                    self.processLock.lock()
                    let wasCancelled =
                        self.conversationGenerations[conversationID]
                            != conversationGeneration
                    if !wasCancelled {
                        self.processes[conversationID] = process
                    }
                    self.processLock.unlock()
                    if wasCancelled, process.isRunning {
                        process.terminate()
                    }
                }

                // Stream events update an inactivity clock. Agentic turns may
                // legitimately run longer than the configured budget while
                // still producing work; silence remains bounded, and a 30m
                // absolute cap protects the process lane.
                let inactivityBudget = max(timeout, 0.001)
                let startedAt = ProcessInfo.processInfo.systemUptime
                var timeoutError: AmpBridgeError?
                while process.isRunning {
                    let now = ProcessInfo.processInfo.systemUptime
                    let idleFor = now - collector.lastActivityUptime
                    let elapsed = now - startedAt
                    if elapsed
                        >= AssistantTurnTimeoutPolicy.maximumTurnDurationSeconds {
                        timeoutError = .maximumDurationExceeded
                        break
                    }
                    if idleFor >= inactivityBudget {
                        timeoutError = .turnTimeout
                        break
                    }
                    let wait = min(
                        min(
                            max(inactivityBudget - idleFor, 0.001),
                            max(
                                AssistantTurnTimeoutPolicy.maximumTurnDurationSeconds
                                    - elapsed,
                                0.001)),
                        0.25)
                    collector.waitForActivity(timeout: wait)
                }
                var forceKill: DispatchWorkItem?
                if let timeoutError, process.isRunning {
                    PetLog.log(
                        "AmpBridge.\(timeoutError.logLabel) — terminating")
                    process.terminate()
                    let kill = DispatchWorkItem {
                        if process.isRunning {
                            _ = Darwin.kill(process.processIdentifier, SIGKILL)
                        }
                    }
                    forceKill = kill
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + 2, execute: kill)
                }
                process.waitUntilExit()
                forceKill?.cancel()
                collector.waitForEOF(timeout: 0.5)
                stdout.fileHandleForReading.readabilityHandler = nil
                if let conversationID, let conversationGeneration {
                    self.finishConversation(
                        conversationID,
                        generation: conversationGeneration,
                        process: process)
                }
                stderr.fileHandleForReading.readabilityHandler = nil

                let data = collector.data
                let raw = String(data: data, encoding: .utf8) ?? ""
                let text = (AmpBridge.textFromStreamJSON(raw)
                    ?? AmpBridge.stripANSI(raw))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let timeoutError {
                    cont.resume(throwing: timeoutError)
                } else if process.terminationStatus == 0, !text.isEmpty {
                    collector.emitFinal(text)
                    cont.resume(returning: text)
                } else {
                    cont.resume(throwing: AmpBridgeError.executionFailed(
                        status: process.terminationStatus))
                }
            }
        }
    }

    func cancelConversation(_ conversationID: String) {
        processLock.lock()
        conversationGenerations[conversationID] =
            (conversationGenerations[conversationID] ?? 0) &+ 1
        let process = processes.removeValue(forKey: conversationID)
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func finishConversation(
        _ conversationID: String,
        generation: UInt64,
        process: Process?
    ) {
        processLock.lock()
        if let process, processes[conversationID] === process {
            processes[conversationID] = nil
        }
        if conversationGenerations[conversationID] == generation {
            conversationGenerations[conversationID] = nil
        }
        processLock.unlock()
    }

    /// Strip ANSI escape sequences (CSI/OSC) that a TUI writes even to a
    /// non-TTY, so a piped answer comes back as clean text.
    static func stripANSI(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]"
        ) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    static func textFromStreamJSON(_ input: String) -> String? {
        var assistantText = ""
        var resultText = ""
        for line in input.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            if type == "assistant",
               let message = object["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "text" {
                    assistantText += block["text"] as? String ?? ""
                }
            } else if type == "result", let result = object["result"] as? String {
                resultText = result
            }
        }
        if !assistantText.isEmpty { return assistantText }
        return resultText.isEmpty ? nil : resultText
    }
}

/// Thread-safe stdout accumulator for one Amp process. It recognizes complete
/// stream-json records for live answer updates, while every stdout chunk still
/// counts as provider activity even when it contains a private/non-text event.
private final class AmpTurnOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let activity = DispatchSemaphore(value: 0)
    private let onPartial: ((String) -> Void)?
    private var buffer = Data()
    private var latestVisibleText = ""
    private var lastPartialAt: Double = 0
    private var reachedEOF = false
    private var activityUptime = ProcessInfo.processInfo.systemUptime

    init(onPartial: ((String) -> Void)?) {
        self.onPartial = onPartial
    }

    var lastActivityUptime: Double {
        lock.lock()
        defer { lock.unlock() }
        return activityUptime
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        activityUptime = ProcessInfo.processInfo.systemUptime
        let snapshot = buffer
        lock.unlock()
        activity.signal()

        guard let raw = String(data: snapshot, encoding: .utf8) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeJSON = trimmed.first == "{"
        let visible = AmpBridge.textFromStreamJSON(raw)
            ?? (looksLikeJSON ? nil : AmpBridge.stripANSI(raw))
        if let visible {
            emitIfChanged(visible.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func markEOF() {
        lock.lock()
        reachedEOF = true
        lock.unlock()
        activity.signal()
    }

    func waitForActivity(timeout: TimeInterval) {
        _ = activity.wait(timeout: .now() + timeout)
    }

    func waitForEOF(timeout: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            lock.lock()
            let done = reachedEOF
            lock.unlock()
            if done { return }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            _ = activity.wait(timeout: .now() + min(remaining, 0.05))
        }
    }

    func emitFinal(_ text: String) {
        emitIfChanged(text, throttled: false)
    }

    private func emitIfChanged(_ text: String, throttled: Bool = true) {
        guard !text.isEmpty, let onPartial else { return }
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let canEmit = text != latestVisibleText
            && (!throttled || now - lastPartialAt > 0.1)
        if canEmit {
            latestVisibleText = text
            lastPartialAt = now
        }
        lock.unlock()
        if canEmit {
            DispatchQueue.main.async { onPartial(text) }
        }
    }
}

enum AmpBridgeError: LocalizedError {
    case processUnavailable(String)
    case executionFailed(status: Int32)
    case turnTimeout
    case maximumDurationExceeded

    var logLabel: String {
        switch self {
        case .turnTimeout: return "inactivity-timeout"
        case .maximumDurationExceeded: return "maximum-duration"
        default: return "failure"
        }
    }

    var errorDescription: String? {
        switch self {
        case .processUnavailable(let m):
            return m
        case .executionFailed(let status):
            return "Amp provider execution failed with status \(status)."
        case .turnTimeout:
            return "Amp was inactive for the configured turn timeout."
        case .maximumDurationExceeded:
            return "Amp reached the 30-minute turn safety limit."
        }
    }
}
