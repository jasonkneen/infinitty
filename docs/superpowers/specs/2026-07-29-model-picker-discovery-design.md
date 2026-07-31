# Model picker: runtime discovery, no text inputs

**Date:** 2026-07-29
**Status:** approved

## Problem

The composer's MODEL chip offers a hardcoded `ModelCatalog`
(`PetAssistant.swift:1716`): four Claude models, two Codex models, and a single
`"<Provider> · configured default"` placeholder row each for OpenCode, Hermes,
and Amp. Because that catalog cannot know about gateway or preview models, each
provider also gets a `Custom… · <Provider>` row that opens an `NSAlert` with a
free-text field where the user types a raw model id
(`PetAssistant.swift:890-961`).

Typing model ids into a dialog is the wrong interaction. Every CLI that has
models can be asked for them at runtime. The picker should show real models.

## Verified discovery matrix

Each row below was confirmed by driving the CLI directly, not inferred.

| Provider | Discovery | Selection |
| --- | --- | --- |
| Codex | `codex app-server` → `model/list` (no params) | existing |
| OpenCode | `opencode2 acp` → `session/new` → `configOptions[id="model"].options[]` | `session/set_config_option {sessionId, configId:"model", value}` |
| Hermes | `hermes acp --accept-hooks` → `session/new` → `models.availableModels[]` | `session/set_model {sessionId, modelId}` |
| Claude | none — no CLI surface exists | `--model` |
| Amp | none — no model surface exists | `-m <mode>` |

Response shapes:

- **Codex** `model/list` → `result.data[]` of `{id, model, displayName,
  description, hidden, isDefault, defaultReasoningEffort,
  supportedReasoningEfforts[{reasoningEffort, description}]}`.
- **OpenCode** `session/new` → `result.configOptions[]`, three `select` options:
  `model` (123 options, `{value, name}`), `effort` (`low/medium/high/max`), and
  `mode` (`build/plan/swarm/*`). Each carries `currentValue`. There is no
  `models` key.
- **Hermes** `session/new` → `result.models.availableModels[]` of `{modelId,
  name, description}`, where `description` reads `"Provider: OpenAI Codex"` and
  appends `" • current"` for the active model. There are no `configOptions`.

OpenCode and Hermes therefore need **two different extractors**. This mirrors
the split `../buzz` maintains between the stable `configOptions` path
(`crates/buzz-acp/src/acp.rs:630`) and the unstable `models.availableModels`
path (`:645`).

Claude has no listing command — `claude --help` documents `--model` as taking
an alias (`fable`, `opus`, `sonnet`) or a full name, and exposes no subcommand
that enumerates them. Amp has no model concept at all; its `-m/--mode` flag
takes `low|medium|high|ultra` and "controls the model, system prompt, and tool
selection". Both stay hand-maintained, and Amp's rows are labelled **Mode**.

## Prerequisite bugs

Two defects in `ACPBridge.swift` block OpenCode entirely. They are fixed as part
of this work because discovery cannot function without them.

1. **The session is opened at `$HOME`.** `ACPBridge.swift` passed
   `NSHomeDirectory()` as the `session/new` cwd. ACP agents scan that tree, so
   the call's cost scales with it. Measured on `opencode2`, four trials each,
   holding everything else fixed:

   | cwd | `session/new` |
   | --- | --- |
   | empty neutral dir | 4.3s, 4.5s, 6.5s, 5.7s |
   | `$HOME` | 33.0s, 30.9s, 27.4s, 27.0s |

   The bridge's generic RPC timeout is 30s, so at `$HOME` OpenCode sits right on
   the edge — sometimes timing out, sometimes erroring. Fix: sessions opened
   without a project context (prewarm, discovery) use a neutral workspace under
   Application Support; real turns pass the caller's cwd, which they already
   had and were dropping. `session/new` also gets its own 90s budget, since a
   large project legitimately takes longer than a generic RPC.

   An earlier reading of this blamed a missing `clientCapabilities.terminal`.
   That was wrong — a controlled A/B returned all 123 models both with and
   without the flag, in both cwds. The capability is *not* set: we implement no
   client-side terminal RPCs, and advertising one we can't answer would hang
   the agent when it called back.

2. **`session/set_model` does not exist on OpenCode.** The bridge sent it for
   `.opencode`; `opencode2` answers `Method not found`. Model selection for
   OpenCode was dead code. The working call is
   `session/set_config_option {sessionId, configId, value}`.

Hermes still answers `session/set_model`, so the bridge keeps both and picks per
provider. Because a session is scoped to its cwd at creation, a cwd change now
invalidates and reopens it.

## Binary resolution

`ProviderDiscovery.swift:57` resolves OpenCode to `opencode`. It becomes: prefer
`opencode2`, fall back to `opencode`. The existing
`INFINITTY_OPENCODE_EXECUTABLE` override continues to win over both.

## Architecture

### `Sources/InfinittyKit/ModelDiscovery.swift` (new)

```swift
struct DiscoveredModel: Equatable {
    let id: String            // routed value
    let name: String          // shown in the menu
    let description: String?
    let isDefault: Bool
    let efforts: [String]     // empty when the provider says nothing
    let group: String?        // sub-provider, parsed from "prefix/Name"
}

enum ProviderModels: Equatable {
    case loading
    case loaded([DiscoveredModel])
    case failed(String)       // human-readable, shown in the menu
}

actor ModelDiscovery {
    static let shared: ModelDiscovery
    func models(for kind: PetAssistant.AgentChoice.Kind) async -> ProviderModels
    func refresh(_ kind: PetAssistant.AgentChoice.Kind) async
}
```

Strategies:

- `.codex` → `CodexAppServer.shared.listModels()`, a new method issuing
  `model/list` on the already-warm process. Drops `hidden == true`. Maps
  `displayName`, `isDefault`, `supportedReasoningEfforts[].reasoningEffort`.
- `.opencode` → `ACPBridge.opencode.configOptions()`, reading the `model` option
  captured from `session/new`. `group` is the `prefix/` of `name`.
- `.hermes` → `ACPBridge.hermes.availableModels()`, reading
  `models.availableModels`. `isDefault` is the entry whose `description` ends
  with `• current`.
- `.claude`, `.amp` → static tables in `ModelDiscovery`, replacing
  `ModelCatalog`. Amp's entries are modes.

Errors are converted to `.failed` with the underlying message so a broken
provider explains itself. A provider whose CLI is absent is omitted from the
menu entirely, as today.

### Bridge changes

`ACPBridge` stores the whole `session/new` result, which it already receives and
currently discards. Discovery ensures a session and reads the model surface out
of it — no extra spawn beyond the prewarm already performed. Model selection
branches per provider between `session/set_config_option` and
`session/set_model`.

`CodexAppServer` gains `listModels()` using its existing `sendRequest`.

### Cache

Last good list per provider is persisted to
`~/Library/Application Support/infinitty/model-catalog.json` — same directory
and file-per-concern pattern as `RecentCustomModels`
(`PetAssistant.swift:2184`), deliberately not `infinitty.conf`. The first menu
open after launch renders from cache immediately; a background refresh replaces
it when it lands.

### UI (`PetAssistantPanelView`)

`makeModelMenu()` becomes `Auto` plus one submenu per available provider.

```
  Auto · Best available
  ─────────────────────
  Claude          ▸
  Codex           ▸
  OpenCode        ▸   ┌ opencode      ▸ ┌ Claude Fable 5
  Hermes          ▸   │ opencode-go   ▸ │ Claude Opus 4.8
  Amp             ▸   └ fireworks-ai  ▸ │ Claude Sonnet 5  ✓
                                        └ Big Pickle
```

- A provider resolves when its submenu opens, not when the chip opens, so
  opening the chip never spawns five children.
- `.loading` → one disabled `Loading…` item.
- `.loaded` → a row per model, ✓ on the selection, `(default)` suffix on
  `isDefault`.
- `.failed(msg)` → a disabled `⚠ <msg>` item plus an enabled `Retry`.
- A third level appears only when a provider returns more than 20 models **and**
  their names carry a `prefix/`; models are then grouped by that prefix. Only
  OpenCode qualifies today.
- The hidden `modelPicker` `NSPopUpButton` remains the selection store and is
  repopulated as models arrive. Its titles stay exactly the selectable choices.

Removed: the five `Custom… · <Provider>` rows, `promptForCustomModel`, and its
`NSAlert` text field. `RecentCustomModels.load()` is retained so previously
saved ids still appear — they merge into their provider's submenu, deduped by
id, with no separate group. `RecentCustomModels.record` loses its only caller
and is kept only as the loader's format definition.

### Effort chip follows the model

`AgentChoice` gains `supportedEfforts: [String]` and `defaultEffort: String?`.
Selecting a model repopulates `effortPicker` from them and preselects
`defaultEffort`. An empty list falls back to today's fixed
`Auto/None/Low/Medium/High`, so `PetAssistantTests.swift:264` stays green for
the default Auto selection. Codex supplies efforts per model
(`low/medium/high/xhigh/max/ultra` for Sol); OpenCode supplies a session-wide
`low/medium/high/max`.

## Testing

TDD, following the repo's existing suites.

1. `ModelDiscovery` parses a recorded `model/list` fixture: models mapped,
   `hidden` filtered out, efforts and `isDefault` captured.
2. `ModelDiscovery` parses a recorded OpenCode `session/new` fixture:
   `configOptions[id="model"]` mapped, `currentValue` marked default, `group`
   derived from the name prefix.
3. `ModelDiscovery` parses a recorded Hermes `session/new` fixture:
   `models.availableModels` mapped, `• current` marked default.
4. A provider that errors yields `.failed(message)`, and the built menu contains
   a disabled `⚠` item plus an enabled `Retry`.
5. Menu shape: `Auto` plus one submenu per available provider; submenu item
   titles equal the discovered model names; a >20-model provider with prefixed
   names nests one level further.
6. Selecting a model with `supportedEfforts` repopulates `effortPicker`;
   selecting one without restores the fixed list.
7. Regression: no menu item is titled `Custom… · *`, anywhere in the tree.

Per `flaky-subprocess-tests`, touched suites are verified with `--filter` rather
than trusting a full `swift test` run.

## Verified end to end

Driven against the real binaries after implementation, all three discovered
providers answer in 5.6s total:

| Provider | Models | Groups | Default | Efforts |
| --- | --- | --- | --- | --- |
| Codex | 7 | — | GPT-5.6-Sol | low, medium, high, xhigh, max, ultra |
| OpenCode | 123 | fireworks-ai, opencode, opencode-go | Kimi K3 Fast | — |
| Hermes | 10 | — | gpt-5.6-sol | — |

## Risks

- Discovery for OpenCode and Hermes requires a live ACP child. Prewarm covers
  the common case; a cold provider's first submenu open shows `Loading…` for the
  duration of its cold start.
- Claude and Amp lists stay hand-maintained. No CLI surface exists to discover
  them from; every subcommand and flag was checked.
- Hermes model ids are provider-prefixed (`openai-codex:gpt-5.6-sol`) while
  names are bare (`gpt-5.6-sol`). The menu shows `name` and routes `modelId`.
- The user's `opencode` v1.17.20 is separately broken — its
  `~/.config/opencode/opencode.jsonc` has an unrecognized `plugins` key that
  kills the process before any RPC. Preferring `opencode2` sidesteps this; the
  config itself is out of scope.
