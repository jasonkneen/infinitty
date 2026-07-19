import Foundation

/// Locates installed `codex` and `claude` binaries on this Mac. Pure probe —
/// no persistent state, no user-config mutations. Lifted from
/// openclicky's `CodexRuntimeLocator` and
/// `ClaudeAgentSDKAPI.findExecutable`, with the Codex-specific fiddling
/// (release-bundle-only) dropped: infinitty follows the opencode sibling
/// pattern of "use what's already installed", and explicit env overrides
/// are sanity-checked rather than trusted.
enum CLIExecutableKind: String, CaseIterable {
    case codex
    case claude

    var binaryName: String { rawValue }

    /// Explicit env override honored by the resolver. Matches the
    /// opencode-family naming (INFINITTY_<BIN>_EXECUTABLE) so users with
    /// multisite setups can pin a binary from their dotfiles.
    var envOverrideKey: String {
        switch self {
        case .codex:  return "INFINITTY_CODEX_EXECUTABLE"
        case .claude: return "INFINITTY_CLAUDE_EXECUTABLE"
        }
    }
}

enum CLIExecutableResolver {
    /// All candidate locations for `kind`, in precedence order. Pure
    /// probing; never mutates anything. First match wins.
    static func candidates(
        for kind: CLIExecutableKind,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL.path
            guard !seen.contains(standardized) else { return }
            seen.insert(standardized)
            out.append(url)
        }

        if let override = environment[kind.envOverrideKey],
           !override.isEmpty {
            add(URL(fileURLWithPath: override))
        }

        let rawPath = environment["PATH"] ?? defaultPATH
        for directory in rawPath.split(separator: ":") {
            add(URL(fileURLWithPath: String(directory))
                .appendingPathComponent(kind.binaryName))
        }

        switch kind {
        case .codex:
            // Codex ships as an app bundle with a `codex` resource inside.
            // Probe the standard install locations before falling through
            // to the brew / usr-local bins.
            add(URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"))
            add(URL(fileURLWithPath: NSString(string: "~/Applications/Codex.app/Contents/Resources/codex").expandingTildeInPath))
        case .claude:
            // Claude Code's official install path is ~/.local/bin/ — npm
            // puts the claude shim there by default (`curl | sh` installer).
            add(fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin")
                .appendingPathComponent(kind.binaryName))
        }

        add(URL(fileURLWithPath: "/opt/homebrew/bin/\(kind.binaryName)"))
        add(URL(fileURLWithPath: "/usr/local/bin/\(kind.binaryName)"))

        return out.filter { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// The first candidate that's actually executable. Nil when nothing
    /// matched — that's a normal "not installed" state, never an error.
    static func resolve(
        _ kind: CLIExecutableKind,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        candidates(for: kind, fileManager: fileManager, environment: environment).first
    }

    private static let defaultPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
}
