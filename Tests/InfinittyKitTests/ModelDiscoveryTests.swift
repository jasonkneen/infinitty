import Foundation
import XCTest
@testable import InfinittyKit

/// Fixtures below are trimmed captures of real responses, recorded 2026-07-29
/// from `codex app-server` 0.145.0, `opencode2 acp` 0.0.0-next-16420, and
/// `hermes acp --accept-hooks` 0.19.0.
final class ModelDiscoveryTests: XCTestCase {

    private func json(_ raw: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Codex: model/list

    private let codexModelList = """
    {
      "data": [
        {
          "id": "gpt-5.6-sol",
          "model": "gpt-5.6-sol",
          "displayName": "GPT-5.6-Sol",
          "description": "Latest frontier agentic coding model.",
          "hidden": false,
          "supportedReasoningEfforts": [
            {"reasoningEffort": "low", "description": "Fast responses"},
            {"reasoningEffort": "high", "description": "Greater depth"},
            {"reasoningEffort": "ultra", "description": "Maximum reasoning"}
          ],
          "defaultReasoningEffort": "low",
          "isDefault": true
        },
        {
          "id": "gpt-5.6-terra",
          "model": "gpt-5.6-terra",
          "displayName": "GPT-5.6-Terra",
          "description": "Balanced agentic coding model for everyday work.",
          "hidden": false,
          "supportedReasoningEfforts": [
            {"reasoningEffort": "medium", "description": "Balanced"}
          ],
          "defaultReasoningEffort": "medium",
          "isDefault": false
        },
        {
          "id": "gpt-5.3-internal",
          "model": "gpt-5.3-internal",
          "displayName": "Internal",
          "hidden": true,
          "supportedReasoningEfforts": [],
          "isDefault": false
        }
      ]
    }
    """

    func testParsesCodexModelList() throws {
        let models = ModelDiscovery.parseCodexModels(try json(codexModelList))

        XCTAssertEqual(models.map(\.id), ["gpt-5.6-sol", "gpt-5.6-terra"],
                       "hidden models must not reach the menu")
        XCTAssertEqual(models.map(\.name), ["GPT-5.6-Sol", "GPT-5.6-Terra"])
        XCTAssertEqual(models[0].description, "Latest frontier agentic coding model.")
        XCTAssertTrue(models[0].isDefault)
        XCTAssertFalse(models[1].isDefault)
        XCTAssertEqual(models[0].efforts, ["low", "high", "ultra"])
        XCTAssertEqual(models[0].defaultEffort, "low")
        XCTAssertNil(models[0].group, "codex names carry no provider prefix")
    }

    func testCodexModelListWithoutDataYieldsNothing() throws {
        XCTAssertTrue(ModelDiscovery.parseCodexModels(try json("{}")).isEmpty)
    }

    // MARK: - OpenCode: session/new configOptions

    private let opencodeSessionNew = """
    {
      "sessionId": "ses_05301282effeoQAlRVkCNVHpf2",
      "configOptions": [
        {
          "id": "model",
          "name": "Model",
          "category": "model",
          "type": "select",
          "currentValue": "opencode/claude-fable-5",
          "options": [
            {"value": "fireworks-ai/accounts/fireworks/models/kimi-k3",
             "name": "fireworks-ai/Kimi K3"},
            {"value": "opencode/claude-fable-5", "name": "opencode/Claude Fable 5"},
            {"value": "opencode/big-pickle", "name": "opencode/Big Pickle"}
          ]
        },
        {
          "id": "effort",
          "name": "Effort",
          "category": "thought_level",
          "type": "select",
          "currentValue": "low",
          "options": [
            {"value": "low", "name": "Low"},
            {"value": "high", "name": "High"}
          ]
        },
        {
          "id": "mode",
          "name": "Session Mode",
          "category": "mode",
          "type": "select",
          "currentValue": "build",
          "options": [{"value": "build", "name": "Build"}]
        }
      ]
    }
    """

    func testParsesOpenCodeConfigOptions() throws {
        let models = ModelDiscovery.parseACPConfigOptionModels(try json(opencodeSessionNew))

        XCTAssertEqual(models.count, 3, "only the model option becomes models")
        XCTAssertEqual(models.map(\.id), [
            "fireworks-ai/accounts/fireworks/models/kimi-k3",
            "opencode/claude-fable-5",
            "opencode/big-pickle",
        ])
        XCTAssertEqual(models.map(\.name), ["Kimi K3", "Claude Fable 5", "Big Pickle"],
                       "the provider prefix moves to `group`, out of the label")
        XCTAssertEqual(models.map(\.group), ["fireworks-ai", "opencode", "opencode"])
        XCTAssertEqual(models.filter(\.isDefault).map(\.id), ["opencode/claude-fable-5"],
                       "currentValue marks the default")
    }

    func testParsesOpenCodeSessionEfforts() throws {
        XCTAssertEqual(
            ModelDiscovery.parseACPConfigOptionEfforts(try json(opencodeSessionNew)),
            ["low", "high"])
    }

    func testOpenCodeParsersIgnoreAHermesShapedResponse() throws {
        XCTAssertTrue(
            ModelDiscovery.parseACPConfigOptionModels(try json(hermesSessionNew)).isEmpty)
    }

    // MARK: - Hermes: session/new models.availableModels

    private let hermesSessionNew = """
    {
      "sessionId": "fd8833ca-0376-44cd-95ed-78fe4efd2a4c",
      "models": {
        "availableModels": [
          {"modelId": "openai-codex:gpt-5.6-sol",
           "name": "gpt-5.6-sol",
           "description": "Provider: OpenAI Codex • current"},
          {"modelId": "openai-codex:gpt-5.6-terra",
           "name": "gpt-5.6-terra",
           "description": "Provider: OpenAI Codex"}
        ]
      }
    }
    """

    func testParsesHermesAvailableModels() throws {
        let models = ModelDiscovery.parseACPAvailableModels(try json(hermesSessionNew))

        XCTAssertEqual(models.map(\.id),
                       ["openai-codex:gpt-5.6-sol", "openai-codex:gpt-5.6-terra"],
                       "the prefixed modelId is what gets routed")
        XCTAssertEqual(models.map(\.name), ["gpt-5.6-sol", "gpt-5.6-terra"],
                       "the bare name is what gets shown")
        XCTAssertEqual(models.filter(\.isDefault).map(\.name), ["gpt-5.6-sol"],
                       "`• current` marks the default")
        XCTAssertNil(models[0].group, "10 models need no sub-grouping")
    }

    func testHermesParserIgnoresAnOpenCodeShapedResponse() throws {
        XCTAssertTrue(
            ModelDiscovery.parseACPAvailableModels(try json(opencodeSessionNew)).isEmpty)
    }

    func testHermesProviderLabelsBecomeGroupsWithoutDroppingModelIDs() throws {
        let result = try json("""
        {
          "models": {
            "availableModels": [
              {
                "modelId": "openrouter:anthropic/claude-sonnet-5",
                "name": "OpenRouter · anthropic/claude-sonnet-5",
                "description": "Provider: OpenRouter • current (active)"
              },
              {
                "modelId": "openai-codex:gpt-5.6-sol",
                "name": "OpenAI Codex · gpt-5.6-sol",
                "description": "Provider: OpenAI Codex"
              }
            ]
          }
        }
        """)
        let models = ModelDiscovery.parseACPAvailableModels(result)

        XCTAssertEqual(models.map(\.id), [
            "openrouter:anthropic/claude-sonnet-5", "openai-codex:gpt-5.6-sol",
        ])
        XCTAssertEqual(models.map(\.name), ["anthropic/claude-sonnet-5", "gpt-5.6-sol"])
        XCTAssertEqual(models.map(\.group), ["OpenRouter", "OpenAI Codex"])
        XCTAssertTrue(models[0].isDefault, "current marker need not be the final suffix")
    }

    // MARK: - Static providers

    func testClaudeModelsAreStaticAndNonEmpty() {
        let models = ModelDiscovery.staticModels(for: .claude)
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.contains { $0.id == "claude-fable-5" })
        XCTAssertEqual(models.filter(\.isDefault).count, 1)
        XCTAssertTrue(models.allSatisfy {
            $0.efforts == ["low", "medium", "high", "xhigh", "max"]
        })
    }

    func testNativeEffortNormalizationUsesProviderSafeDefaults() {
        XCTAssertEqual(NativeReasoningEffort.codexValue(" Max "), "max")
        XCTAssertEqual(NativeReasoningEffort.codexValue("XHIGH"), "xhigh")
        XCTAssertEqual(NativeReasoningEffort.codexValue("Ultra"), "ultra")
        XCTAssertEqual(NativeReasoningEffort.codexValue("Auto"), "medium")
        XCTAssertEqual(NativeReasoningEffort.codexValue("unexpected"), "medium")

        XCTAssertEqual(NativeReasoningEffort.claudeValue("XHIGH"), "xhigh")
        XCTAssertEqual(NativeReasoningEffort.claudeValue("Max"), "max")
        XCTAssertNil(NativeReasoningEffort.claudeValue("Auto"))
        XCTAssertNil(NativeReasoningEffort.claudeValue("None"))
        XCTAssertNil(NativeReasoningEffort.claudeValue("Ultra"))
    }

    func testProviderScopedModelLabelsDropRedundantProviderNames() {
        let claude = PetAssistant.AgentChoice(
            DiscoveredModel(
                id: "claude-sonnet-5", name: "Claude Sonnet 5",
                description: nil, isDefault: true, efforts: [],
                defaultEffort: nil, group: nil),
            kind: .claude, symbolName: "a.circle")
        let codex = PetAssistant.AgentChoice(
            DiscoveredModel(
                id: "gpt-5.6-sol", name: "GPT-5.6-Sol",
                description: nil, isDefault: true, efforts: [],
                defaultEffort: nil, group: nil),
            kind: .codex, symbolName: "o.circle")

        XCTAssertEqual(PetAssistantPanelView.shortModelLabel(for: claude), "Sonnet 5")
        XCTAssertEqual(PetAssistantPanelView.shortModelLabel(for: codex), "GPT-5.6-Sol")
    }

    func testCodexSeedCatalogNeverShowsConfiguredDefaultPlaceholder() {
        let models = ModelDiscovery.staticModels(for: .codex)
        XCTAssertTrue(models.contains { $0.id == "gpt-5.6-sol" && $0.isDefault })
        XCTAssertFalse(models.contains { $0.name.localizedCaseInsensitiveContains(
            "configured default") })
    }

    func testAmpExposesModesNotModels() {
        let modes = ModelDiscovery.staticModels(for: .amp)
        XCTAssertEqual(modes.map(\.id), ["low", "medium", "high", "ultra"],
                       "amp's -m flag takes a mode, not a model id")
    }

    // MARK: - Grouping

    func testGroupingOnlyKicksInForLargeProviders() {
        let few = (0..<3).map {
            DiscoveredModel(id: "p/m\($0)", name: "M\($0)", description: nil,
                            isDefault: false, efforts: [], defaultEffort: nil, group: "p")
        }
        XCTAssertFalse(ModelDiscovery.shouldGroup(few),
                       "a short list stays flat even when prefixed")

        let many = (0..<25).map {
            DiscoveredModel(id: "p/m\($0)", name: "M\($0)", description: nil,
                            isDefault: false, efforts: [], defaultEffort: nil, group: "p")
        }
        XCTAssertTrue(ModelDiscovery.shouldGroup(many))

        let manyUngrouped = (0..<25).map {
            DiscoveredModel(id: "m\($0)", name: "M\($0)", description: nil,
                            isDefault: false, efforts: [], defaultEffort: nil, group: nil)
        }
        XCTAssertFalse(ModelDiscovery.shouldGroup(manyUngrouped),
                       "no prefix means nothing to group by")
    }

    // MARK: - Cache

    func testCacheRoundTripsAndSurvivesAReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitty-model-cache-\(UUID().uuidString)")
        let cacheURL = directory.appendingPathComponent("model-catalog.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let models = [
            DiscoveredModel(id: "gpt-5.6-sol", name: "GPT-5.6-Sol", description: "d",
                            isDefault: true, efforts: ["low", "high"],
                            defaultEffort: "low", group: nil),
        ]
        ModelCatalogCache.store(models, for: .codex, at: cacheURL)

        XCTAssertEqual(ModelCatalogCache.load(for: .codex, from: cacheURL), models)
        XCTAssertNil(ModelCatalogCache.load(for: .hermes, from: cacheURL),
                     "an unwritten provider must read back as absent, not empty")
    }
}
