import Foundation

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
    private static let turnTimeoutSeconds: TimeInterval = 90

    init(executableURL: URL? = nil) {
        self.executableURLOverride = executableURL
    }

    func turn(
        prompt: String,
        system: String = "",
        model: String? = nil,
        cwd: String? = nil,
        conversationID: String? = nil,
        timeout: TimeInterval = AmpBridge.turnTimeoutSeconds,
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

                // Watchdog: never hang. Terminate at the deadline — that
                // closes stdout, so the blocking read below returns and we
                // resume with a bounded provider-execution error.
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        PetLog.log("AmpBridge.timeout after \(Int(timeout))s — terminating")
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Deterministic: read to EOF (child exit / watchdog close the
                // pipe), then inspect the exit status. No handler race.
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                if let conversationID, let conversationGeneration {
                    self.finishConversation(
                        conversationID,
                        generation: conversationGeneration,
                        process: process)
                }
                stderr.fileHandleForReading.readabilityHandler = nil

                let raw = String(data: data, encoding: .utf8) ?? ""
                let text = (AmpBridge.textFromStreamJSON(raw)
                    ?? AmpBridge.stripANSI(raw))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, !text.isEmpty {
                    if let onPartial {
                        DispatchQueue.main.async { onPartial(text) }
                    }
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

enum AmpBridgeError: LocalizedError {
    case processUnavailable(String)
    case executionFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .processUnavailable(let m):
            return m
        case .executionFailed(let status):
            return "Amp provider execution failed with status \(status)."
        }
    }
}
