# Agent Channels Implementation Plan

**Source design:** `docs/superpowers/specs/2026-07-31-agent-channels-design.md`

## Delivery rules

- Preserve the terminal/render/PTy main-thread isolation.
- Every visible app action gains a structured control-plane equivalent that
  works against a windowless Infinitty host.
- Provider/model availability is negotiated from the live adapter.
- No room provisioning side effect occurs before exact human approval.
- Every mutation is identified, revision-checked, authorized, durable, ordered,
  observable, cancellable where possible, and auditable.
- Keep new room semantics out of `AppDelegate` and `PetAssistant`; those remain
  adapters/projections.

In this plan, **headless** refers only to the Infinitty terminal/app host running
without AppKit windows. Amp is an agent provider; its `--execute --stream-json`
mode is a non-interactive provider transport, not the product's headless host.

## Delivery note — terminal CLI Channel awareness

**Delivered:** 2026-08-01 on `feature/agent-channels`

The terminal-agent integration slice is complete and is the supported path for
using Claude, Codex, Amp, and other local CLIs in Channels:

- `infinitty-agent run -- <cli>` registers a managed CLI lifetime without
  changing its PID/TTY semantics; `context` emits bounded plain, Claude-hook,
  or Codex-hook context;
- MCP initialization provides the first live Channel snapshot and binds
  registration/post operations to the owning pane;
- the visual host provides recognized-CLI fallback registration, unique names,
  and stale-owner cleanup;
- Claude hooks and the optional zsh auto-wrapper are installed idempotently and
  preserve existing user configuration;
- app, tarball, npm, and release-script packaging includes the MCP server,
  helper, and hook assets.

Verification completed for this slice: `swift test` (515 passed, 5 skipped),
release build, signed app bundle smoke checks, and helper/MCP packaging checks.
The remaining phase items below are intentionally still marked by their own
status lines; this note does not claim the full enterprise Channel roadmap is
complete.

## Phase 0 — safety and measurement gates

### 0.1 Correlated terminal execution

Status: implemented for queue correlation and output ownership; prompt admission,
forged-marker detection, and unknown-outcome receipts remain.

- Replace the `runQueues` OSC-marker coupling with a per-terminal execution
  lease and immutable command receipt.
- Admit only at a proven prompt or return a structured precondition error.
- Capture output/exit before the next command can start.
- Timeout becomes cancel/unknown-outcome; it never shifts completion to another
  queued request.
- Add concurrent, forged-marker, timeout, cancellation, restart, and output-race
  tests.

### 0.2 Parser/image/global memory budgets

Status: implemented for CSI, OSC/APC payloads, queued decode bytes, decoded
pixels, placements, Kitty store, CPU buffers, and Metal texture cache. RSS/GPU
telemetry remains.

- Bound CSI parameters, Kitty assembly bytes, decode jobs, placements, stored
  images, CPU buffers, and GPU textures under one per-pane budget.
- Apply backpressure and explicit eviction/error events.
- Add malicious APC/CSI and maximum-image stress tests plus RSS/GPU assertions.

### 0.3 Performance harness

Status: initial gross-regression budgets cover 1 MiB parsing, 1,000 full-grid
snapshots, and 1,000 room commits. Signposts and machine baselines remain.

- Add release-mode parser, flood/input-latency, multi-pane render, idle, control
  latency, and teardown benchmarks.
- Capture signposts for PTY read/parse, snapshot, instance build, encode, commit,
  present, control admission, journal commit, and projection.
- Make regressions visible in CI with machine-specific baselines/tolerances.

### 0.4 Security defaults and release posture

Status: provider danger modes are explicit opt-in, `-Ounchecked` is removed,
and release tests/signing/notarization fail closed. Keychain migration, signed
installer verification, dependency pinning, provenance, and SBOM remain.

- Remove implicit provider permission bypasses; generate policy from grants.
- Move secrets to Keychain references.
- Verify signed installer digests before extraction.
- Pin release dependencies and fail closed on tests/signing/notarization,
  provenance, and SBOM generation.
- Restrict or remove `-Ounchecked` from privileged control-plane code.

## Phase 1 — one local Channel, end to end

### 1.1 Room kernel and journal

Status: local foundation implemented.

- Typed Channel, endpoint, participant, responsibility, plan, and message state.
- Expected revisions, idempotency keys, hash-linked audit records.
- In-memory and JSONL adapters with replay/tamper tests.
- Original idempotency receipts are replayed exactly; live transcript snapshots
  retain a bounded recent window while the audit remains append-only.
- Next: add proposal/grant intents, plan cycle validation, claim TTL/fencing,
  denied decision events, and journal rotation/snapshot policy.

### 1.2 Structured local transport

Status: versioned base64url JSON transport, MCP snapshot/link/apply/leave/update
tools, and one durable local coordinator shared by visual and headless
instances are implemented. Coordinator ownership fails over by replaying the
same hash-linked journal. Authentication, durable event cursors, deadlines,
cancellation, and grants remain.

- Add versioned JSON request/response envelopes over a new authenticated local
  coordinator socket.
- Carry actor, instance, command ID, expected revision, deadline, capability,
  consent, and correlation.
- Preserve legacy read-only commands temporarily behind a compatibility adapter.
- Return machine-readable errors and ordered cursor receipts.
- Make MCP concurrent by request ID and honor cancellation notifications.

### 1.3 Pane identities and connector

Status: connector with a 28 point hit target, cross-window screen-coordinate drag targets, transient wire,
deterministic Channel color, pane tint, accessible labels, direct instance
endpoint IDs, unique Chat names, and visible Channel name/member badges
implemented. Chat/terminal renames update membership and close/window teardown
leave the room. Pane identities are process-lifetime, not yet restart
persistent; keyboard linking and frame coalescing remain.

- Give every window/tab/pane/Chat/surface a persistent UUID independent of view
  identity, memory address, or process-local terminal integer.
- Add connector control with 28 point target, accessibility actions, keyboard
  linking, screen-coordinate cross-window target discovery, cached frames, and
  coalesced transient wire.
- Project room accent/name/member count to linked panes.
- Submit link/merge commands through the room module only.

### 1.4 Channel and Plan/Status projections

Status: implemented as durable room state without a Channel pane. Connector
badges project membership while linked Chat providers receive bounded live
identity, peer, plan, and recent-message context. Data operations remain
available to MCP/headless clients; former visual lifecycle operations return
`channel_panel_removed`.

A Chat thread may additionally own an ordered in-pane roster. `/add-agent` and
the model picker's `+` add exact configured agents. Broadcasts run one bounded
sequential round; `@alias` routes only to recognized members. Responses remain
in one attributed transcript and publish through the Chat endpoint as bounded
`[Agent]` messages rather than creating endpoints.

### 1.5 MCP/action manifest parity

Status: Channel snapshot/link/typed apply tools include atomic link-and-join,
leave, and membership update, and pane discovery includes Chat endpoints.
Generated manifests, prepare/authorize, events/export, and semantic parity
traces remain.

- Generate a capability/action manifest for every AppKit action.
- Declare schema, target identity, permission, reversibility, preconditions, and
  windowless-host support.
- Add Channel tools for prepare/authorize, list/snapshot, link/join/leave,
  participant/role, plan/claim, message/steer, open/stage, events, and export.
- Run one trace against AppKit and headless adapters and compare semantic state.

## Phase 2 — permission-first agent rooms

### 2.1 Proposal and approval

- Parse a room request into editable participants, roles, responsibilities,
  provider/runtime choices, workspace scopes, capabilities, cost, and plan.
- Preflight providers and workspace asynchronously with zero mutation.
- Bind approval to proposal digest, actor, expiry, and allowed deviations.
- Route the proposal through native host approval UI.

### 2.2 Provider broker

- Define one internal agent runtime port.
- Add Codex, Claude, ACP/OpenCode/Hermes, Amp non-interactive stream-JSON, and
  deterministic mock adapters.
- Negotiate model, effort, MCP/UI control, cancellation, resume, authentication,
  quotas, and cost.
- Pass the same scoped room MCP capabilities to every compatible provider.

### 2.3 Provisioning saga

- Create panes, windowless-host terminals, provider executions, and worktrees;
  join endpoints, assign roles and claims, publish the kickoff plan, and begin
  only after durable authorization.
- Make every step idempotent and compensatable.
- Expose partial setup and Retry/Continue/Roll Back.

## Phase 3 — non-clashing workspace coordination

### 3.1 Plan DAG and delegation

- Revisioned task graph with stable IDs, dependencies, owners, evidence,
  blockers, progress, and child delegation threads.
- Merge disjoint plan patches and surface overlapping edits for reconciliation.

### 3.2 Responsibility lease engine

- Normalize repo scopes and detect path/glob overlap safely.
- Issue TTL leases with fencing tokens and heartbeats.
- Reject stale result commits after reassignment.
- Support exclusive/shared/read modes plus separately fenced integration lease.

### 3.3 Shared checkout and worktree adapters

- Shared checkout adapter enforces non-overlapping scopes.
- Worktree adapter creates named, recoverable worktrees and records base/branch.
- Integration adapter previews conflicts and requires explicit authority for
  destructive resolution.

## Phase 4 — coordinator, headless, and multiple instances

### 4.1 Local coordinator

Status: partial discovery adapter implemented. Every visual instance publishes
a private descriptor and monotonic event sequence; MCP can list instances and
target one via `INFINITTY_INSTANCE_ID`. Authority, durable order, heartbeats,
epochs, and daemon ownership remain.

- Move journal/order/claims/provider sagas to a renderer-free daemon.
- Add an authenticated instance registry, heartbeats, stable routing, and
  coordinator epochs.
- Replace newest-socket discovery with explicit instance selection.

### 4.2 True headless host

Status: renderer-free `infinitty --headless` foundation implemented. It launches
real PTYs and exposes pane/app sockets, instance discovery, Channel state,
events, and MCP terminal/Channel tools without constructing `NSApplication`,
windows, Metal layers, renderers, or display links. Visual projection
attach/detach, durable coordinator ownership, authenticated authority, and
automated release-mode idle/recovery gates remain. A production probe measured
328.1 ms start-to-ping, 14,256 KiB RSS with one PTY, a correlated command
receipt, and clean child/socket teardown.

- Start room/control/provider modules without `NSApplication`, `NSWindow`,
  `CAMetalLayer`, renderer thread, or display link.
- Allow visual instances to attach/detach as projections.
- Verify start-to-ping, memory, idle CPU, and recovery gates.

### 4.3 Recovery and backpressure

- SQLite WAL journal/outbox and snapshot compaction.
- Snapshot-plus-replay recovery and explicit cursor expiry.
- Bounded per-subscriber queues with lossless lifecycle/audit events and
  coalescible presentation telemetry.
- Kill/restart/failover tests after every command phase.

## Phase 5 — cloud agents and enterprise controls

### 5.1 Cloud runtime adapters

- Codex server and Claude server adapters behind the same runtime port.
- mTLS/authenticated callbacks, scoped workspace manifests, secret references,
  cancellation/resume/status, egress policy, accounting, and unknown-outcome
  reconciliation.

### 5.2 Enterprise audit

- Encrypted journal payloads, data classification, governed redacted views,
  retention/legal hold, crypto-shredding events, periodic signed Merkle roots,
  signed JSONL export, SIEM/OTLP, and WORM mirror adapters.
- Replay/export verification never invokes effects.

### 5.3 Policy administration

- Organization capability policy, provider allowlists, sandbox/network rules,
  cost budgets, audit requirements, retention, and delegated approval.
- Enterprise-required audit failure blocks mutations and remains visible.

## Release acceptance

The feature is complete only when all of the following are proven:

1. six mixed local/cloud participants can be proposed, approved, provisioned,
   linked, named, assigned, and coordinated from one Channel;
2. the same scenario runs visible or headless and across multiple app instances;
3. panes/Channels/plan panels move, stage, restore, close, reopen, and relaunch
   without losing identity;
4. overlapping responsibility claims cannot silently proceed, with or without
   worktrees;
5. humans can steer the room, any participant, or a delegation subthread;
6. every UI action is discoverable and controllable through the structured
   manifest;
7. permission, cancellation, provider loss, audit loss, partial provisioning,
   cursor gaps, and stale leases fail explicitly and recover safely;
8. audit replay reconstructs the same room and tampering is detected;
9. performance, memory, idle, teardown, render, accessibility, contrast,
   reduced-motion, installer, provenance, and soak gates pass.
