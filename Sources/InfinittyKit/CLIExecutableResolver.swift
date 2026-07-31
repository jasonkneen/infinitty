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
    case opencode
    case hermes
    case amp

    var binaryName: String { rawValue }

    /// Every binary name that can back this kind, most preferred first.
    ///
    /// OpenCode ships two: the stable `opencode` and the next build
    /// `opencode2`. We prefer `opencode2` because it is the one whose ACP
    /// `session/new` advertises the model list under `configOptions` — the
    /// stable line predates that surface. Name order beats PATH order, so an
    /// `opencode2` anywhere on PATH wins over an earlier `opencode`.
    var binaryNames: [String] {
        switch self {
        case .opencode: return ["opencode2", "opencode"]
        default:        return [binaryName]
        }
    }

    /// Explicit env override honored by the resolver. Matches the
    /// opencode-family naming (INFINITTY_<BIN>_EXECUTABLE) so users with
    /// multisite setups can pin a binary from their dotfiles.
    var envOverrideKey: String {
        switch self {
        case .codex:    return "INFINITTY_CODEX_EXECUTABLE"
        case .claude:   return "INFINITTY_CLAUDE_EXECUTABLE"
        case .opencode: return "INFINITTY_OPENCODE_EXECUTABLE"
        case .hermes:   return "INFINITTY_HERMES_EXECUTABLE"
        case .amp:      return "INFINITTY_AMP_EXECUTABLE"
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
        // Names in preference order, each swept across the whole PATH, so a
        // preferred name in a late directory still beats a fallback name in an
        // early one.
        for name in kind.binaryNames {
            for directory in rawPath.split(separator: ":") {
                add(URL(fileURLWithPath: String(directory)).appendingPathComponent(name))
            }

            switch kind {
            case .codex:
                // Codex ships as an app bundle with a `codex` resource inside.
                // Probe the standard install locations before falling through
                // to the brew / usr-local bins.
                add(URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"))
                add(URL(fileURLWithPath: NSString(string: "~/Applications/Codex.app/Contents/Resources/codex").expandingTildeInPath))
            case .claude, .hermes, .amp:
                // Claude Code's official install path is ~/.local/bin/ — npm
                // puts the claude shim there by default (`curl | sh` installer).
                // Hermes and Amp install their launchers there too.
                add(fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin")
                    .appendingPathComponent(name))
            case .opencode:
                // OpenCode ships as a node global / brew bin — the generic
                // PATH + /opt/homebrew/bin + /usr/local/bin probes cover it.
                break
            }

            add(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
            add(URL(fileURLWithPath: "/usr/local/bin/\(name)"))
        }

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
