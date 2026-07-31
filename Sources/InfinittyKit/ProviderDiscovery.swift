import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Three-way AI provider switch for infinitty. Lifted from openclicky's
/// `OpenClickyProviderDiscovery`, renamed to drop the voice/talk framing
/// (infinitty is shell-first, not voice-first). Pure probing:
/// `availability()` reads file system, env, and (on macOS 26+)
/// `SystemLanguageModel.default.availability`. Nothing long-lived is
/// spawned. Safe to call from any thread.
public enum InfinittyAIProvider: String, CaseIterable, Equatable {
    /// Apple Foundation Models, on-device (macOS 26+ / Apple Intelligence).
    case apple
    /// OpenAI Codex CLI binary (`codex` on PATH).
    case codex
    /// Anthropic Claude Code CLI binary (`claude` on PATH).
    case claude
    /// OpenCode CLI binary (`opencode` on PATH), driven over ACP.
    case opencode
    /// Hermes Agent CLI binary (`hermes` on PATH), driven over ACP.
    case hermes
    /// Sourcegraph Amp CLI binary (`amp` on PATH).
    case amp

    public var displayName: String {
        switch self {
        case .apple:    return "Apple Intelligence"
        case .codex:    return "Codex"
        case .claude:   return "Claude"
        case .opencode: return "OpenCode"
        case .hermes:   return "Hermes"
        case .amp:      return "Amp"
        }
    }

    /// One-character chip label For a notch / provider chip UI.
    public var shortLabel: String {
        switch self {
        case .apple:    return "A"
        case .codex:    return "X"
        case .claude:   return "C"
        case .opencode: return "O"
        case .hermes:   return "H"
        case .amp:      return "M"
        }
    }

    /// CLI binary name to spawn. Empty for Apple (in-process Foundation
    /// Models, no subprocess).
    public var binaryName: String {
        switch self {
        case .apple:    return ""
        case .codex:    return "codex"
        case .claude:   return "claude"
        case .opencode: return "opencode"
        case .hermes:   return "hermes"
        case .amp:      return "amp"
        }
    }

    /// The CLI binary kind backing this provider, or nil for Apple
    /// (in-process Foundation Models, no subprocess). Drives the generic
    /// PATH probe in `ProviderDiscovery.cliAvailability`.
    var cliKind: CLIExecutableKind? {
        switch self {
        case .apple:    return nil
        case .codex:    return .codex
        case .claude:   return .claude
        case .opencode: return .opencode
        case .hermes:   return .hermes
        case .amp:      return .amp
        }
    }

    /// One-line "not installed" hint shown in the availability detail.
    var installHint: String {
        switch self {
        case .apple:    return "Apple Intelligence models require macOS 26 or later."
        case .codex:    return "Install the Codex CLI (developers.openai.com)."
        case .claude:   return "Install Claude Code (npm i -g @anthropic-ai/claude-code)."
        case .opencode: return "Install OpenCode (npm i -g opencode-ai) or set INFINITTY_OPENCODE_EXECUTABLE."
        case .hermes:   return "Install Hermes, or set INFINITTY_HERMES_EXECUTABLE."
        case .amp:      return "Install Amp (sourcegraph.com/amp) or set INFINITTY_AMP_EXECUTABLE."
        }
    }
}

public struct ProviderAvailability: Equatable {
    public let provider: InfinittyAIProvider
    public let isAvailable: Bool
    /// Short status pill (Ready / Detected / Missing / …).
    public let statusLabel: String
    /// Multi-line hint shown in Settings → AI and provider chips.
    public let detail: String
    /// Resolved binary path (for CLI providers). Always nil for Apple.
    public let executableURL: URL?
}

public enum ProviderDiscovery {
    /// Probe every provider. Order matches the visual order of the chips
    /// in Settings → AI (Apple → Codex → Claude). One IO pass; safe to
    /// call on the main thread at app launch or whenever a Settings UI
    /// becomes visible.
    public static func availability(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ProviderAvailability] {
        [
            appleAvailability(),
            codexAvailability(fileManager: fileManager, environment: environment),
            claudeAvailability(fileManager: fileManager, environment: environment),
            cliAvailability(.opencode, fileManager: fileManager, environment: environment),
            cliAvailability(.hermes, fileManager: fileManager, environment: environment),
            cliAvailability(.amp, fileManager: fileManager, environment: environment),
        ]
    }

    public static func isAvailable(
        _ provider: InfinittyAIProvider,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        availability(fileManager: fileManager, environment: environment)
            .first { $0.provider == provider }?.isAvailable ?? false
    }

    public static func appleAvailability() -> ProviderAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let ready = SystemLanguageModel.default.isAvailable
            return ProviderAvailability(
                provider: .apple,
                isAvailable: ready,
                statusLabel: ready ? "Ready" : "Unavailable",
                detail: ready
                    ? "Apple Foundation Models (on-device). No network, no key."
                    : "Apple Foundation Models require an Apple Intelligence–capable Mac.",
                executableURL: nil
            )
        }
        #endif
        return ProviderAvailability(
            provider: .apple,
            isAvailable: false,
            statusLabel: "macOS 26+",
            detail: "Apple Intelligence models require macOS 26 or later.",
            executableURL: nil
        )
    }

    public static func codexAvailability(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderAvailability {
        let url = CLIExecutableResolver.resolve(.codex, fileManager: fileManager, environment: environment)
        return ProviderAvailability(
            provider: .codex,
            isAvailable: url != nil,
            statusLabel: url == nil ? "Missing" : "Detected",
            detail: url == nil
                ? "Install the Codex CLI (developers.openai.com)."
                : "Codex CLI at \(url!.path)",
            executableURL: url
        )
    }

    public static func claudeAvailability(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderAvailability {
        let url = CLIExecutableResolver.resolve(.claude, fileManager: fileManager, environment: environment)
        return ProviderAvailability(
            provider: .claude,
            isAvailable: url != nil,
            statusLabel: url == nil ? "Missing" : "Detected",
            detail: url == nil
                ? "Install Claude Code (npm i -g @anthropic-ai/claude-code)."
                : "Claude Code CLI at \(url!.path)",
            executableURL: url
        )
    }

    /// Generic PATH probe for a CLI-backed provider (opencode/hermes/amp).
    /// Same shape as `codexAvailability`/`claudeAvailability` but reads the
    /// binary + env override + install hint off the provider itself, so a
    /// new CLI provider is one enum case instead of a new function.
    public static func cliAvailability(
        _ provider: InfinittyAIProvider,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderAvailability {
        guard let kind = provider.cliKind else {
            return appleAvailability()
        }
        let url = CLIExecutableResolver.resolve(
            kind, fileManager: fileManager, environment: environment)
        return ProviderAvailability(
            provider: provider,
            isAvailable: url != nil,
            statusLabel: url == nil ? "Missing" : "Detected",
            detail: url == nil
                ? provider.installHint
                : "\(provider.displayName) CLI at \(url!.path)",
            executableURL: url
        )
    }

    /// Resolve the user-configured provider to a concrete pick, honoring
    /// `ai-provider` from the infinitty config (or its env override). When
    /// the value is "auto" / unset, prefer Claude → Codex → Apple so user's
    /// local CLI tools get first crack before falling back to the slow
    /// Apple-on-device model.
    ///
    /// Returns nil when the configured provider isn't available, so the
    /// caller can fall through to its own default (hint engine → .none;
    /// pet assistant → curl up ("no AI configured")).
    public static func preferredProvider(
        configured: String?,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> InfinittyAIProvider? {
        let normalized = (configured ?? "auto").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let probe = availability(fileManager: fileManager, environment: environment)

        switch normalized {
        case "", "auto":
            for candidate in [InfinittyAIProvider.claude, .codex, .apple] {
                if let entry = probe.first(where: { $0.provider == candidate }),
                   entry.isAvailable {
                    return candidate
                }
            }
            return nil
        case "apple", "foundation", "ondevice", "on-device":
            return probe.first { $0.provider == .apple }?.isAvailable == true ? .apple : nil
        case "codex", "openai":
            return probe.first { $0.provider == .codex }?.isAvailable == true ? .codex : nil
        case "claude", "anthropic":
            return probe.first { $0.provider == .claude }?.isAvailable == true ? .claude : nil
        case "opencode", "openclaw", "oc":
            return probe.first { $0.provider == .opencode }?.isAvailable == true ? .opencode : nil
        case "hermes", "nous":
            return probe.first { $0.provider == .hermes }?.isAvailable == true ? .hermes : nil
        case "amp", "sourcegraph":
            return probe.first { $0.provider == .amp }?.isAvailable == true ? .amp : nil
        default:
            return nil
        }
    }
}
