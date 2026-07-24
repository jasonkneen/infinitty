# AI API-Key Provider — Design

**Date:** 2026-07-24
**Status:** Approved (design), pending implementation plan
**Scope:** One combined spec covering three build phases (A foundation, B key-funded CLIs, C native agent loop).

## Problem

Today the embedded chat and pet assistant reach an AI only through the `claude` / `codex`
**CLIs** (OAuth/subscription) or Apple on-device Foundation Models. There is no way to
enter an API key and use OpenAI / Anthropic / a gateway directly. Jason wants:

1. Keep Codex and Claude as CLI agents on OAuth (no key) — untouched.
2. Drop Apple as a *chat* provider.
3. Add an **API Key** provider: pick a well-known endpoint (OpenAI / Anthropic /
   Vercel AI Gateway) or a custom URL, paste a key, and populate the model list by
   calling `GET /models` on the endpoint.
4. **Tools must still work in API-key mode.** If the key is an OpenAI or Anthropic key,
   fund the existing Codex / Claude Code CLIs with it (they bring the full agentic
   toolset). If it's a pure API route with no backing CLI, provide a native agent loop
   with a minimal built-in toolset.

Non-goal: there is no Vercel "AI SDK" for Swift (it is TypeScript/JS only). The
equivalent is a native Swift HTTP client against the OpenAI-compatible surface, which
every target endpoint (OpenAI, Anthropic's compat endpoint, Vercel AI Gateway) exposes.

## Decisions (locked during brainstorming)

- **One combined spec**, built in phases A → B → C.
- **Key storage: macOS Keychain** (Security framework), never the plaintext config file.
- **Native agent loop tool safety: auto-run, cwd-scoped** — matches the existing
  claude/codex agent feel; file ops jailed to the pane's cwd tree; `bash` runs in cwd
  with no approval prompt.
- **Routing by endpoint choice**, not by sniffing the key string.
- **Native loop speaks one dialect: OpenAI function-calling** (Anthropic never needs its
  native tool format here because Anthropic routes through the Claude Code CLI).

## Current architecture (grounding)

- `ProviderDiscovery.swift` — `InfinittyAIProvider` enum (`apple`/`codex`/`claude`),
  availability probing, and `preferredProvider(configured:)` resolving the `ai-provider`
  config string.
- `HintEngine.swift` — ghost-text autocomplete. Already has a working OpenAI-compatible
  HTTP path (`ai-base-url`/`ai-key`/`ai-model`) **and** an Apple on-device smart source
  (`.foundation`). This axis is *separate* from the chat provider axis and stays intact.
- `PetAssistant.swift` — the chat/pet orchestrator. `Backend` enum
  (`.claude`/`.codex`/`.openai`/`.foundation`/`.command`/`.none`), `resolveBackend(...)`,
  `askAI(...)`. `.openai` today is a chat-only, non-agentic call (`askOpenAI`).
- `ClaudeBridge.swift` / `CodexAppServer.swift` — spawn the CLIs; env is assembled in
  the spawn path (`ClaudeBridge` ~line 267, `CodexAppServer` analogous).
- `Config.swift` — parses/serializes `ai-provider` (`auto|apple|codex|claude`),
  `ai-base-url`/`ai-endpoint`, `ai-key`, `ai-model`, `claudeModel`, `codexModel`.
- `Settings.swift` — the Settings window; AI config is currently "Edit Config…" only,
  no provider UI.

## Design

### 1. Provider model — drop Apple, add API Key

- `InfinittyAIProvider` → `codex`, `claude` only (CLI discovery). Remove `.apple`,
  `appleAvailability()`, and the `.apple` branch of `preferredProvider`.
- `Config.aiProvider` valid set becomes `auto | codex | claude | apikey`.
- **Ghost-text hints are untouched:** `HintEngine.foundation` and `FoundationHint.swift`
  keep the on-device Apple default for autocomplete. Only the chat/pet Apple path is
  removed.
- **Dead code created (list, ask before deleting):** `PetAssistant.Backend.foundation`,
  `PetAssistantFM`, `providerImage(for: .apple)`, the `.apple` composer `AgentChoice`,
  `ModelCatalog.apple`, and the `.apple`/`.foundation` branches of `resolveBackend`.

### 2. Config + Keychain

New config keys (live-reloadable):

```
ai-provider = apikey
ai-endpoint = openai | anthropic | gateway | https://custom.example/v1
ai-model    = anthropic/claude-sonnet-5
# the API key is NOT written here — it lives in the Keychain
```

- New `Keychain.swift` helper wrapping `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/
  `SecItemDelete` for a generic-password item.
  - Service: `com.jasonkneen.infinitty`.
  - Account: `ai-key:<endpoint>` (e.g. `ai-key:gateway`, `ai-key:openai`) so distinct
    endpoint keys coexist.
- Endpoint preset → base URL resolution (single source of truth, reused by Settings,
  `/models`, routing, and the native loop):
  - `openai`   → `https://api.openai.com/v1`
  - `anthropic`→ `https://api.anthropic.com/v1`
  - `gateway`  → `https://ai-gateway.vercel.sh/v1`
  - `<url>`    → used verbatim (custom).
- `Config` parsing: extend the `ai-endpoint`/`ai-provider` cases; add `apikey` to the
  accepted `ai-provider` values. Serialize `ai-provider`/`ai-endpoint`/`ai-model` as
  today; never serialize the key.

### 3. Settings UI (`Settings.swift`)

- New **AI** section with provider chips: `Auto · Codex · Claude · API Key`.
- Selecting **API Key** reveals:
  - Endpoint dropdown: OpenAI / Anthropic / Vercel AI Gateway / Custom…
  - Custom-URL text field (visible only for Custom).
  - Secure key field (`NSSecureTextField`) — on edit, write to Keychain via `Keychain.swift`;
    never to the config file. Show a "key set / not set" affordance rather than echoing it.
  - Model dropdown populated by `/models` (§4) with a refresh button; falls back to
    editable free-text when the endpoint has no usable `/models`.
- Writes `ai-provider` / `ai-endpoint` / `ai-model` to the config (triggers live reload).

### 4. `/models` fetch (`ModelDirectory.swift`)

- `fetch(base:key:) async -> [String]`: `GET {base}/models`, parse `data[].id`.
- Cache per endpoint; manual refresh from the Settings button.
- Endpoints without a working `/models` (or that error) → return empty; Settings then
  offers free-text model entry plus a small curated fallback list per known endpoint.
- Uses the mockable HTTP client from §7 so it is testable offline.

### 5. Routing (`resolveBackend` in `PetAssistant.swift`)

When `ai-provider == apikey`, resolve by **endpoint**:

| Endpoint          | Precondition        | Resulting `Backend`                                  |
|-------------------|---------------------|------------------------------------------------------|
| `anthropic`       | `claude` on PATH    | `.claude(model:)` + `ANTHROPIC_API_KEY` injected (B) |
| `openai`          | `codex` on PATH     | `.codex(model:)` + `OPENAI_API_KEY` injected (B)     |
| `gateway`/custom  | —                   | `.apiAgent(base:model:)` native loop (C)             |
| `anthropic`/`openai` | CLI **missing**  | `.apiAgent(base:model:)` native loop (C)             |

- Backend gains a new case: `.apiAgent(base: String, model: String)`. The key is fetched
  from the Keychain at call time (not carried in the enum).
- OAuth modes (`auto`/`codex`/`claude`) resolve exactly as today — no behavior change.

### 6. Phase B — key-funded CLIs

- `ClaudeBridge.spawn`: when in `apikey` mode with the `anthropic` endpoint, set
  `env["ANTHROPIC_API_KEY"] = <keychain key>` (Claude Code then bills the API instead of
  OAuth). No other spawn changes.
- `CodexAppServer` spawn: analogously set `env["OPENAI_API_KEY"] = <keychain key>`.
- Injection happens **only** in `apikey` mode with the matching endpoint. OAuth paths keep
  their current env untouched (still `--setting-sources project,local`, OAuth in keychain).

### 7. Phase C — native Swift agent loop (`APIAgent.swift`)

An OpenAI-compatible **function-calling + SSE-streaming** client with a built-in tool
registry. Reuses the request-shaping already proven in `HintEngine.requestOpenAI`.

**HTTP layer**
- `POST {base}/chat/completions` with `stream: true`, `messages`, and `tools`.
- SSE parse: accumulate `choices[].delta.content` (stream to the chat live) and
  `choices[].delta.tool_calls[]` (name + JSON-arguments fragments assembled across chunks;
  keyed by `index`).
- All network goes through an injectable `URLSession`/`URLProtocol` seam for tests.

**Tool registry (auto-run, cwd-jailed)**
- `bash` — run a command via `/bin/zsh -c` in the pane cwd; capped output.
- `file_list` — list a directory (cwd-relative).
- `file_read` — read a file.
- `file_edit` — exact-string replace within a file.
- `file_write` — create/overwrite a file.
- Path safety: every file path is resolved with `realpath` and rejected if it escapes the
  pane's cwd tree. Honest residual risk: `bash` can still `cd /` — accepted per the
  auto-run decision. Mitigations: env kill-switch `INFINITTY_API_AGENT_NO_TOOLS=1`
  (chat-only, no tools) and a hard max-iteration cap on the loop.

**Agent loop**
1. Build `messages` (system + prior turns + new user message) and the `tools` schema.
2. Stream the response; render `delta.content` into the chat as it arrives.
3. If the turn ends with `tool_calls`: execute each tool, append one `role:"tool"`
   message per call (with `tool_call_id`), and loop to step 2.
4. Stop when the model returns a final message with no tool calls, or the iteration cap
   is hit (surface a clear "reached step limit" message).

**Integration**
- `askAI(backend: .apiAgent(...), ...)` drives `APIAgent` and streams through the existing
  chat/`onPetMessage` plumbing (same surface the CLI bridges already feed).
- `prewarm()` is a no-op for `.apiAgent` (no cold start to hide).

### 8. Testing

Offline via a `URLProtocol` mock — no live network in the suite.

- `Config`: parse/serialize `ai-provider=apikey`, `ai-endpoint` presets + custom URL,
  `ai-model`; assert the key is never serialized.
- `Keychain`: add/read/update/delete roundtrip (guarded so it runs against a test service
  name, cleaned up in teardown).
- Endpoint preset → base URL resolution.
- `/models`: parse `data[].id`; empty/error fallback path.
- **Routing matrix**: each (endpoint × CLI-availability) row → expected `Backend`.
- **SSE assembly**: `delta.content` concatenation and multi-chunk `tool_calls` argument
  reassembly by index.
- **Path-jail**: `file_*` tools reject `../` escapes and absolute paths outside cwd.
- Run touched suites with `swift test --filter <SuiteName>` (the full suite is flaky under
  load — see the project's flaky-subprocess-tests note).

## Build order

- **A (foundation):** §1 drop-Apple, §2 config+Keychain, §3 Settings UI, §4 `/models`,
  and the `.apiAgent` case + routing skeleton in §5 (routing can initially fall back to
  chat-only until C lands). Independently shippable.
- **B (key-funded CLIs):** §6 env injection. Small; makes API keys immediately useful
  with the real agents.
- **C (native loop):** §7 `APIAgent.swift`. The large, isolated piece.

## Open items to confirm during implementation

- Exact `/models` fallback model lists per endpoint (curated defaults).
- Whether the pet popover (as opposed to the sidebar chat) should also use `.apiAgent`
  or stay chat-only; default: same resolution as the sidebar.
- Confirm removal of the dead Apple chat-path code (§1) before deleting.
