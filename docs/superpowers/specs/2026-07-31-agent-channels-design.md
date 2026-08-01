# Infinitty Agent Channels

**Date:** 2026-07-31
**Branch:** `feature/agent-channels`
**Status:** selected architecture. The terminal-CLI Channel-awareness slice is
implemented on this branch; the broader room/proposal/claims roadmap remains
phased as described below.

## Product intent

Infinitty is an agent-first Ghostty replacement where humans and agents share
the same visible, scriptable workspace. Every visible app action must have a
structured control-plane equivalent that also works when the Infinitty host
runs without AppKit windows. Several terminals, chats, windows, app instances,
local agents, and cloud agents can be joined into one collaboration Channel.

Here, **headless** means the Infinitty terminal/app host is running without a
visible UI. Amp remains an agent provider; `--execute --stream-json` is its
non-interactive provider transport and is not what this design means by a
headless app.

A Channel gives the group:

- one room-level conversation with navigable delegation subthreads;
- explicit participant names, roles, capabilities, and responsibilities;
- a canonical plan, task graph, status, evidence, and blockers;
- exclusive or shared workspace claims that prevent silent collisions;
- local or cloud execution with permission scoped to the exact proposal;
- a persistent color and identity projected onto member panes;
- a complete, ordered, attributable, tamper-evident audit trail.

## Existing foundation

The live tree already provides high-leverage presentation and runtime modules:

- Metal rendering, bounded scrollback, off-main PTY parsing, and damage-gated
  frames;
- nested split panes, pane rearrangement, zoom/stage and exact restore;
- multiple Chat and Browser leaves plus agent-created display surfaces;
- stable terminal IDs inside a process and structural pane ledger IDs;
- Codex, Claude, ACP/OpenCode/Hermes, and Amp bridges;
- model discovery from live providers rather than a hard-coded release list;
- an app control socket, per-pane control sockets, MCP tools, and event
  subscriptions;
- per-pane agent todos and agent/tool event rendering.

These are adapters and projections for collaboration. None is the source of
Channel truth.

## Audit findings that shape the design

### P0: shell automation does not yet provide a non-clashing execution lease

`App.swift` completes queued `run` calls from any OSC 133 completion marker. A
timed-out head item can be removed before its real completion arrives, causing
the next request to be completed without being sent. A fast following command
can also replace `lastCommandOutput` before the first caller reads it.

Channel execution therefore requires a command identity, prompt-state
precondition, exclusive terminal lease, correlated completion, immutable output
receipt, cancellation, and unknown-outcome recovery.

### P0: terminal image and parser memory need explicit global budgets

CSI parameter growth, Kitty chunks, decode jobs, CPU placements, stored images,
and renderer texture caches do not share one enforced per-pane budget. Several
maximum-size images can consume gigabytes. Collaboration multiplies pane count,
so the product cannot rely on ordinary workloads staying small.

### P0: ambient local authority is not enterprise authorization

The Unix sockets are mode `0600`, but every same-UID process can issue terminal
input, shell runs, pane closure, window creation, and UI mutations. Requests
lack an authenticated principal, capability proof, consent receipt, command
ID, expected revision, and audit correlation.

Provider bridges currently default to broad bypass modes in some paths. A room
must generate provider policy from its capability grant; an adapter may never
silently broaden it.

### P1: multi-instance discovery and event order are not authoritative

`/tmp/infinitty-current.sock` is a last-writer-wins symlink, not an instance
registry. App broadcasts are separate asynchronous tasks and the MCP event
buffer is in-memory, bounded, and silently drops old events. A Channel needs one
ordered journal, durable cursors, explicit gap recovery, stable instance IDs,
and direct instance addressing.

### P1: current diagnostics are not enterprise audit

`PaneLifecycleLedger` is valuable crash evidence, but it records structural
pane changes only. It has no authenticated actor, authorization, consent,
command intent/result, delegation, provider provenance, classification,
integrity chain, governed retention, replay, or export.

### P1: provider behavior is nonlocal and capability-asymmetric

Provider switches and lifecycle decisions are spread through `PetAssistant`.
Codex and Claude receive the current app MCP socket, while ACP starts with no
MCP servers. The installed Amp CLI advertises non-interactive `--execute` and
stream-JSON options, now consumed by its provider adapter. Provider
capabilities must be negotiated and adapter-owned.

### P1: current rendering and UI tests reveal scale risks

Each rendered frame snapshots and walks the full grid, and glyph lookup shares
one atlas lock. Six busy large panes magnify that cost. The baseline suite also
passes while emitting Auto Layout conflicts in `CodeView` and invalid geometry
warnings in a quick-terminal test. Visual and accessibility acceptance must
assert rendered behavior, not only direct view state.

## Domain language

- **Channel** — the durable coordination scope visible to the human.
- **Room kernel** — the authoritative state machine behind a Channel.
- **Participant** — a human or agent identity with a name and role.
- **Endpoint** — a terminal, Chat, Channel panel, remote execution, or other
  visible or windowless app surface attached to a Channel.
- **Responsibility** — the human-readable ownership assignment.
- **Claim** — the enforceable workspace/resource lease behind a
  responsibility.
- **Plan** — the revisioned task DAG owned by the Channel.
- **Projection** — an AppKit panel, tint, MCP response, CLI response, or cloud
  view derived from room state.
- **Proposal** — a side-effect-free description of intended provisioning,
  capabilities, cost, workspace strategy, and plan.
- **Grant** — explicit authorization bound to the exact proposal digest.

## Selected architecture

Use one deep `CollaborationRoom` module. It owns ordering, identity, policy,
consent, plans, claims, provider dispatch, audit, recovery, and projections.
AppKit, MCP, Unix JSON-RPC, local CLIs, and cloud runtimes are adapters.

The external interface has three high-leverage operations:

```swift
public protocol CollaborationRoom: Sendable {
    func apply(_ command: RoomCommandEnvelope) async throws -> RoomCommit

    func snapshot(
        _ query: RoomQuery,
        actor: ActorContext
    ) async throws -> RoomSnapshot

    func events(
        after cursor: RoomCursor?,
        filter: RoomEventFilter,
        actor: ActorContext
    ) -> AsyncThrowingStream<RoomEventEnvelope, Error>
}
```

`RoomIntent.prepare` and `RoomIntent.authorize` are typed commands, not separate
interfaces. This keeps the common path small while proving that preparation has
no side effects.

The in-process kernel stays exhaustively typed. Transport adapters expose
versioned schemas and capability manifests, but do not reduce the kernel to
untyped dictionaries.

### Command envelope

Every mutation carries:

- room ID and globally stable command/idempotency ID;
- authenticated actor, optional delegator chain, and instance ID;
- expected room or plan revision where conflict-sensitive;
- causation, correlation, trace, and deadline;
- capability proof and consent receipt;
- typed intent and schema version.

Duplicate command IDs return the original commit. Reuse with a different
payload is rejected. A successful commit is returned only after the journal is
durable.

### Ordering and recovery

- One room has one authoritative sequence and fenced coordinator epoch.
- Transport is at-least-once; state mutation is exactly-once by command ID.
- Streams may replay duplicates but never silently gap.
- Expired cursors return the earliest retained cursor and snapshot revision.
- Replay reconstructs state but never reruns external side effects.
- Provider calls use a durable outbox/saga and record
  `ExternalOutcomeUnknown` when safe reconciliation is impossible.

### Claims and collision prevention

- Plans use optimistic revisions and explicit reconciliation.
- Disjoint changes may merge; overlapping task, dependency, owner, or scope
  edits never use silent last-writer-wins.
- Responsibilities use leases with fencing tokens, TTLs, and heartbeats.
- Without worktrees, overlapping normalized repository-relative scopes are
  rejected.
- Worktrees provide physical isolation but do not waive logical ownership.
- Integration/merge uses its own exclusive fenced lease.
- Scope matching must handle symlinks, `..`, Unicode normalization, and macOS
  case folding.

### Permissions

Default capability is observation only.

The following need scoped grants or an exact human consent receipt:

- spawning participants or creating worktrees;
- terminal input and shell execution;
- filesystem, network, process, secret, or cloud access;
- destructive actions;
- provider danger/approval bypass modes;
- paid cloud execution and data egress.

Dragging a connector authorizes only the endpoint membership change. It never
implicitly authorizes the actions above.

## Connector and Channel UX

Each pane header gets a 14–16 point connector circle with a 28 point hit target,
an accessibility action, tooltip, keyboard focus, and non-color status text.
Existing whole-header dragging remains pane rearrangement.

During connector drag:

1. no persistence, provider, or network work occurs on mouse movement;
2. an app-level transient wire follows the pointer;
3. eligible endpoint frames are cached in screen coordinates;
4. endpoints across all windows in the instance receive a halo;
5. Escape cancels;
6. drop submits one typed link command.

Drop behavior:

- unlinked + unlinked creates a two-endpoint Channel;
- linked + unlinked joins the existing Channel;
- same Channel is idempotent;
- different Channels create a merge proposal and require explicit approval.

After drop the wire disappears. Members keep the same contrast-safe accent,
connector state, Channel name, and member count. Color is never the only cue.

Clicking the connector opens membership actions and the Channel panel.

### Channel panel

`UtilityPanelKind.channel` is a normal movable pane/window projection. It
inherits existing double-click stage/restore behavior and contains:

- room-level conversation;
- participant names, roles, status, provider, and workspace;
- delegation subthreads;
- plan/status rail with owners, dependencies, blockers, and evidence;
- responsibility/claim conflicts;
- approvals, failures, recovery actions, and audit receipts.

Closing a projection does not destroy the Channel or stop provider
executions.

## Permission-first six-agent flow

“Create a room of six agents” first emits a proposal card containing:

- objective and canonical kickoff plan;
- six editable names, roles, and non-overlapping responsibilities;
- local/cloud runtime and provider-reported model;
- shared checkout or worktree strategy;
- requested filesystem, terminal, network, secret, and cloud capabilities;
- estimated local resources and cloud cost;
- collision policy, audit policy, and retention destination.

No pane, process, worktree, or cloud call is created before approval. Approval
is bound to the proposal digest and expiry.

Provisioning is a visible saga. Partial setup becomes `setupIncomplete` with
explicit Retry, Continue With Fewer, and Roll Back actions. Hidden orphan
agents or worktrees are never treated as success.

## Audit and enterprise controls

Every accepted, rejected, consent-required, failed, cancelled, and timed-out
command records:

- actor, delegator, instance, room, participant, endpoint, task, and execution;
- command/idempotency, causation, correlation, trace, and schema version;
- capability and consent receipt;
- data classification and redacted payload digest;
- provider/runtime provenance, timing, resource/cost use, and outcome;
- previous event hash and periodic signed-root reference.

The local adapter uses a private append-only journal. Enterprise adapters may
mirror signed JSONL, SIEM/OTLP, or WORM storage. Redaction creates a governed
view or destroys a separately encrypted payload key; it never rewrites history.

Secrets are Keychain references resolved only at execution. They never enter
room commands, events, prompts, logs, exports, settings files, or provider
arguments.

## Performance contract

### Terminal/runtime

- Keystroke-to-present: p50 ≤8 ms, p95 ≤16.7 ms, p99 ≤33 ms with six busy panes.
- Parser: ≥100 MiB/s printable ASCII in release; terminal-lock p99 ≤2 ms.
- Six 240×80 panes: sustained 60 fps; p95 CPU frame construction ≤8 ms.
- Idle after 1.5 s: <1% aggregate CPU for six panes and no recurring frames.
- Image CPU+GPU budget: ≤128 MiB per pane; decode queue ≤2 jobs/32 MiB.
- Pane teardown: process group, PTY, sockets, read/render threads gone in
  ≤500 ms p99.

### Collaboration/control

- Local command admission p95 ≤10 ms.
- Durable local commit p95 ≤25 ms, p99 ≤75 ms.
- Commit-to-visible projection p95 ≤100 ms, p99 ≤250 ms.
- Snapshot p95 ≤20 ms for 100 participants and 1,000 tasks.
- Local cancellation acknowledgement ≤250 ms.
- Headless start-to-ping ≤400 ms with no windows, Metal layers, or display links.
- Six app instances are simultaneously discoverable and directly addressable.
- Slow consumers receive an explicit recoverable gap; audit events are never
  silently dropped.

## Alternatives considered

### Minimal typed actor

`open`, `apply`, and `events` with an exhaustive `RoomIntent` is the best kernel
shape. It maximizes depth and compile-time guarantees.

### Versioned extensible command registry

Namespaced type IDs and payload schemas make third-party extensions easy, but
using them inside the kernel weakens exhaustiveness. They belong at transport
and plugin adapters, which translate into typed intents.

### Peer-to-peer CRDT room

Useful later for offline plan drafts, but rejected as the authority model.
Consent, revocation, audit sequence, exclusive claims, filesystem effects, and
cloud execution require coordinator ordering and fencing.

## Delivered terminal-agent slice

The following slice is implemented and shipped with the branch:

- `infinitty-agent` provides a provider-neutral `run` wrapper and bounded
  `context` command for Claude, Codex, Amp, and other terminal CLIs;
- MCP initialization includes an authoritative bounded Channel snapshot and
  managed process registration, with explicit self/post tools for refresh and
  publishing;
- the visual host registers recognized foreground CLIs as a fallback and uses
  unique participant names plus stale-owner cleanup;
- Claude `SessionStart`/`UserPromptSubmit` hooks are merged idempotently, and
  the optional zsh integration can auto-wrap recognized CLIs;
- pane-socket registration, context, and post messages remain
  provider-neutral, bounded, and authenticated to the owning pane;
- the app bundle, release scripts, tarball, and npm installer package the
  helper and hooks alongside the MCP server.

The in-process Channel kernel and the wider typed control-plane, proposal,
claims, and enterprise-audit work remain governed by the phased implementation
plan rather than being implied complete by this terminal integration.
