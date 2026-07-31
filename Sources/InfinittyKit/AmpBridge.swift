import Foundation

/// Best-effort bridge for the Sourcegraph Amp CLI.
///
/// Amp ships **no headless mode** — `amp` with no subcommand launches an
/// interactive TUI (its only commands are login/logout/version/orb/threads).
/// Rather than scrape the TUI (fragile ANSI layout parsing) or hang the
/// turn, this bridge attempts a plain non-TTY one-shot — write the prompt
/// to stdin, read stdout until exit — bounded by a hard timeout. If Amp
/// answers (some builds handle piped stdin), great; if it doesn't, the
/// turn fails FAST with an actionable "open amp in a pane" message instead
/// of looking hung. This keeps Amp visible and selectable in the picker
/// without pretending to a streaming protocol it doesn't expose.
final class AmpBridge: @unchecked Sendable {
    static let shared = AmpBridge()

    private let executableURLOverride: URL?
    private static let turnTimeoutSeconds: TimeInterval = 90

    init(executableURL: URL? = nil) {
        self.executableURLOverride = executableURL
    }

    func turn(
        prompt: String,
        system: String = "",
        model: String? = nil,
        timeout: TimeInterval = AmpBridge.turnTimeoutSeconds,
        onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
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
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
                // Hint non-interactive use where Amp honors it.
                env["NO_COLOR"] = "1"
                env["TERM"] = "dumb"
                process.environment = env

                // Drain stderr on the side so a chatty child can't fill the
                // pipe and block before we've read stdout to EOF.
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    if handle.availableData.isEmpty { handle.readabilityHandler = nil }
                }

                PetLog.log("AmpBridge.spawn (best-effort one-shot)")
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: AmpBridgeError.processUnavailable(
                        "Failed to launch amp: \(error.localizedDescription)"))
                    return
                }
                try? stdin.fileHandleForWriting.write(contentsOf: Data(full.utf8))
                try? stdin.fileHandleForWriting.close()

                // Watchdog: never hang. Terminate at the deadline — that
                // closes stdout, so the blocking read below returns and we
                // resume with the clear interactive-only error.
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
                stderr.fileHandleForReading.readabilityHandler = nil

                let text = AmpBridge.stripANSI(
                    String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, !text.isEmpty {
                    if let onPartial {
                        DispatchQueue.main.async { onPartial(text) }
                    }
                    cont.resume(returning: text)
                } else {
                    cont.resume(throwing: AmpBridgeError.interactiveOnly)
                }
            }
        }
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
}

enum AmpBridgeError: LocalizedError {
    case processUnavailable(String)
    case interactiveOnly

    var errorDescription: String? {
        switch self {
        case .processUnavailable(let m):
            return m
        case .interactiveOnly:
            return "Amp is interactive-only — it didn't answer headlessly. "
                + "Open a pane (⌘T) and run `amp` to use it there."
        }
    }
}
