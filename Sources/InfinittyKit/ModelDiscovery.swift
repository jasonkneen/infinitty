import Foundation

/// One selectable model in the composer's MODEL chip.
///
/// `id` is what gets routed to the CLI; `name` is what the user reads. The two
/// differ for every discovered provider — hermes routes
/// `openai-codex:gpt-5.6-sol` while showing `gpt-5.6-sol`, opencode routes
/// `opencode/claude-fable-5` while showing `Claude Fable 5` under an `opencode`
/// group.
struct DiscoveredModel: Equatable {
    let id: String
    let name: String
    let description: String?
    /// The provider's own current/default pick, marked "(default)" in the menu.
    let isDefault: Bool
    /// Reasoning efforts this model accepts. Empty when the provider says
    /// nothing, in which case the effort chip keeps its fixed list.
    let efforts: [String]
    let defaultEffort: String?
    /// Sub-provider parsed from a `prefix/Name` label. Only used to add a
    /// grouping level when a provider returns too many models to list flat.
    let group: String?
}

/// Per-provider discovery state, rendered directly by the model menu.
enum ProviderModels: Equatable {
    case loading
    case loaded([DiscoveredModel])
    /// Human-readable reason, shown in the menu so a broken provider explains
    /// itself instead of silently going missing.
    case failed(String)
}

/// Asks each provider's CLI what models it actually has, at runtime.
///
/// Every provider that *can* be asked, is asked — there is no typed-model-id
/// path. The three discovery shapes were confirmed against the real binaries:
///
///   codex     `model/list` on the warm app-server → `data[]`
///   opencode  `session/new` → `configOptions[id="model"].options[]`
///   hermes    `session/new` → `models.availableModels[]`
///
/// claude and amp have no listing surface at all (checked every subcommand and
/// flag), so they fall back to static tables. Amp's entries are *modes* — its
/// `-m low|medium|high|ultra` flag is the only model-adjacent lever it has.
actor ModelDiscovery {
    static let shared = ModelDiscovery()

    private var state: [PetAssistant.AgentChoice.Kind: ProviderModels] = [:]

    /// Resolve a provider's models, preferring in-memory state, then the disk
    /// cache (so the first menu open after launch is populated), then a live
    /// query. Never throws — a failure becomes `.failed` for the menu to show.
    func models(for kind: PetAssistant.AgentChoice.Kind) async -> ProviderModels {
        if let known = state[kind], known != .loading { return known }
        if let cached = ModelCatalogCache.load(for: kind), !cached.isEmpty {
            state[kind] = .loaded(cached)
            Task { await self.refresh(kind) }
            return .loaded(cached)
        }
        return await query(kind)
    }

    /// Drop any cached answer and ask the provider again. Backs the menu's
    /// Retry row.
    func refresh(_ kind: PetAssistant.AgentChoice.Kind) async {
        _ = await query(kind)
    }

    /// Test seam: forget everything resolved this session.
    func resetForTesting() { state = [:] }

    private func query(_ kind: PetAssistant.AgentChoice.Kind) async -> ProviderModels {
        state[kind] = .loading
        let resolved: ProviderModels
        do {
            let models = try await fetch(kind)
            resolved = models.isEmpty
                ? .failed("\(kind.providerLabel) returned no models.")
                : .loaded(models)
            if !models.isEmpty { ModelCatalogCache.store(models, for: kind) }
        } catch {
            resolved = .failed(Self.shortMessage(for: error))
        }
        state[kind] = resolved
        return resolved
    }

    private func fetch(
        _ kind: PetAssistant.AgentChoice.Kind
    ) async throws -> [DiscoveredModel] {
        switch kind {
        case .codex:
            return Self.parseCodexModels(try await CodexAppServer.shared.listModels())
        case .opencode:
            return Self.parseACPConfigOptionModels(
                try await ACPBridge.opencode.sessionModelSurface())
        case .hermes:
            return Self.parseACPAvailableModels(
                try await ACPBridge.hermes.sessionModelSurface())
        case .claude, .amp:
            return Self.staticModels(for: kind)
        case .auto, .apple:
            return []
        }
    }

    /// Menu rows are narrow; a wrapped stack trace is useless there. Keep the
    /// first sentence of the underlying failure.
    private static func shortMessage(for error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 120 ? String(firstLine.prefix(117)) + "…" : firstLine
    }

    // MARK: - Parsers

    /// `codex app-server` → `model/list` → `{data: [...]}`.
    static func parseCodexModels(_ result: [String: Any]) -> [DiscoveredModel] {
        guard let data = result["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { entry in
            guard (entry["hidden"] as? Bool) != true,
                  let id = (entry["model"] as? String) ?? (entry["id"] as? String)
            else { return nil }
            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
            return DiscoveredModel(
                id: id,
                name: (entry["displayName"] as? String) ?? id,
                description: entry["description"] as? String,
                isDefault: (entry["isDefault"] as? Bool) ?? false,
                efforts: efforts,
                defaultEffort: entry["defaultReasoningEffort"] as? String,
                group: nil)
        }
    }

    /// ACP stable path (opencode) — `session/new` → `configOptions[id="model"]`.
    /// Labels arrive as `provider/Model Name`; the prefix becomes `group` so it
    /// isn't repeated on every row.
    static func parseACPConfigOptionModels(_ result: [String: Any]) -> [DiscoveredModel] {
        guard let option = configOption(named: "model", in: result),
              let options = option["options"] as? [[String: Any]]
        else { return [] }
        let current = option["currentValue"] as? String
        return options.compactMap { entry in
            guard let value = entry["value"] as? String else { return nil }
            let label = (entry["name"] as? String) ?? value
            let (group, name) = splitPrefix(label)
            return DiscoveredModel(
                id: value,
                name: name,
                description: entry["description"] as? String,
                isDefault: value == current,
                efforts: [],
                defaultEffort: nil,
                group: group)
        }
    }

    /// Session-wide effort values opencode advertises alongside its models.
    static func parseACPConfigOptionEfforts(_ result: [String: Any]) -> [String] {
        guard let option = configOption(named: "effort", in: result),
              let options = option["options"] as? [[String: Any]]
        else { return [] }
        return options.compactMap { $0["value"] as? String }
    }

    /// ACP unstable path (hermes) — `session/new` → `models.availableModels[]`.
    /// The active model is flagged only by a `• current` suffix on its
    /// description; there is no boolean.
    static func parseACPAvailableModels(_ result: [String: Any]) -> [DiscoveredModel] {
        guard let models = result["models"] as? [String: Any],
              let available = models["availableModels"] as? [[String: Any]]
        else { return [] }
        return available.compactMap { entry in
            guard let id = entry["modelId"] as? String else { return nil }
            let description = entry["description"] as? String
            return DiscoveredModel(
                id: id,
                name: (entry["name"] as? String) ?? id,
                description: description,
                isDefault: description?.hasSuffix("• current") ?? false,
                efforts: [],
                defaultEffort: nil,
                group: nil)
        }
    }

    private static func configOption(
        named id: String, in result: [String: Any]
    ) -> [String: Any]? {
        (result["configOptions"] as? [[String: Any]])?
            .first { ($0["id"] as? String) == id }
    }

    /// `"opencode/Claude Fable 5"` → `("opencode", "Claude Fable 5")`.
    /// Labels without a prefix are returned whole.
    private static func splitPrefix(_ label: String) -> (group: String?, name: String) {
        guard let slash = label.firstIndex(of: "/") else { return (nil, label) }
        let group = String(label[label.startIndex..<slash])
        let name = String(label[label.index(after: slash)...])
        guard !group.isEmpty, !name.isEmpty else { return (nil, label) }
        return (group, name)
    }

    // MARK: - Static providers

    /// Providers with no listing surface. Claude's aliases are the ones
    /// `claude --help` documents for `--model`; amp's are the modes its `-m`
    /// flag accepts.
    static func staticModels(
        for kind: PetAssistant.AgentChoice.Kind
    ) -> [DiscoveredModel] {
        func model(_ id: String, _ name: String, isDefault: Bool = false) -> DiscoveredModel {
            DiscoveredModel(id: id, name: name, description: nil, isDefault: isDefault,
                            efforts: [], defaultEffort: nil, group: nil)
        }
        switch kind {
        case .claude:
            return [
                model("claude-fable-5", "Claude Fable 5", isDefault: true),
                model("claude-opus-4-8", "Claude Opus 4.8"),
                model("claude-sonnet-5", "Claude Sonnet 5"),
                model("claude-haiku-4-5", "Claude Haiku 4.5"),
            ]
        case .amp:
            return [
                model("low", "Low"),
                model("medium", "Medium"),
                model("high", "High", isDefault: true),
                model("ultra", "Ultra"),
            ]
        default:
            return []
        }
    }

    /// What the picker shows before any live query has answered: the last
    /// cached list, else the static table, else a single row standing for the
    /// agent's own configured default so the provider is still selectable.
    static func seedModels(
        for kind: PetAssistant.AgentChoice.Kind
    ) -> [DiscoveredModel] {
        if let cached = ModelCatalogCache.load(for: kind), !cached.isEmpty { return cached }
        let statics = staticModels(for: kind)
        if !statics.isEmpty { return statics }
        return [DiscoveredModel(
            id: "", name: "configured default", description: nil, isDefault: true,
            efforts: [], defaultEffort: nil, group: nil)]
    }

    // MARK: - Grouping

    /// Only opencode is big enough to need a third menu level today (123
    /// models). Everything else reads better flat.
    static let groupingThreshold = 20

    static func shouldGroup(_ models: [DiscoveredModel]) -> Bool {
        models.count > groupingThreshold && models.contains { $0.group != nil }
    }
}

/// Last known model list per provider, so the first menu open after launch is
/// populated instantly while a live refresh runs behind it.
///
/// Its own file rather than `infinitty.conf` — same reasoning as
/// `RecentCustomModels`: this is derived data and must never clobber the user's
/// hand-edited config.
enum ModelCatalogCache {
    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("infinitty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("model-catalog.json")
    }

    static func load(for kind: PetAssistant.AgentChoice.Kind) -> [DiscoveredModel]? {
        guard let entries = loadAll()[kind.configuredProviderKey] else { return nil }
        return entries.map(decode)
    }

    static func store(_ models: [DiscoveredModel], for kind: PetAssistant.AgentChoice.Kind) {
        guard let url = fileURL else { return }
        var all = loadAll()
        all[kind.configuredProviderKey] = models.map(encode)
        guard let data = try? JSONSerialization.data(
            withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Test seam: forget every cached provider list.
    static func clearForTesting() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadAll() -> [String: [[String: Any]]] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data)
                as? [String: [[String: Any]]]
        else { return [:] }
        return parsed
    }

    private static func encode(_ model: DiscoveredModel) -> [String: Any] {
        var entry: [String: Any] = [
            "id": model.id, "name": model.name,
            "isDefault": model.isDefault, "efforts": model.efforts,
        ]
        if let description = model.description { entry["description"] = description }
        if let defaultEffort = model.defaultEffort { entry["defaultEffort"] = defaultEffort }
        if let group = model.group { entry["group"] = group }
        return entry
    }

    private static func decode(_ entry: [String: Any]) -> DiscoveredModel {
        DiscoveredModel(
            id: (entry["id"] as? String) ?? "",
            name: (entry["name"] as? String) ?? "",
            description: entry["description"] as? String,
            isDefault: (entry["isDefault"] as? Bool) ?? false,
            efforts: (entry["efforts"] as? [String]) ?? [],
            defaultEffort: entry["defaultEffort"] as? String,
            group: entry["group"] as? String)
    }
}

extension PetAssistant.AgentChoice.Kind {
    /// Stable key for on-disk grouping. Mirrors `AgentChoice.configuredProvider`
    /// but lives on the Kind so cache code needn't build a whole choice.
    var configuredProviderKey: String {
        switch self {
        case .auto: return "auto"
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .hermes: return "hermes"
        case .amp: return "amp"
        case .apple: return "apple"
        }
    }
}
