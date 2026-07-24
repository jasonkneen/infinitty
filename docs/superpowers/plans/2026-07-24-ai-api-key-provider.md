# AI API-Key Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user enter an API key in Settings and drive the embedded chat/pet via OpenAI, Anthropic, or Vercel AI Gateway — funding the real Codex/Claude CLIs when the key matches, or a native Swift agent loop otherwise.

**Architecture:** Three phases. **A** — drop Apple as a chat provider, add an `apikey` provider with Keychain-stored keys, endpoint presets + custom URL, a `/models` fetch, and a Settings UI; the `apikey` path ships as plain (non-agentic) chat by reusing the existing OpenAI-compatible call. **B** — when the endpoint is Anthropic/OpenAI and the matching CLI is installed, route to that CLI with the key injected as an env var (full MCP/tools). **C** — a native OpenAI-compatible function-calling loop with cwd-jailed `bash`/file tools for gateway/custom routes.

**Tech Stack:** Swift 5 / AppKit / Security framework (Keychain) / Foundation URLSession. Module `InfinittyKit`. Tests: XCTest, run with `swift test --filter <Suite>`.

## Global Constraints

- Module is `InfinittyKit`; binaries `infinitty` + `infinitty-mcp`. Build: `swift build -c release`.
- **Run touched suites only:** `swift test --filter <SuiteName>` — the full `swift test` is flaky under load (SIGSEGVs non-deterministically). Never gate a task on the full suite.
- **No network in tests.** All HTTP goes through an injectable `URLSession`; tests use a `MockURLProtocol`.
- **API keys are NEVER written to the config file.** They live in the macOS Keychain: service `com.jasonkneen.infinitty`, account `ai-key:<endpoint>` (`ai-key:openai`, `ai-key:anthropic`, `ai-key:gateway`, `ai-key:custom`).
- Endpoint preset → base URL: `openai` → `https://api.openai.com/v1`; `anthropic` → `https://api.anthropic.com/v1`; `gateway` → `https://ai-gateway.vercel.sh/v1`; anything else → used verbatim as a custom URL.
- Native loop (Phase C): OpenAI function-calling dialect only; tools auto-run, jailed to the pane cwd tree; kill-switch env `INFINITTY_API_AGENT_NO_TOOLS=1` (chat-only, no tools); hard iteration cap `APIAgent.maxIterations = 12`.
- **Seeing changes requires rebuilding the `.app`** (`./scripts/ship-signed.sh` or `scripts/make-app.sh`) and relaunching `/Applications/Infinitty.app` — `swift build` alone changes nothing the user sees.

## File Structure

**New files (Sources/InfinittyKit/):**
- `AIEndpoint.swift` — endpoint enum: preset parsing, base-URL resolution, Keychain account, fundable-CLI mapping, default model. Shared by Config, Settings, routing, ModelDirectory, and the native loop.
- `Keychain.swift` — generic-password get/set/delete wrapper over the Security framework.
- `ModelDirectory.swift` — `GET {base}/models` fetch + parse, with an injectable session.
- `AIAgentClient.swift` (Phase C) — OpenAI chat-completions streaming client with tool-calling; the pure `SSEAccumulator`; the `ChatCompletionClient` protocol + `OpenAIChatClient`.
- `AIAgentTools.swift` (Phase C) — tool specs + execution (`bash`, `file_list`, `file_read`, `file_edit`, `file_write`) with the cwd path-jail.
- `APIAgent.swift` (Phase C) — the agent loop tying client + tools together, returning a `PetAssistant.AIOutcome`.

**Modified files:**
- `Config.swift` — add `aiEndpoint`; add `apikey` to the provider set; decouple `ai-endpoint` from `ai-base-url`; serialize `ai-endpoint`.
- `ProviderDiscovery.swift` — remove `.apple` from `InfinittyAIProvider` and its branches.
- `PetAssistant.swift` — remove the Apple chat path; add `Backend.apiAgent`; add `apiKey` to `.claude`/`.codex` (Phase B); `apikey` routing; wire the native loop (Phase C).
- `ClaudeBridge.swift` / `CodexAppServer.swift` — inject `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` when funding a CLI (Phase B).
- `Settings.swift` — new AI section (provider chips, endpoint dropdown, key field, model dropdown).

**New test files (Tests/InfinittyKitTests/):**
- `MockURLProtocol.swift` (shared helper), `AIEndpointTests.swift`, `KeychainTests.swift`, `ModelDirectoryTests.swift`, `APIAgentTests.swift`; extend `ConfigTests.swift`, `ProviderDiscoveryTests.swift`, `PetAssistantTests.swift`.

---

# Phase A — Foundation

## Task 1: `AIEndpoint` — presets, URLs, routing metadata

**Files:**
- Create: `Sources/InfinittyKit/AIEndpoint.swift`
- Test: `Tests/InfinittyKitTests/AIEndpointTests.swift`

**Interfaces:**
- Produces: `enum AIEndpoint: Equatable { case openai, anthropic, gateway, custom(String) }` with `static func parse(_:) -> AIEndpoint`, `var baseURL: String`, `var keychainAccount: String`, `var fundableCLI: InfinittyAIProvider?`, `var defaultModel: String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import InfinittyKit

final class AIEndpointTests: XCTestCase {
    func testPresetParsing() {
        XCTAssertEqual(AIEndpoint.parse("openai"), .openai)
        XCTAssertEqual(AIEndpoint.parse("Anthropic"), .anthropic)
        XCTAssertEqual(AIEndpoint.parse("gateway"), .gateway)
        XCTAssertEqual(AIEndpoint.parse("ai-gateway"), .gateway)
        XCTAssertEqual(AIEndpoint.parse("https://x.example/v1"), .custom("https://x.example/v1"))
    }

    func testBaseURLs() {
        XCTAssertEqual(AIEndpoint.openai.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(AIEndpoint.anthropic.baseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(AIEndpoint.gateway.baseURL, "https://ai-gateway.vercel.sh/v1")
        XCTAssertEqual(AIEndpoint.custom("https://x/v1").baseURL, "https://x/v1")
    }

    func testFundableCLI() {
        XCTAssertEqual(AIEndpoint.anthropic.fundableCLI, .claude)
        XCTAssertEqual(AIEndpoint.openai.fundableCLI, .codex)
        XCTAssertNil(AIEndpoint.gateway.fundableCLI)
        XCTAssertNil(AIEndpoint.custom("x").fundableCLI)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AIEndpointTests`
Expected: FAIL — `cannot find 'AIEndpoint' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The AI-provider endpoint chosen in Settings when `ai-provider = apikey`.
/// Single source of truth for base URLs, Keychain account keys, and which
/// CLI (if any) a native OpenAI/Anthropic key can fund.
public enum AIEndpoint: Equatable {
    case openai
    case anthropic
    case gateway
    case custom(String)

    /// Preset names map to the cases; anything else is a raw custom URL.
    public static func parse(_ raw: String) -> AIEndpoint {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "openai": return .openai
        case "anthropic": return .anthropic
        case "gateway", "vercel", "ai-gateway": return .gateway
        default: return .custom(raw.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Config token written to `ai-endpoint`.
    public var configValue: String {
        switch self {
        case .openai: return "openai"
        case .anthropic: return "anthropic"
        case .gateway: return "gateway"
        case .custom(let u): return u
        }
    }

    public var baseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gateway: return "https://ai-gateway.vercel.sh/v1"
        case .custom(let u): return u
        }
    }

    /// Keychain account so distinct endpoint keys coexist.
    public var keychainAccount: String {
        switch self {
        case .openai: return "ai-key:openai"
        case .anthropic: return "ai-key:anthropic"
        case .gateway: return "ai-key:gateway"
        case .custom: return "ai-key:custom"
        }
    }

    /// The CLI a native key for this endpoint can fund (Phase B), if installed.
    public var fundableCLI: InfinittyAIProvider? {
        switch self {
        case .anthropic: return .claude
        case .openai: return .codex
        case .gateway, .custom: return nil
        }
    }

    /// Fallback model id when none is configured yet.
    public var defaultModel: String {
        switch self {
        case .openai: return "gpt-5.6"
        case .anthropic: return "claude-sonnet-5"
        case .gateway: return "anthropic/claude-sonnet-5"
        case .custom: return "gpt-4o-mini"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AIEndpointTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinittyKit/AIEndpoint.swift Tests/InfinittyKitTests/AIEndpointTests.swift
git commit -m "feat(ai): AIEndpoint — presets, base URLs, fundable-CLI mapping

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Task 2: `Keychain` helper

**Files:**
- Create: `Sources/InfinittyKit/Keychain.swift`
- Test: `Tests/InfinittyKitTests/KeychainTests.swift`

**Interfaces:**
- Produces: `enum Keychain` with `static func set(_ value: String?, account: String, service: String = "com.jasonkneen.infinitty") -> Bool`, `static func get(account: String, service: String = "com.jasonkneen.infinitty") -> String?`. Passing `nil`/empty to `set` deletes the item.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import InfinittyKit

final class KeychainTests: XCTestCase {
    // Use a throwaway service so we never touch real credentials.
    let service = "com.jasonkneen.infinitty.tests"
    let account = "ai-key:test"

    override func tearDown() {
        _ = Keychain.set(nil, account: account, service: service)
        super.tearDown()
    }

    func testRoundTripSetGet() {
        XCTAssertTrue(Keychain.set("sk-abc123", account: account, service: service))
        XCTAssertEqual(Keychain.get(account: account, service: service), "sk-abc123")
    }

    func testOverwrite() {
        _ = Keychain.set("first", account: account, service: service)
        _ = Keychain.set("second", account: account, service: service)
        XCTAssertEqual(Keychain.get(account: account, service: service), "second")
    }

    func testDeleteViaNil() {
        _ = Keychain.set("x", account: account, service: service)
        XCTAssertTrue(Keychain.set(nil, account: account, service: service))
        XCTAssertNil(Keychain.get(account: account, service: service))
    }

    func testMissingReturnsNil() {
        XCTAssertNil(Keychain.get(account: "ai-key:absent", service: service))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KeychainTests`
Expected: FAIL — `cannot find 'Keychain' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Security

/// Thin wrapper over the Security framework for a single generic-password
/// item. Used to store AI provider API keys out of the plaintext config file.
public enum Keychain {
    public static let defaultService = "com.jasonkneen.infinitty"

    /// Store (or, with nil/empty, delete) the value. Returns true on success.
    @discardableResult
    public static func set(_ value: String?,
                           account: String,
                           service: String = defaultService) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        // Update if present, else add.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    public static func get(account: String,
                           service: String = defaultService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter KeychainTests`
Expected: PASS (4 tests). If macOS prompts for keychain access during tests, allow it; the throwaway service is cleaned up in `tearDown`.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinittyKit/Keychain.swift Tests/InfinittyKitTests/KeychainTests.swift
git commit -m "feat(ai): Keychain generic-password wrapper for API keys

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Task 3: `MockURLProtocol` + `ModelDirectory` (`/models` fetch)

**Files:**
- Create: `Sources/InfinittyKit/ModelDirectory.swift`
- Create: `Tests/InfinittyKitTests/MockURLProtocol.swift` (shared test helper)
- Test: `Tests/InfinittyKitTests/ModelDirectoryTests.swift`

**Interfaces:**
- Produces: `enum ModelDirectory { static func fetch(base: String, key: String, session: URLSession, completion: @escaping ([String]) -> Void) }` — GETs `{base}/models`, returns `data[].id`, or `[]` on any error.
- Produces (test helper): `final class MockURLProtocol: URLProtocol` with `static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?` and `static func session() -> URLSession`.

- [ ] **Step 1: Write the shared mock helper**

```swift
import Foundation
@testable import InfinittyKit

/// Deterministic offline HTTP for tests. Set `handler` per test.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "MockURLProtocol", code: 0)); return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import InfinittyKit

final class ModelDirectoryTests: XCTestCase {
    override func tearDown() { MockURLProtocol.handler = nil; super.tearDown() }

    func testParsesModelIDs() {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/v1/models"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-x")
            let body = #"{"data":[{"id":"gpt-5.6"},{"id":"o4-mini"}]}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let exp = expectation(description: "fetch")
        ModelDirectory.fetch(base: "https://api.openai.com/v1", key: "sk-x",
                             session: MockURLProtocol.session()) { models in
            XCTAssertEqual(models, ["gpt-5.6", "o4-mini"]); exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testEmptyOnError() {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404,
                             httpVersion: nil, headerFields: nil)!, Data("nope".utf8))
        }
        let exp = expectation(description: "fetch")
        ModelDirectory.fetch(base: "https://x/v1", key: "",
                             session: MockURLProtocol.session()) { models in
            XCTAssertEqual(models, []); exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter ModelDirectoryTests`
Expected: FAIL — `cannot find 'ModelDirectory' in scope`.

- [ ] **Step 4: Write the implementation**

```swift
import Foundation

/// Populates the Settings model dropdown from an OpenAI-compatible
/// `GET {base}/models`. Returns `[]` on any failure so the UI can fall back
/// to free-text entry.
public enum ModelDirectory {
    public static func fetch(base: String,
                             key: String,
                             session: URLSession = .shared,
                             completion: @escaping ([String]) -> Void) {
        let trimmed = base.hasSuffix("/models") ? base
            : base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models"
        guard let url = URL(string: trimmed) else { completion([]); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        session.dataTask(with: req) { data, resp, _ in
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["data"] as? [[String: Any]] else { completion([]); return }
            let ids = arr.compactMap { $0["id"] as? String }
            completion(ids)
        }.resume()
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ModelDirectoryTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/InfinittyKit/ModelDirectory.swift Tests/InfinittyKitTests/MockURLProtocol.swift Tests/InfinittyKitTests/ModelDirectoryTests.swift
git commit -m "feat(ai): ModelDirectory /models fetch + MockURLProtocol test helper

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Task 4: Config — add `apikey` provider + `ai-endpoint`; drop `apple`

**Files:**
- Modify: `Sources/InfinittyKit/Config.swift:63-69` (fields), `:258-266` (parse), `:390-393` (serialize)
- Test: `Tests/InfinittyKitTests/ConfigTests.swift` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces: `AppConfig.aiEndpoint: String?`; `aiProvider` now accepts `apikey` (and no longer `apple`); `ai-endpoint` no longer aliases `ai-base-url`.

**Note:** `ai-endpoint` currently aliases `ai-base-url` (a raw hint URL). This decouples them: `ai-base-url` stays the ghost-text hint URL; `ai-endpoint` becomes the chat provider's endpoint preset/URL. Legacy `ai-provider = apple` now falls through to the default `auto`.

- [ ] **Step 1: Write the failing test** (append to `ConfigTests.swift`)

```swift
func testParsesAPIKeyProviderAndEndpoint() {
    let cfg = AppConfig.parse("""
    ai-provider = apikey
    ai-endpoint = gateway
    ai-model = anthropic/claude-sonnet-5
    """)
    XCTAssertEqual(cfg.aiProvider, "apikey")
    XCTAssertEqual(cfg.aiEndpoint, "gateway")
    XCTAssertEqual(cfg.aiModel, "anthropic/claude-sonnet-5")
}

func testLegacyAppleProviderFallsToAuto() {
    let cfg = AppConfig.parse("ai-provider = apple")
    XCTAssertEqual(cfg.aiProvider, "auto")
}

func testEndpointDoesNotSetBaseURL() {
    let cfg = AppConfig.parse("ai-endpoint = openai")
    XCTAssertEqual(cfg.aiEndpoint, "openai")
    XCTAssertNil(cfg.aiBaseURL)
}

func testSerializeRoundTripsEndpoint() {
    var cfg = AppConfig()
    cfg.aiProvider = "apikey"; cfg.aiEndpoint = "anthropic"
    XCTAssertTrue(cfg.serialize().contains("ai-endpoint = anthropic"))
    XCTAssertTrue(cfg.serialize().contains("ai-provider = apikey"))
}
```

(If `AppConfig.parse` / `serialize` have different names in `ConfigTests.swift`, match the existing test helpers in that file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigTests`
Expected: FAIL — `value of type 'AppConfig' has no member 'aiEndpoint'`.

- [ ] **Step 3: Add the field** (`Config.swift`, near line 65 after `aiModel`)

```swift
    var aiModel: String?
    /// Chat provider endpoint when aiProvider == "apikey": a preset
    /// ("openai"/"anthropic"/"gateway") or a raw base URL. See AIEndpoint.
    var aiEndpoint: String?
```

- [ ] **Step 4: Update the parser** (`Config.swift:258-266`)

Replace:
```swift
            case "ai-base-url", "ai-endpoint":
                aiBaseURL = value
            case "ai-key", "ai-api-key":
                aiKey = value
            case "ai-model":
                aiModel = value
            case "ai-provider", "ai":
                let v = value.lowercased()
                if ["auto", "apple", "codex", "claude"].contains(v) { aiProvider = v }
```
with:
```swift
            case "ai-base-url":
                aiBaseURL = value
            case "ai-endpoint":
                aiEndpoint = value
            case "ai-key", "ai-api-key":
                aiKey = value
            case "ai-model":
                aiModel = value
            case "ai-provider", "ai":
                let v = value.lowercased()
                if ["auto", "codex", "claude", "apikey"].contains(v) { aiProvider = v }
```

- [ ] **Step 5: Update serialization** (`Config.swift`, near line 391)

Add after the `ai-model` serialize line:
```swift
        if let v = aiEndpoint, !v.isEmpty { out += "ai-endpoint = \(v)\n" }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter ConfigTests`
Expected: PASS (all ConfigTests, including the 4 new ones).

- [ ] **Step 7: Commit**

```bash
git add Sources/InfinittyKit/Config.swift Tests/InfinittyKitTests/ConfigTests.swift
git commit -m "feat(ai): config ai-provider=apikey + decoupled ai-endpoint; drop legacy apple

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Task 5: Drop Apple from `InfinittyAIProvider`

**Files:**
- Modify: `Sources/InfinittyKit/ProviderDiscovery.swift` (remove `.apple` case + branches)
- Test: `Tests/InfinittyKitTests/ProviderDiscoveryTests.swift` (extend)

**Interfaces:**
- Produces: `InfinittyAIProvider` with cases `codex`, `claude` only. `preferredProvider("apikey")` / `preferredProvider("apple")` → `nil`.

**Note:** `HintEngine.foundation` and `FoundationHint.swift` (ghost-text on-device hints) are a *separate* axis and stay untouched. Only the provider enum's Apple case is removed here.

- [ ] **Step 1: Write the failing test** (append to `ProviderDiscoveryTests.swift`)

```swift
func testProviderCasesAreCodexAndClaudeOnly() {
    XCTAssertEqual(Set(InfinittyAIProvider.allCases), [.codex, .claude])
}

func testApiKeyAndAppleResolveToNil() {
    let env = ["PATH": "/dev/null/no/bin"]  // no CLIs discoverable
    XCTAssertNil(ProviderDiscovery.preferredProvider(configured: "apikey", environment: env))
    XCTAssertNil(ProviderDiscovery.preferredProvider(configured: "apple", environment: env))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProviderDiscoveryTests`
Expected: FAIL — either a compile error referencing `.apple`, or `testProviderCasesAreCodexAndClaudeOnly` failing.

- [ ] **Step 3: Edit `ProviderDiscovery.swift`**

1. Remove the `case apple` from `InfinittyAIProvider` and its `displayName`/`shortLabel`/`binaryName` branches.
2. Delete `appleAvailability()` and remove it from the `availability()` array (leave `codex`, `claude`).
3. In `preferredProvider`, delete the `case "apple", "foundation", ...` branch and remove `.apple` from the `auto` preference loop (loop becomes `[.claude, .codex]`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProviderDiscoveryTests`
Expected: PASS. If other files fail to compile on the removed `.apple` (e.g. `PetAssistant.swift`), that's expected — Task 6 fixes the chat path. To keep this task's commit compiling, also apply Task 6's Apple removals now if the build breaks; otherwise commit after Task 6. (Recommended: do Tasks 5 and 6 back-to-back, single commit.)

- [ ] **Step 5: Commit** (after Task 6 if the build needs it)

```bash
git add Sources/InfinittyKit/ProviderDiscovery.swift Tests/InfinittyKitTests/ProviderDiscoveryTests.swift
git commit -m "refactor(ai): drop Apple from InfinittyAIProvider (hints keep on-device)

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Task 6: Remove the Apple chat path + add `Backend.apiAgent` (chat-only stub) + `apikey` routing

**Files:**
- Modify: `Sources/InfinittyKit/PetAssistant.swift` — `AgentChoice.Kind` (:1534), `configuredProvider` (:1547), `tint` (:1559), `Backend` (:1584), `resolveBackend` (:1621-1679), `askAI` switch (:1737-1780), `prewarm` switch (:1610-1618), `providerImage` (:607-612), and `PetAssistantFM` (:1870-1882).
- Test: `Tests/InfinittyKitTests/PetAssistantTests.swift` (extend)

**Interfaces:**
- Produces: `Backend` gains `case apiAgent(base: String, model: String)`; loses `case foundation`. `AgentChoice.Kind` loses `.apple`. `resolveBackend(config:environment:)` returns `.apiAgent(...)` when `aiProvider == "apikey"`.

- [ ] **Step 1: Write the failing test** (append to `PetAssistantTests.swift`)

```swift
func testApiKeyProviderRoutesToApiAgent() {
    var cfg = AppConfig()
    cfg.aiProvider = "apikey"
    cfg.aiEndpoint = "gateway"
    cfg.aiModel = "anthropic/claude-sonnet-5"
    let backend = PetAssistant.resolveBackend(config: cfg, environment: ["PATH": "/dev/null"])
    XCTAssertEqual(backend,
        .apiAgent(base: "https://ai-gateway.vercel.sh/v1", model: "anthropic/claude-sonnet-5"))
}

func testApiKeyDefaultsEndpointAndModel() {
    var cfg = AppConfig()
    cfg.aiProvider = "apikey"          // no endpoint/model set
    let backend = PetAssistant.resolveBackend(config: cfg, environment: ["PATH": "/dev/null"])
    XCTAssertEqual(backend,
        .apiAgent(base: "https://ai-gateway.vercel.sh/v1", model: "anthropic/claude-sonnet-5"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PetAssistantTests`
Expected: FAIL — `type 'PetAssistant.Backend' has no member 'apiAgent'`.

- [ ] **Step 3: Edit the `Backend` enum** (`PetAssistant.swift:1584`)

```swift
    enum Backend: Equatable {
        case none
        case command(String)
        case openai(base: String, key: String, model: String)
        case codex(model: String?)
        case claude(model: String?)
        case apiAgent(base: String, model: String)   // native OpenAI-compatible loop
    }
```
(Delete `case foundation`.)

- [ ] **Step 4: Add the `apikey` resolver** (`PetAssistant.swift`, replace the body of `resolveBackend(configuredProvider:config:environment:)` at :1656)

```swift
    private static func resolveBackend(
        configuredProvider: String, config: AppConfig, environment: [String: String]
    ) -> Backend {
        if configuredProvider.lowercased() == "apikey" {
            return resolveAPIKeyBackend(config: config, environment: environment)
        }
        let pick = ProviderDiscovery.preferredProvider(
            configured: configuredProvider, environment: environment)
        switch pick {
        case .codex: return .codex(model: config.codexModel)
        case .claude: return .claude(model: config.claudeModel)
        case .none: break
        }
        if let base = config.aiBaseURL, !base.isEmpty {
            return .openai(base: base, key: config.aiKey ?? "",
                           model: config.aiModel ?? "gpt-4o-mini")
        }
        if let cmd = config.hintCommand, !cmd.isEmpty { return .command(cmd) }
        return .none
    }

    /// Phase A: apikey mode always uses the native loop (plain chat until
    /// Phase C adds tools). Phase B routes anthropic/openai to a funded CLI.
    static func resolveAPIKeyBackend(
        config: AppConfig, environment: [String: String]
    ) -> Backend {
        let endpoint = AIEndpoint.parse(config.aiEndpoint ?? "gateway")
        let model = config.aiModel ?? endpoint.defaultModel
        return .apiAgent(base: endpoint.baseURL, model: model)
    }
```

- [ ] **Step 5: Update the `resolveBackend(choice:)` switch** (:1630-1645)

Remove the `case .apple:` branch (the composer never offers Apple — `buildChoices` already only adds `.claude`/`.codex`). Then:
- Change `AgentChoice.Kind` to `enum Kind: Equatable { case auto, claude, codex }`.
- Delete the `.apple` arms in `configuredProvider` (:1547) and `tint` (:1559).
- Delete `providerImage(for:)`'s `.apple` case (:612) and the `.apple` case in the row-glyph `symbolName`/`tint` around :1550-1564.
- At the composer's `visible` filter (:1071), drop `.filter { $0.kind != .apple }` — with `.apple` gone the filter no longer compiles; use the choices list directly.

- [ ] **Step 6: Update `askAI` and `prewarm` switches**

In `askAI` (:1737), delete the `case .foundation:` arm and add:
```swift
        case .apiAgent(let base, let model):
            askAPIAgent(base: base, model: model, cwd: cwd,
                        system: system, user: user, done: done)
```
In `prewarm` (:1616), change `.openai, .foundation, .command, .none` to `.openai, .apiAgent, .command, .none`.

Add the Phase-A stub (non-agentic chat) near `askOpenAI`:
```swift
    /// Phase A stub: plain chat via the OpenAI-compatible endpoint, key pulled
    /// from the Keychain. Phase C replaces this body with the agentic loop.
    private static func askAPIAgent(
        base: String, model: String, cwd: String,
        system: String, user: String,
        done: @escaping (AIOutcome) -> Void
    ) {
        let key = Keychain.get(account: keychainAccount(forBaseURL: base)) ?? ""
        askOpenAI(base: base, key: key, model: model, system: system, user: user, done: done)
    }

    /// Map a resolved base URL back to the endpoint's Keychain account.
    static func keychainAccount(forBaseURL base: String) -> String {
        for e in [AIEndpoint.openai, .anthropic, .gateway] where e.baseURL == base {
            return e.keychainAccount
        }
        return AIEndpoint.custom(base).keychainAccount
    }
```

- [ ] **Step 7: Delete `PetAssistantFM`** (:1870-1882) and any `.foundation`/`PetAssistantFM` references. Leave `FoundationHint.swift` and `HintEngine` alone.

- [ ] **Step 8: Build + run tests**

Run: `swift build 2>&1 | tail -20 && swift test --filter PetAssistantTests`
Expected: build succeeds; PetAssistantTests PASS (incl. 2 new). Fix any residual `.apple`/`.foundation` references the compiler flags.

- [ ] **Step 9: Commit** (folding Task 5 if not already committed)

```bash
git add Sources/InfinittyKit/PetAssistant.swift Sources/InfinittyKit/ProviderDiscovery.swift Tests/InfinittyKitTests/
git commit -m "feat(ai): Backend.apiAgent + apikey routing; remove Apple chat path

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Task 7: Settings UI — AI provider section

**Files:**
- Modify: `Sources/InfinittyKit/Settings.swift`

**Interfaces:**
- Consumes: `AIEndpoint`, `Keychain`, `ModelDirectory`, `AppConfig.aiProvider/aiEndpoint/aiModel`.
- Produces: no new public API; writes config (triggers live reload) + Keychain.

This task is AppKit UI (not unit-tested here — the underlying logic is already covered by Tasks 1–6). Deliverable is verified by building the app and opening Settings.

- [ ] **Step 1: Add an "AI" section** to the Settings window, following the existing control-construction pattern in `Settings.swift` (see the `hintsCheck`/`editConfigButton` block ~:68 and :243-295). Add:
  - A segmented control / chip row: `Auto`, `Codex`, `Claude`, `API Key`, bound to `config.aiProvider` (`auto`/`codex`/`claude`/`apikey`).
  - A container (shown only when `API Key` is selected) with:
    - `NSPopUpButton` endpoint: titles `OpenAI`, `Anthropic`, `Vercel AI Gateway`, `Custom…` → `AIEndpoint` `.openai/.anthropic/.gateway/.custom`.
    - `NSTextField` custom-URL (shown only when `Custom…`), bound to write `ai-endpoint = <url>`.
    - `NSSecureTextField` API key. On end-editing: `Keychain.set(field.stringValue, account: endpoint.keychainAccount)`; on load, show a placeholder `"key set"` / `"no key"` derived from `Keychain.get(...) != nil` (never echo the stored key).
    - `NSPopUpButton` model + a "Refresh" `NSButton`. Refresh calls `ModelDirectory.fetch(base: endpoint.baseURL, key: Keychain.get(...) ?? "")` and repopulates; selection writes `ai-model`. If the fetch returns `[]`, make the model control editable free-text.

- [ ] **Step 2: Persist on change.** When the chips/endpoint/model change, update the in-memory `AppConfig`, write it via the existing config-save path used by the current Settings controls (the same call `editConfigButton`/other controls use — search `Settings.swift` for where it writes the config file and reuse it), which triggers the live-reload watcher.

- [ ] **Step 3: Build the app and verify**

```bash
swift build -c release 2>&1 | tail -20
```
Then rebuild + relaunch the app bundle (`scripts/make-app.sh` or `./scripts/ship-signed.sh <ver>` for a signed build) and open Settings (⌘,). Verify: selecting **API Key** → **Vercel AI Gateway**, pasting a key, hitting **Refresh** lists models; picking one writes `ai-model`; the key is in Keychain (`security find-generic-password -s com.jasonkneen.infinitty -a ai-key:gateway`) and NOT in `~/.config/infinitty/infinitty.conf`.

- [ ] **Step 4: Commit**

```bash
git add Sources/InfinittyKit/Settings.swift
git commit -m "feat(ai): Settings AI section — provider chips, endpoint, key, model picker

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

**Phase A ships here:** enter a key, pick Gateway/OpenAI/Anthropic/custom, chat works as plain conversation (no tools yet).

---

# Phase B — Key-funded CLIs

## Task 8: Route Anthropic/OpenAI keys to the CLIs with injected env

**Files:**
- Modify: `Sources/InfinittyKit/PetAssistant.swift` — `Backend.codex`/`.claude` (add `apiKey`), `resolveAPIKeyBackend`, `askClaude`/`askCodex`, `prewarm`.
- Modify: `Sources/InfinittyKit/ClaudeBridge.swift:267-274` (env), `Sources/InfinittyKit/CodexAppServer.swift:189-194` (env).
- Test: `Tests/InfinittyKitTests/PetAssistantTests.swift` (extend)

**Interfaces:**
- Produces: `Backend.claude(model: String?, apiKey: String?)` and `Backend.codex(model: String?, apiKey: String?)`. `resolveAPIKeyBackend(config:environment:keyProvider:)` where `keyProvider: (AIEndpoint) -> String?` defaults to `{ Keychain.get(account: $0.keychainAccount) }`.
- Consumes: `AIEndpoint.fundableCLI`, `ProviderDiscovery.isAvailable`.

- [ ] **Step 1: Write the failing test**

```swift
func testAnthropicKeyFundsClaudeWhenInstalled() {
    let fakeClaude = makeFakeExecutable(named: "claude")   // add helper below
    defer { try? FileManager.default.removeItem(at: fakeClaude.deletingLastPathComponent()) }
    var cfg = AppConfig()
    cfg.aiProvider = "apikey"; cfg.aiEndpoint = "anthropic"; cfg.aiModel = "claude-sonnet-5"
    let env = ["INFINITTY_CLAUDE_EXECUTABLE": fakeClaude.path]
    let backend = PetAssistant.resolveAPIKeyBackend(
        config: cfg, environment: env, keyProvider: { _ in "sk-ant-test" })
    XCTAssertEqual(backend, .claude(model: "claude-sonnet-5", apiKey: "sk-ant-test"))
}

func testGatewayStillUsesApiAgent() {
    var cfg = AppConfig()
    cfg.aiProvider = "apikey"; cfg.aiEndpoint = "gateway"; cfg.aiModel = "m"
    let backend = PetAssistant.resolveAPIKeyBackend(
        config: cfg, environment: ["PATH": "/dev/null"], keyProvider: { _ in "k" })
    XCTAssertEqual(backend, .apiAgent(base: "https://ai-gateway.vercel.sh/v1", model: "m"))
}
```

Add a helper to `PetAssistantTests.swift` (mirrors `ProviderDiscoveryTests.makeExecutable`):
```swift
private func makeFakeExecutable(named: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(named)
    FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8),
        attributes: [.posixPermissions: 0o755])
    return url
}
```
(Confirm the env var `INFINITTY_CLAUDE_EXECUTABLE` matches `CLIExecutableResolver` — grep it; use the actual override key.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PetAssistantTests`
Expected: FAIL — `resolveAPIKeyBackend` has no `keyProvider:` param / `.claude` has no `apiKey:`.

- [ ] **Step 3: Add `apiKey` to the CLI backend cases** (`PetAssistant.swift:1584`)

```swift
        case codex(model: String?, apiKey: String?)
        case claude(model: String?, apiKey: String?)
```
Enum cases **cannot** carry default values, so every construction must pass `apiKey:` explicitly and every match must bind it. Find all sites:
```bash
grep -n "\.codex(\|\.claude(" Sources/InfinittyKit/PetAssistant.swift
```
- Constructions in the non-apikey `resolveBackend` → `.codex(model: config.codexModel, apiKey: nil)`, `.claude(model: config.claudeModel, apiKey: nil)`.
- Constructions in `resolveBackend(choice:)` → add `apiKey: nil`.
- Matches in `askAI` and `prewarm` → `case .codex(let model, let apiKey):` / `case .claude(let model, let apiKey):`.

- [ ] **Step 4: Update `resolveAPIKeyBackend`**

```swift
    static func resolveAPIKeyBackend(
        config: AppConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keyProvider: (AIEndpoint) -> String? = { Keychain.get(account: $0.keychainAccount) }
    ) -> Backend {
        let endpoint = AIEndpoint.parse(config.aiEndpoint ?? "gateway")
        let model = config.aiModel ?? endpoint.defaultModel
        let key = keyProvider(endpoint)
        if let cli = endpoint.fundableCLI,
           ProviderDiscovery.isAvailable(cli, environment: environment) {
            switch cli {
            case .claude: return .claude(model: model, apiKey: key)
            case .codex:  return .codex(model: model, apiKey: key)
            }
        }
        return .apiAgent(base: endpoint.baseURL, model: model)
    }
```

- [ ] **Step 5: Thread the key into the bridges**

In `askClaude`/`askCodex`, pass `apiKey` down to the bridge call (add an `apiKey: String?` param to the bridge `send`/`turn`/`warmUp` entry points; default `nil`). In `ClaudeBridge.swift` at the env block (:267-274) add:
```swift
            if let apiKey, !apiKey.isEmpty { env["ANTHROPIC_API_KEY"] = apiKey }
```
In `CodexAppServer.swift` at its env block (:189-194) add:
```swift
            if let apiKey, !apiKey.isEmpty { env["OPENAI_API_KEY"] = apiKey }
```
(Store the `apiKey` on the bridge instance when the turn/warmUp is requested so the spawn closure can read it; follow how `resolvedModel`/`system` are already threaded to the spawn.)

- [ ] **Step 6: Update `prewarm`** to pass the resolved `apiKey` when warming a funded CLI.

- [ ] **Step 7: Build + test**

Run: `swift build 2>&1 | tail -20 && swift test --filter PetAssistantTests`
Expected: build succeeds; PetAssistantTests PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/InfinittyKit/PetAssistant.swift Sources/InfinittyKit/ClaudeBridge.swift Sources/InfinittyKit/CodexAppServer.swift Tests/InfinittyKitTests/PetAssistantTests.swift
git commit -m "feat(ai): fund Claude/Codex CLIs with API key via injected env

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

**Phase B ships here:** an Anthropic/OpenAI key now drives the real agents (full MCP/tools), billed to the key.

---

# Phase C — Native agent loop

## Task 9: `SSEAccumulator` — pure streaming assembly

**Files:**
- Create: `Sources/InfinittyKit/AIAgentClient.swift` (start with the types + accumulator)
- Test: `Tests/InfinittyKitTests/APIAgentTests.swift`

**Interfaces:**
- Produces: `struct ChatMessage`, `struct ToolCall: Equatable { let id, name, arguments: String }`, `struct ToolSpec`, and `struct SSEAccumulator` with `mutating func consume(_ line: String)`, `var text: String`, `func toolCalls() -> [ToolCall]`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import InfinittyKit

final class APIAgentTests: XCTestCase {
    func testAccumulatesContentDeltas() {
        var acc = SSEAccumulator()
        acc.consume(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#)
        acc.consume(#"data: {"choices":[{"delta":{"content":"lo"}}]}"#)
        acc.consume("data: [DONE]")
        XCTAssertEqual(acc.text, "Hello")
        XCTAssertTrue(acc.toolCalls().isEmpty)
    }

    func testAssemblesToolCallAcrossChunks() {
        var acc = SSEAccumulator()
        acc.consume(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"cmd\":\"l"}}]}}]}"#)
        acc.consume(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"s\"}"}}]}}]}"#)
        acc.consume("data: [DONE]")
        XCTAssertEqual(acc.toolCalls(),
            [ToolCall(id: "call_1", name: "bash", arguments: "{\"cmd\":\"ls\"}")])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter APIAgentTests`
Expected: FAIL — `cannot find 'SSEAccumulator' in scope`.

- [ ] **Step 3: Implement the types + accumulator** (`AIAgentClient.swift`)

```swift
import Foundation

public struct ToolCall: Equatable {
    public let id: String
    public let name: String
    public let arguments: String
}

public struct ToolSpec {
    public let name: String
    public let description: String
    public let parameters: [String: Any]   // JSON Schema object
    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public struct ChatMessage {
    public let role: String            // system | user | assistant | tool
    public let content: String?
    public let toolCallId: String?     // for role == tool
    public let toolCalls: [ToolCall]?  // for role == assistant
    public init(role: String, content: String?,
                toolCallId: String? = nil, toolCalls: [ToolCall]? = nil) {
        self.role = role; self.content = content
        self.toolCallId = toolCallId; self.toolCalls = toolCalls
    }
}

/// Assembles an OpenAI streaming (SSE) chat response. Fed one `data:` line at
/// a time; concatenates `delta.content` and stitches `delta.tool_calls[]` by
/// index (id/name arrive once, arguments stream in fragments).
public struct SSEAccumulator {
    public private(set) var text = ""
    private var calls: [Int: (id: String, name: String, args: String)] = [:]
    private var order: [Int] = []
    public init() {}

    public mutating func consume(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else { return }
        let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" || payload.isEmpty { return }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return }
        if let content = delta["content"] as? String { text += content }
        if let tcs = delta["tool_calls"] as? [[String: Any]] {
            for tc in tcs {
                let idx = tc["index"] as? Int ?? 0
                if calls[idx] == nil { calls[idx] = ("", "", ""); order.append(idx) }
                if let id = tc["id"] as? String, !id.isEmpty { calls[idx]!.id = id }
                if let fn = tc["function"] as? [String: Any] {
                    if let name = fn["name"] as? String, !name.isEmpty { calls[idx]!.name = name }
                    if let args = fn["arguments"] as? String { calls[idx]!.args += args }
                }
            }
        }
    }

    public func toolCalls() -> [ToolCall] {
        order.compactMap { calls[$0] }.map { ToolCall(id: $0.id, name: $0.name, arguments: $0.args) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter APIAgentTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinittyKit/AIAgentClient.swift Tests/InfinittyKitTests/APIAgentTests.swift
git commit -m "feat(ai): SSEAccumulator — assemble streamed content + tool calls

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Task 10: `AIAgentTools` — cwd-jailed tool registry

**Files:**
- Create: `Sources/InfinittyKit/AIAgentTools.swift`
- Test: `Tests/InfinittyKitTests/APIAgentTests.swift` (extend)

**Interfaces:**
- Produces: `enum AIAgentTools` with `static func specs() -> [ToolSpec]`, `static func resolvePath(_ raw: String, cwd: String) -> String?` (nil if it escapes the cwd tree), `static func run(name: String, arguments: [String: Any], cwd: String) -> String`.

- [ ] **Step 1: Write the failing test** (append to `APIAgentTests.swift`)

```swift
func testPathJailRejectsEscapes() {
    let cwd = NSTemporaryDirectory()
    XCTAssertNil(AIAgentTools.resolvePath("../../etc/passwd", cwd: cwd))
    XCTAssertNil(AIAgentTools.resolvePath("/etc/passwd", cwd: cwd))
    XCTAssertNotNil(AIAgentTools.resolvePath("sub/file.txt", cwd: cwd))
}

func testFileWriteThenRead() {
    let dir = NSTemporaryDirectory() + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    _ = AIAgentTools.run(name: "file_write",
        arguments: ["path": "note.txt", "content": "hi there"], cwd: dir)
    let out = AIAgentTools.run(name: "file_read", arguments: ["path": "note.txt"], cwd: dir)
    XCTAssertTrue(out.contains("hi there"))
}

func testBashRunsInCwd() {
    let dir = NSTemporaryDirectory() + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let out = AIAgentTools.run(name: "bash", arguments: ["command": "echo hello-jail"], cwd: dir)
    XCTAssertTrue(out.contains("hello-jail"))
}

func testToolSpecsCoverExpectedTools() {
    let names = Set(AIAgentTools.specs().map { $0.name })
    XCTAssertEqual(names, ["bash", "file_list", "file_read", "file_edit", "file_write"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter APIAgentTests`
Expected: FAIL — `cannot find 'AIAgentTools' in scope`.

- [ ] **Step 3: Implement** (`AIAgentTools.swift`)

```swift
import Foundation

/// Built-in tools for the native agent loop. Auto-run, jailed to the pane's
/// cwd tree (file ops). `bash` runs in cwd but can still leave it — accepted
/// per the auto-run trust model; gated only by INFINITTY_API_AGENT_NO_TOOLS.
public enum AIAgentTools {
    public static func specs() -> [ToolSpec] {
        [
            ToolSpec(name: "bash", description: "Run a shell command in the working directory.",
                     parameters: ["type": "object",
                                  "properties": ["command": ["type": "string"]],
                                  "required": ["command"]]),
            ToolSpec(name: "file_list", description: "List files in a directory (relative to cwd).",
                     parameters: ["type": "object",
                                  "properties": ["path": ["type": "string"]]]),
            ToolSpec(name: "file_read", description: "Read a UTF-8 text file (relative to cwd).",
                     parameters: ["type": "object",
                                  "properties": ["path": ["type": "string"]],
                                  "required": ["path"]]),
            ToolSpec(name: "file_edit",
                     description: "Replace the first exact occurrence of `find` with `replace` in a file.",
                     parameters: ["type": "object",
                                  "properties": ["path": ["type": "string"],
                                                 "find": ["type": "string"],
                                                 "replace": ["type": "string"]],
                                  "required": ["path", "find", "replace"]]),
            ToolSpec(name: "file_write", description: "Create or overwrite a file (relative to cwd).",
                     parameters: ["type": "object",
                                  "properties": ["path": ["type": "string"],
                                                 "content": ["type": "string"]],
                                  "required": ["path", "content"]]),
        ]
    }

    /// Resolve `raw` under `cwd`; return nil if it escapes the cwd tree.
    public static func resolvePath(_ raw: String, cwd: String) -> String? {
        let cwdStd = (cwd as NSString).standardizingPath
        let joined = raw.hasPrefix("/") ? raw : (cwdStd as NSString).appendingPathComponent(raw)
        let std = (joined as NSString).standardizingPath
        let prefix = cwdStd.hasSuffix("/") ? cwdStd : cwdStd + "/"
        return (std == cwdStd || std.hasPrefix(prefix)) ? std : nil
    }

    public static func run(name: String, arguments: [String: Any], cwd: String) -> String {
        switch name {
        case "bash":
            guard let cmd = arguments["command"] as? String else { return "error: missing command" }
            return runBash(cmd, cwd: cwd)
        case "file_list":
            let rel = arguments["path"] as? String ?? "."
            guard let dir = resolvePath(rel, cwd: cwd) else { return "error: path escapes working directory" }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return items.sorted().joined(separator: "\n")
        case "file_read":
            guard let rel = arguments["path"] as? String,
                  let path = resolvePath(rel, cwd: cwd) else { return "error: bad path" }
            return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "error: cannot read \(rel)"
        case "file_write":
            guard let rel = arguments["path"] as? String,
                  let content = arguments["content"] as? String,
                  let path = resolvePath(rel, cwd: cwd) else { return "error: bad path" }
            do { try content.write(toFile: path, atomically: true, encoding: .utf8)
                 return "wrote \(rel) (\(content.utf8.count) bytes)" }
            catch { return "error: \(error.localizedDescription)" }
        case "file_edit":
            guard let rel = arguments["path"] as? String,
                  let find = arguments["find"] as? String,
                  let replace = arguments["replace"] as? String,
                  let path = resolvePath(rel, cwd: cwd),
                  let original = try? String(contentsOfFile: path, encoding: .utf8)
            else { return "error: bad path or unreadable file" }
            guard let range = original.range(of: find) else { return "error: `find` text not present" }
            var edited = original; edited.replaceSubrange(range, with: replace)
            do { try edited.write(toFile: path, atomically: true, encoding: .utf8)
                 return "edited \(rel)" }
            catch { return "error: \(error.localizedDescription)" }
        default:
            return "error: unknown tool \(name)"
        }
    }

    private static func runBash(_ cmd: String, cwd: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", cmd]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        let out = Pipe(); proc.standardOutput = out; proc.standardError = out
        do { try proc.run() } catch { return "error: \(error.localizedDescription)" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let capped = text.count > 16_000 ? String(text.prefix(16_000)) + "\n…[truncated]" : text
        return capped.isEmpty ? "(no output, exit \(proc.terminationStatus))" : capped
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter APIAgentTests`
Expected: PASS (6 tests total in the suite now).

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinittyKit/AIAgentTools.swift Tests/InfinittyKitTests/APIAgentTests.swift
git commit -m "feat(ai): AIAgentTools — cwd-jailed bash/file tool registry

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Task 11: `ChatCompletionClient` + `OpenAIChatClient` (streaming, with tools)

**Files:**
- Modify: `Sources/InfinittyKit/AIAgentClient.swift` (add protocol + client)
- Test: `Tests/InfinittyKitTests/APIAgentTests.swift` (extend, using `MockURLProtocol`)

**Interfaces:**
- Produces: `protocol ChatCompletionClient { func complete(messages: [ChatMessage], tools: [ToolSpec], onDelta: @escaping (String) -> Void, completion: @escaping (Result<ChatMessage, Error>) -> Void) }` and `struct OpenAIChatClient: ChatCompletionClient` (`init(base:key:model:session:)`).

- [ ] **Step 1: Write the failing test** (append to `APIAgentTests.swift`)

```swift
func testOpenAIClientStreamsFinalAssistantMessage() {
    MockURLProtocol.handler = { req in
        let sse = """
        data: {"choices":[{"delta":{"content":"All "}}]}

        data: {"choices":[{"delta":{"content":"done"}}]}

        data: [DONE]
        """
        return (HTTPURLResponse(url: req.url!, statusCode: 200,
                                httpVersion: nil, headerFields: nil)!, Data(sse.utf8))
    }
    let client = OpenAIChatClient(base: "https://x/v1", key: "k", model: "m",
                                  session: MockURLProtocol.session())
    let exp = expectation(description: "complete")
    var streamed = ""
    client.complete(messages: [ChatMessage(role: "user", content: "hi")], tools: [],
                    onDelta: { streamed += $0 }) { result in
        guard case .success(let msg) = result else { return XCTFail("expected success") }
        XCTAssertEqual(msg.content, "All done")
        XCTAssertEqual(streamed, "All done")
        exp.fulfill()
    }
    wait(for: [exp], timeout: 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter APIAgentTests`
Expected: FAIL — `cannot find 'OpenAIChatClient' in scope`.

- [ ] **Step 3: Implement** (add to `AIAgentClient.swift`)

```swift
public protocol ChatCompletionClient {
    func complete(messages: [ChatMessage],
                  tools: [ToolSpec],
                  onDelta: @escaping (String) -> Void,
                  completion: @escaping (Result<ChatMessage, Error>) -> Void)
}

public struct OpenAIChatClient: ChatCompletionClient {
    let base: String, key: String, model: String
    let session: URLSession
    public init(base: String, key: String, model: String, session: URLSession = .shared) {
        self.base = base; self.key = key; self.model = model; self.session = session
    }

    public func complete(messages: [ChatMessage], tools: [ToolSpec],
                         onDelta: @escaping (String) -> Void,
                         completion: @escaping (Result<ChatMessage, Error>) -> Void) {
        let urlStr = base.hasSuffix("/chat/completions") ? base
            : base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        guard let url = URL(string: urlStr) else {
            completion(.failure(NSError(domain: "OpenAIChatClient", code: 1))); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map(Self.encode),
        ]
        if !tools.isEmpty {
            payload["tools"] = tools.map { spec in
                ["type": "function",
                 "function": ["name": spec.name, "description": spec.description,
                              "parameters": spec.parameters]]
            }
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        session.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(err)); return }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                completion(.failure(NSError(domain: "OpenAIChatClient", code: code,
                    userInfo: [NSLocalizedDescriptionKey:
                        "HTTP \(code): \(String(decoding: data ?? Data(), as: UTF8.self).prefix(200))"])))
                return
            }
            var acc = SSEAccumulator()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                acc.consume(String(line))
            }
            onDelta(acc.text)   // non-incremental fallback; loop delivers final text
            let calls = acc.toolCalls()
            completion(.success(ChatMessage(role: "assistant",
                content: acc.text.isEmpty ? nil : acc.text,
                toolCalls: calls.isEmpty ? nil : calls)))
        }.resume()
    }

    static func encode(_ m: ChatMessage) -> [String: Any] {
        var d: [String: Any] = ["role": m.role]
        if let c = m.content { d["content"] = c }
        if let id = m.toolCallId { d["tool_call_id"] = id }
        if let calls = m.toolCalls {
            d["tool_calls"] = calls.map {
                ["id": $0.id, "type": "function",
                 "function": ["name": $0.name, "arguments": $0.arguments]]
            }
        }
        return d
    }
}
```

**Note on streaming:** `URLSession.dataTask` here buffers the full body before parsing — fine because the chat UI is non-streaming today (final answer only). `onDelta` is called once with the full text so the loop's interface is future-proof for true incremental streaming later.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter APIAgentTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinittyKit/AIAgentClient.swift Tests/InfinittyKitTests/APIAgentTests.swift
git commit -m "feat(ai): OpenAIChatClient — OpenAI-compatible chat with tools + SSE

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Task 12: `APIAgent.run` loop + wire into `askAI`

**Files:**
- Create: `Sources/InfinittyKit/APIAgent.swift`
- Modify: `Sources/InfinittyKit/PetAssistant.swift` — replace the `askAPIAgent` stub body (from Task 6) with the real loop.
- Test: `Tests/InfinittyKitTests/APIAgentTests.swift` (extend, with a fake client)

**Interfaces:**
- Produces: `enum APIAgent { static let maxIterations = 12; static func run(client: ChatCompletionClient, tools: [ToolSpec], cwd: String, system: String, user: String, onDelta: @escaping (String) -> Void, completion: @escaping (PetAssistant.AIOutcome) -> Void) }`.

- [ ] **Step 1: Write the failing test** (append to `APIAgentTests.swift`)

```swift
/// Scripted client: returns a tool call on turn 1, a final answer on turn 2.
final class ScriptedClient: ChatCompletionClient {
    var turn = 0
    func complete(messages: [ChatMessage], tools: [ToolSpec],
                  onDelta: @escaping (String) -> Void,
                  completion: @escaping (Result<ChatMessage, Error>) -> Void) {
        turn += 1
        if turn == 1 {
            completion(.success(ChatMessage(role: "assistant", content: nil,
                toolCalls: [ToolCall(id: "c1", name: "bash",
                                     arguments: #"{"command":"echo hi"}"#)])))
        } else {
            let sawToolResult = messages.contains { $0.role == "tool" }
            completion(.success(ChatMessage(role: "assistant",
                content: sawToolResult ? "final answer" : "no tool seen")))
        }
    }
}

func testAgentLoopExecutesToolThenFinishes() {
    let dir = NSTemporaryDirectory() + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let exp = expectation(description: "run")
    APIAgent.run(client: ScriptedClient(), tools: AIAgentTools.specs(), cwd: dir,
                 system: "sys", user: "do it", onDelta: { _ in }) { outcome in
        guard case .text(let t) = outcome else { return XCTFail("expected text") }
        XCTAssertEqual(t, "final answer")
        exp.fulfill()
    }
    wait(for: [exp], timeout: 3)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter APIAgentTests`
Expected: FAIL — `cannot find 'APIAgent' in scope`.

- [ ] **Step 3: Implement the loop** (`APIAgent.swift`)

```swift
import Foundation

/// Native OpenAI-compatible agent loop: chat → tool_calls → execute (cwd-jailed)
/// → feed results back → repeat until a plain answer or the iteration cap.
public enum APIAgent {
    public static let maxIterations = 12

    public static func run(
        client: ChatCompletionClient,
        tools: [ToolSpec],
        cwd: String,
        system: String,
        user: String,
        onDelta: @escaping (String) -> Void,
        completion: @escaping (PetAssistant.AIOutcome) -> Void
    ) {
        var messages = [ChatMessage(role: "system", content: system),
                        ChatMessage(role: "user", content: user)]

        func step(_ iteration: Int) {
            if iteration >= maxIterations {
                completion(.failure("Reached the \(maxIterations)-step limit without finishing."))
                return
            }
            client.complete(messages: messages, tools: tools, onDelta: onDelta) { result in
                switch result {
                case .failure(let err):
                    completion(.failure("API request failed: \(err.localizedDescription)"))
                case .success(let assistant):
                    guard let calls = assistant.toolCalls, !calls.isEmpty else {
                        completion(.text(assistant.content?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
                        return
                    }
                    messages.append(assistant)   // assistant turn with tool_calls
                    for call in calls {
                        let args = (try? JSONSerialization.jsonObject(
                            with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
                        let output = AIAgentTools.run(name: call.name, arguments: args, cwd: cwd)
                        messages.append(ChatMessage(role: "tool", content: output,
                                                    toolCallId: call.id))
                    }
                    step(iteration + 1)
                }
            }
        }
        step(0)
    }
}
```

- [ ] **Step 4: Wire into `askAI`** — replace the `askAPIAgent` body (`PetAssistant.swift`, from Task 6 Step 6)

```swift
    private static func askAPIAgent(
        base: String, model: String, cwd: String,
        system: String, user: String,
        done: @escaping (AIOutcome) -> Void
    ) {
        let key = Keychain.get(account: keychainAccount(forBaseURL: base)) ?? ""
        let noTools = ProcessInfo.processInfo.environment["INFINITTY_API_AGENT_NO_TOOLS"] == "1"
        let client = OpenAIChatClient(base: base, key: key, model: model)
        let tools = noTools ? [] : AIAgentTools.specs()
        APIAgent.run(client: client, tools: tools, cwd: cwd,
                     system: system, user: user, onDelta: { _ in }) { outcome in
            done(outcome)
        }
    }
```

- [ ] **Step 5: Build + test**

Run: `swift build 2>&1 | tail -20 && swift test --filter APIAgentTests && swift test --filter PetAssistantTests`
Expected: build succeeds; both suites PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/InfinittyKit/APIAgent.swift Sources/InfinittyKit/PetAssistant.swift Tests/InfinittyKitTests/APIAgentTests.swift
git commit -m "feat(ai): native APIAgent loop (tool-calling) wired into apikey chat

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

**Phase C ships here:** gateway/custom routes now drive an agentic chat with cwd-jailed bash/file tools.

---

## Task 13: End-to-end verification + dead-code confirmation

**Files:** none (verification) + possible deletions after approval.

- [ ] **Step 1: Full touched-suite sweep**

```bash
swift test --filter AIEndpointTests
swift test --filter KeychainTests
swift test --filter ModelDirectoryTests
swift test --filter ConfigTests
swift test --filter ProviderDiscoveryTests
swift test --filter PetAssistantTests
swift test --filter APIAgentTests
```
Expected: each PASS. (Do NOT run the full `swift test` as a gate — it is flaky under load.)

- [ ] **Step 2: Real app smoke test** — rebuild the bundle and relaunch:

```bash
swift build -c release 2>&1 | tail -5
```
Then `scripts/make-app.sh` (or `./scripts/ship-signed.sh <ver>`), relaunch `/Applications/Infinitty.app`. In Settings → AI:
- **Gateway** + key → chat performs a tool-using task (e.g. "list the files here and read README") and file/bash tools run in the pane cwd.
- **Anthropic** + key with `claude` installed → chat runs through Claude Code (verify with `INFINITTY_API_AGENT_NO_TOOLS` unset; confirm MCP tools available).
- Verify the key is absent from `~/.config/infinitty/infinitty.conf` and present in the Keychain.

- [ ] **Step 3: Dead-code confirmation** — list anything now unreferenced (candidates: `providerImage(for: .apple)` remnants, any `FoundationModels` imports in `PetAssistant.swift` after `PetAssistantFM` removal). **Ask the user before deleting** (per the repo's dead-code rule). `FoundationHint.swift` / `HintEngine.foundation` are intentionally retained (ghost-text hints).

- [ ] **Step 4: Final commit** (if any cleanup approved)

```bash
git add -A
git commit -m "chore(ai): remove dead Apple chat-path remnants

Claude-Session: https://claude.ai/code/session_01TJgBYkUo8crvqN9hC4wQA7"
```

---

## Spec Coverage Check

- §1 drop Apple / add API Key → Tasks 5, 6 (+ Task 4 config).
- §2 config + Keychain → Tasks 1, 2, 4.
- §3 Settings UI → Task 7.
- §4 `/models` fetch → Task 3.
- §5 routing matrix → Tasks 6 (apikey→apiAgent), 8 (endpoint→CLI funding).
- §6 key-funded CLIs → Task 8.
- §7 native loop → Tasks 9, 10, 11, 12.
- §8 testing → every task is TDD; Task 13 sweeps.

**Deviation from spec (noted):** §7 says "stream delta.content into the chat live." The chat has no token-streaming sink today (all backends return a final answer), so the native loop streams SSE internally and returns a final `AIOutcome` via the existing `done`/`onPetMessage` path. `APIAgent.run`/`ChatCompletionClient` keep an `onDelta` seam so true live streaming is a clean follow-up without an interface change.
