# infinitty — full code review

**Reviewed:** `main` @ `59893f4` · 139 Swift files · ~75k LOC (55k source / 20k tests)
**Date:** 2026-08-06
**Method:** whole-tree read of the five risk domains (security, concurrency/memory, terminal
correctness, agent bridges, architecture/tests), plus `swift build`, `swift test`, a `git
worktree` bisect, and purpose-written probe tests to confirm or refute the sharpest claims.

Detailed per-domain reports: `/tmp/review/{security,concurrency,terminal,bridges,architecture}.md`
Ready-to-paste regression tests for the confirmed terminal bugs: `/tmp/review/RegressionProbes.swift`

---

## 0. Headline

This is a strong codebase. Zero `TODO`/`FIXME`, zero empty `catch {}`, four `try!`, one `as!`,
no raw `os_unfair_lock` (so the classic value-copied-lock bug is absent), disciplined index
clamping in the VT parser, and a genuinely well-engineered event-sourced collaboration layer
with a hash-chained audit log. The tests are real tests (648 functions, 2,791 assertions), not
construction theatre.

The problems are concentrated in three places:

1. **Untrusted terminal output is a filesystem primitive.** The kitty graphics file path is
   not canonicalised, giving arbitrary file read *and delete* to anything that can print bytes.
2. **The agent control plane has no authorisation.** Any same-uid process can type into any
   pane, which makes the app's own agent-sandboxing decorative.
3. **Nothing runs the tests.** The suite is red at HEAD and has been for 19 commits, because
   CI is `workflow_dispatch`-only.

Everything else is downstream of the third point.

---

## 1. Build & test health

| Check | Result |
| --- | --- |
| `swift build` | clean |
| `swift test` | **FAIL** — 648 tests, 5 failures, 5 skipped |

Three tests fail deterministically (re-ran in isolation, not flaky):

- `HeadlessAppHostTests.testApprovedHeadlessProposalCreatesRealConnectedAgentRoom`
- `NavigationTests.testApprovedVisualProposalCreatesNamedConnectedProviderChat`
- `NavigationTests.testConnectedChatPanesReceiveNamesMembershipAndPeerMessages`

### Bisected to a single commit

I bisected in a throwaway `git worktree` (untouched main tree):

| Commit | Result |
| --- | --- |
| `a49580d` Replace the Channel pane with durable rooms | **pass** |
| `b108d79` Document release failure modes | **pass** |
| `399b975` Add native reasoning effort control and inactivity timeout policy | **FAIL** |

`399b975` is the regressing commit (+6,134 lines across the bridges, `PetAssistant`,
`ShadcnAssistantHost`, `HeadlessChatRuntime`). It did not touch `NavigationTests.swift` or
`HeadlessAppHostTests.swift` — the failures were shipped and never noticed.

### Why nobody noticed — CRITICAL

`.github/workflows/release.yml:5` is the **only** workflow and triggers on `workflow_dispatch`
only. There is no push/PR CI. `swift test` runs at line 27 of that workflow, which means **the
next release build will fail at the test step**.

Compounding it: `RELEASING.md:144` documents that "the full `swift test` run SIGSEGVs
non-deterministically under load … Rerun." A non-deterministic segfault in the test suite is
being treated as a known annoyance. With 55 test classes, 7 `tearDown`s, 3
`nonisolated(unsafe)` static event buses, 4 singletons and fixed `/tmp` socket paths, shared
global state is the obvious suspect.

**Fix:** add a push/PR workflow; fix the three tests; treat the SIGSEGV as P0; set
`INFINITTY_PERFORMANCE_GATES=1` in CI so `PerformanceBudgetTests` actually runs (today it never
does).

---

## 2. CRITICAL

### C1 — Arbitrary file read *and delete* from terminal output
`Sources/InfinittyKit/Terminal.swift:1741-1756`

The kitty graphics protocol `t=f` / `t=t` transmission accepts a file path and guards it with an
un-canonicalised prefix/substring test:

```swift
guard path.contains("tty-graphics-protocol")
    || path.hasPrefix("/tmp/") || path.hasPrefix(tmpdir)
    || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/var/folders/") else { return nil }
guard let d = FileManager.default.contents(atPath: path), d.count <= Self.maxEncodedImageBytes else { return nil }
if controls["t"] == "t" { try? FileManager.default.removeItem(atPath: path) }
```

`/tmp/../Users/you/.ssh/id_ed25519` satisfies `hasPrefix("/tmp/")`, and `FileManager` resolves
the `..`. So:

- **read** — file contents are decoded and rendered as an image;
- **delete** — with `t=t`, `removeItem` unlinks it (any readable file ≤ 8 MB);
- **oracle** — `a=q` replies `OK`/`EINVAL` back down the PTY, probing file existence.

The trigger is *terminal output*, reached unconditionally through the APC parser
(`Terminal.swift:664 → :1507 → :1673`) with no enable flag. `cat`-ing a hostile file, an `ssh`
session, an npm postinstall banner, or an agent's tool output is enough. `contains(...)` is also
satisfiable anywhere in the path.

**Fix:** `resolvingSymlinksInPath().standardizedFileURL` *first*, then assert containment under
the real temp dir; open with `O_NOFOLLOW`; drop the `contains(...)` clause; only ever delete
files the terminal itself created.

### C2 — The app control socket authorises nothing
`Sources/InfinittyKit/App.swift:6015`, `AppControlServer.swift:64,104,184`

`handleContextualAppRequest` applies its peer-executable check to `assistant-approval` and then
falls through to `handleAppRequest(request)` for **everything else** — including `send`,
`send-line` (`App.swift:6973`) and `run` (`:6995`), which write straight into a pane's PTY.
`LOCAL_PEERPID` is read at `AppControlServer.swift:362` but used only for the approval verb.

The socket lives at the fixed, predictable `/tmp/infinitty-current.sock`. `chmod 0600` stops
*other users*; it does not stop *other processes of the same user* — which is precisely the
threat the app's agent sandboxing exists to address. The MCP workspace-chat profile carefully
blocks `infinitty_send`/`infinitty_run` (`infinitty-mcp/main.swift:1911`), but `ClaudeBridge.swift:550`
grants the agent `Bash`; anything that can open a unix socket can drive any pane directly.

*Caveat, stated honestly:* the Claude leg of that chain also depends on whether Claude's own
seatbelt sandbox (`sandbox.enabled: true`) permits `connect()` to a `/tmp` socket — I did not
verify that. The **same-uid exposure itself needs no agent at all** and is not in doubt.

**Fix:** per-instance capability token (env-passed, file mode 0600) required on every mutating
verb, plus a peer-uid/pid check. Treat "same uid" as untrusted.

### C3 — Data race on `ForegroundProcessTracker.current`
`Sources/InfinittyKit/ForegroundProcessTracker.swift:50,63,108-112`

`current` (`ForegroundProcessInfo?`, ~48 bytes, 4 ARC refs) and `currentCwd` are written from the
`.utility` poll queue in `tick()` and read from main at `Session.swift:207` and
`App.swift:887,905,915,1664,4667` with **no synchronisation** — the file contains no lock at all
(only a `DispatchQueue` used for scheduling). A torn read retains a garbage `String`/`URL`
pointer → `EXC_BAD_ACCESS`. Made more likely by the `didSet` observers, which compare `oldValue`
and post a `Notification` synchronously from the writer thread.

**Fix:** the `NSLock`-guarded accessor pattern already used in `PTY.swift:18-26`.

---

## 3. HIGH

### Security

**S1 — Auto-update has no integrity check and disables Gatekeeper.**
`Updater.swift:185-238`. Downloads a tarball, then `rm -rf`s the installed bundle, `ditto`s the
replacement, and runs `xattr -dr com.apple.quarantine` on it. There is **no SHA-256 check and no
codesign/team-id check** — grepping the file for `sha256|codesign|verify` returns nothing — even
though the project *publishes* a `.sha256` next to every release and simply never consumes it.
`browser_download_url` is taken verbatim from the API JSON (`:56-63`) with no host or scheme
validation. TLS to GitHub is the only control, and quarantine-stripping means macOS won't
re-check the signature either. **Fix:** verify the published SHA-256, then `codesign --verify
--deep --strict` + team-id assertion, before swapping; never strip quarantine.

**S2 — "Allow for session" is far broader than the card implies.**
`AssistantApproval.swift:382` + `CodexApprovalAdapter.swift:32,69` + `ShadcnAssistantHost.swift:376`.
The grant key is `(scopeID, provider, kind, toolName)` — and Codex hardcodes
`toolName: "command execution"` for *every* shell approval. The actual command appears only in
the un-keyed `input` preview that the card renders. So the user reads `{"command":["git","status"]}`,
clicks **Allow for session**, and every subsequent Codex command is auto-approved — with no card
shown at all, because `request()` short-circuits at `:254` *before* publishing an event. Two
sub-defects: the fast path ignores `availableDecisions`, so a request advertising only
`[allowOnce, deny]` can still resolve `.allowSession`; and the auto-allow emits no telemetry, so
there is no audit trace. **Fix:** include a digest of the real argv/payload in the grant key, and
gate the fast path on `availableDecisions.contains(.allowSession)`.

**S3 — Fixed-path world-readable debug logs in a sticky dir.**
`PaneChrome.swift:4`, `PetAssistant.swift:7`. `/tmp/infinitty-pane.log` and
`/tmp/infinitty-pet.log`, opened via `FileHandle(forWritingTo:)` with no `O_NOFOLLOW`, ungated by
any debug flag. Verified live on this machine: **1.6 MB and 245 KB, mode 0644, being written
during this review.** Content includes attacker-settable OSC window titles. In a 1777 directory
another user can pre-plant a symlink and have your app append to a file you own.

**S4 — Coordinator socket squatting.** `CollaborationCoordinator.swift:28,74`. Path is
`SHA256(~/Library/Application Support)[:8]` in `/tmp`; `ensureAuthority()` trusts anything that
answers `pong`, with no server-side peer check. A squatter owns room state, audit answers, and
the human approve/deny transport. Also 1,232 stale `infinitty-channel-*.lock` files are
currently leaked in `/tmp` (verified).

**S5 — `bind()` → `chmod()` TOCTOU.** `ControlServer.swift:55-84`, `AppControlServer.swift:151-179`.
I measured it: the socket is **mode 0755 between `bind()` and `chmod(0600)`** (umask 022), in
world-writable `/tmp`. Since `send-line` is arbitrary keystroke injection, that window is a local
privilege-escalation primitive. No `umask()` call exists anywhere in the repo. **Fix:** use the
per-user `FileManager.default.temporaryDirectory` (the codebase already does this in 8 other
places), and wrap `bind()` in `umask(0o177)`.

**S6 — API key stored world-readable.** `Config.swift:440,469` — `ai-key` written in cleartext
with no `chmod`; verified 0644 on disk. Also, secrets reach `argv` (visible to `ps` for any
same-uid process): `ClaudeBridge.swift:514,583` and `AmpBridge.swift:70-77`.

### Terminal correctness — all three confirmed by execution

I wrote probe tests and ran them against `59893f4`.

**T1 — `last-output` returns corrupted data while a TUI is open.** `Terminal.swift:2150-2158`.
Markers are only *written* when `!usingAlt` (`:1877`), but `rowAtAbsoluteLine` *reads* from the
active `screen` — the alt buffer. Measured:

```
before (main screen) = "REAL_OUTPUT"
after `ESC[?1049h` + TUI paint = "ONTENT"     ← fragment of the TUI's own screen
```

This is the flagship agent API (`last-output`, `exit-code`, `last-command`) silently handing an
LLM garbage whenever `vim`/`less`/`htop`/`fzf` is open. **Fix:** read from
`usingAlt ? inactiveScreen : screen`.

**T2 — Partial scroll regions corrupt scrollback and absolute-line accounting.**
`Terminal.swift:895`. The guard is `if top == 0 && !usingAlt`; it must also require
`bottom == rows - 1`. With a top-anchored region (`CSI 1;5r` — every curses installer, `less`,
any status-bar TUI), each scroll appends a still-on-screen row to scrollback *and* increments
`sbAppended`, which is the sole definition of "absolute line 0". Measured: **4 rows on screen,
8 in history** — every row duplicated. That offset corrupts `history`, every OSC 133
`Marker.line`, selection anchors and link ranges.

**T3 — Resizing inside the alt screen destroys main scrollback.** `Terminal.swift:498`.
`adjust(&inactiveScreen, keepHistory: false)` is unconditional, so when `usingAlt` the *main*
screen's rows are dropped rather than pushed into the ring. Measured on shrink:
**30 history lines → 27**. Silent, unrecoverable. (Growing the window did not trigger it; shrink
does.)

*Refuted:* the related claim that `fullReset()`/RIS from the alt screen leaves alt content
visible did **not** reproduce — the screen was correctly blank. Reported as unconfirmed.

### Threading — README claims that don't hold

**T4 — `copySnapshot` copies every cell, every frame, under the lock.** `Terminal.swift:393-455`.
The README says the renderer "snapshots rows by reference (copy-on-write does the rest)". It
does not: `:415` copies each cell individually, plus per-row selection/link scans at `:421-432`.
That is ~17,500 cell copies (~280 KB) per frame on a 250×70 grid at 120 Hz, all inside the
single hot lock the README says is "held for microseconds".

**T5 — `screenText`/`historyText` build up to 10,000 rows of `String` under the lock**
(`Terminal.swift:2170-2184`), called from `.utility` socket threads
(`ControlServer.swift:193`, `App.swift:6980`). Any agent can issue `history 10000` in a loop and
stall the PTY parser and render thread. The 256 KB truncation happens *after* the string is
built. Fixing T4 as advertised fixes T5 too.

**T6 — `broadcast()` writes to a subscriber fd after releasing the lock.**
`AppControlServer.swift:236-243`. Membership is checked under `subscriberLock`, the lock is
released at `:238`, and `write()` happens at `:241`. In between, the client thread (`:333`) or
`stop()` (`:206`) can remove and close that fd — and any thread can be handed the same number.
Candidate reusers include a **PTY master fd** (`PTY.swift:69`, created on main exactly when
`pane-opened` is broadcast), i.e. JSON event bytes injected as keystrokes into a user's shell.
The author documented the fd-reuse hazard at `:330-332` and then left the write outside the lock.

**T7 — `stop()` closes `listenFD` while a thread is blocked in `accept()` on it.**
`ControlServer.swift:95-101`, `AppControlServer.swift:196`. Darwin does not guarantee `accept()`
wakes; the fd number is immediately reusable. **Fix:** `shutdown(fd, SHUT_RDWR)` or a self-pipe
wake, and close only on the accept thread.

**T8 — `HintEngine` can `SIGABRT` the app.** `HintEngine.swift:268` uses
`fileHandleForWriting.write(_:)`, which raises an uncatchable Obj-C `NSException` if the user's
`hint-command` closes stdin early. `Terminal.swift:2028` documents avoiding exactly this API in
`runGlow`; `runHintCommand` never got the fix. There is also no timeout on
`readDataToEndOfFile`/`waitUntilExit` (`:270`), so a hanging hint command wedges `aiQueue`
forever with `aiInFlight` stuck true.

### Agent bridges

**B1 — Every pipeline in every pane inherits `SIGPIPE = SIG_IGN`.**
`App.swift:407` sets `signal(SIGPIPE, SIG_IGN)` process-wide; `Sources/CPty/cpty.c:95-102` forks
and `execve`s without resetting it. POSIX preserves *ignored* dispositions across `exec`. I
reproduced it end to end:

```
with SIGPIPE ignored (infinitty's child env):  yes | head -1  →  "yes: stdout: Broken pipe"
with default disposition:                      yes | head -1  →  (silent)
```

Every `… | head`, `… | grep -q`, `yes | …` in the terminal misbehaves. **Fix:** reset SIGPIPE
(and the signal mask) to `SIG_DFL` in the child between `forkpty()` and `execve()` — `signal()`
is async-signal-safe, so it is legal there.

**B2 — Agent child processes survive app quit.** `App.swift:595`. `applicationWillTerminate`
stops the control socket and PTYs but never calls `stop()` on `ClaudeBridge.shared`,
`ACPBridge.opencode/.hermes`, or `CodexAppServer.shared` — these are static singletons, so
`deinit` never runs, and there are **zero production callers** of those `stop()`s. Unkeyed roots
are spawned routinely by the model menu (`ModelDiscovery.swift:132`) and prewarm
(`PetAssistant.swift:4127`). Result: `codex app-server`, `opencode acp`, `hermes acp` reparent to
launchd and accumulate one set per launch. (Per-pane keyed children *are* cleaned up correctly.)

**B3 — Double release of the ACP turn gate.** `ACPBridge.swift:272`. `await turnGate.release()`
runs, then the empty-answer `guard` throws at `:274` inside the same `do`, so `catch` releases
again at `:279`. `AgentTurnGate.release()` resumes a FIFO waiter while leaving `isLocked` true →
two concurrent `session/prompt` RPCs on one stdio child sharing one accumulator. The trigger is
the case the code explicitly anticipates (`.emptyResponse`). Claude and Codex get this right.

**B4 — Cancelling a headless cloud chat kills the agent permanently.**
`HeadlessChatRuntime.swift:297`. `backendConversationCanceller` is stored and **never invoked** —
cancel/stop/new-thread/signature-change all call the *releaser* instead, which for a cloud
adapter means `close()` → `closed = true`, and every later turn fails `guard !closed` with
"cloud runtime is closed" forever. Harmless for local backends (an epoch bump makes the tombstone
moot), which is why it hides. Looks like fallout from the cloud-approval routing work.

**B5 — Codex stdout buffer is never cleared across restarts.** `CodexAppServer.swift:44`.
Neither `stop()` nor the respawn branch of `ensureProcess()` clears `stdoutBuffer` (ACP clears at
`:397`, Claude at `:405`). A partial line from a killed process is prepended to the next
process's `initialize` response, which then fails JSON parse, is silently `continue`d at `:646`,
and rides the full 30 s handshake deadline. The readability handler also lacks the
`processGeneration == generation` guard both sibling bridges have.

### Architecture

**A1 — The agent control plane is implemented twice, with drift.**
`App.swift:6680` (429 lines) and `HeadlessAppHost.swift:484` (236 lines) are two hand-written
dispatchers for the same protocol, 23 shared commands, no shared command table. Confirmed
divergences: `snapshot`/`assign_role` ignore `threadId` in headless (`:1105` hardcodes `nil`);
`threadId` is validated for all ops in the GUI but only inside `post_message` in headless; a
missing channel yields `missing_channel` vs `unknown_channel`; and **the same human performing
the same action is written to the shared hash-chained audit log under two different actor
identities** (`"local-user:\(NSUserName())"` vs `"human:headless-control"`). **Fix:** one
`ControlCommand` enum + `ControlPlaneHost` protocol + one router.

**A2 — `AppDelegate` is 7,292 lines / 281 methods / ~100 stored properties** with 22
`[ObjectIdentifier: X]` side tables standing in for a window model, and 35 `ForTesting` shims.
`PetAssistant.swift` is a 4,882-line pair of god objects (`ask` alone is 232 lines). The
per-domain report names concrete seams (`AppControlPlane`, `CollaborationDirector`, `WindowModel`,
`PaneLayoutCoordinator`, `UtilityPaneRegistry`, `PaneLedgerRecorder`, `AppMenuBuilder`) that
take `App.swift` under ~2,500 lines.

**A3 — O(n²) per streamed turn in SwiftUI `body`.** `ShadcnAssistantHost.swift:409` constructs
`AssistantRunStatusSnapshot` *inside* `body`; its init reduces over all `model.messages` and
`model.tools` summing UTF-8 bytes. Streaming reassigns the full accumulated string per chunk,
so cost grows quadratically with turn length. The result types are already `Equatable`, which
cannot help — the cost is in *producing* the value.

**A4 — Three byte-identical event buses** (`AssistantToolEvent.swift:49`,
`AssistantApproval.swift:96`, `AssistantRunEvent.swift:208`), ~270 duplicated lines; and a
byte-budget truncation helper written **seven times** despite a canonical `boundedPrefix`
existing at `CollaborationChannel.swift:396`.

**A5 — `onMain`'s 3 s timeout is collapsed into domain answers.** `App.swift:6046`. It returns
`nil`, and call sites turn that into `[]` "no panes", "no such pane", "split failed". An agent
cannot distinguish *busy* from *absent* — and will confidently act on the wrong one.

---

## 4. Test coverage, where it actually matters

`Terminal.swift` is 2,418 lines with **215 lines of tests (17-23 cases)**. Untested: `resize`
reflow, `fullReset`, `saveCursor`/`restoreCursor`, all 45 `csiDispatch` cases (including
DECSTBM), every DECSET mode, the whole image subsystem, and the printable-ASCII fast path.

Single assertions would have caught T1, T2 and T3 — I wrote them in about ten minutes and all
three failed immediately. They are saved at `/tmp/review/RegressionProbes.swift`.

Other zero-test files: `TerminalView` (1,018), `TerminalTabStrip` (1,013), `Renderer` (770),
`Settings` (645), `MCPConfiguration` (462), `GlyphAtlas` (335), `ControlServer` (266).
`Sources/infinitty-mcp/main.swift` (2,044 lines) and `infinitty-agent/main.swift` (389) have
**zero** tests — they are all top-level code and not importable.

22 of 35 control-plane commands have no test of the dispatch path.

---

## 5. Suggested order

1. **T1 / T2 / T3** — one-line fixes each, tests already written. These corrupt the product's
   headline agent API today.
2. **C1** — canonicalise the kitty path. Small, self-contained, closes an arbitrary-delete.
3. **CI on push/PR + fix the 3 red tests + the SIGSEGV.** Without this, everything below
   regresses silently.
4. **B1** (reset SIGPIPE in the child) and **C3** (lock the tracker) — both tiny.
5. **S1** (verify update signatures) and **S2** (bind session grants to the real command).
6. **T4/T5** — one refactor makes the README's snapshot claim true and removes the agent-driven
   stall.
7. **C2** — capability token on the control plane. Needs a design pass; do it deliberately.
8. **A1** then **A2** — unify the control plane, then extract `AppControlPlane` from
   `AppDelegate`.

---

## 6. Note on the working tree

The tree was clean at the start of this review (only untracked `ui-review.md`). It now carries
uncommitted edits to `ClaudeBridge.swift`, `CodexAppServer.swift`, `CollaborationCloudRuntime.swift`,
`ModelDiscovery.swift`, `AgentBridgeTests.swift`, `CollaborationCloudRuntimeTests.swift`
(+172 / −5), timestamped mid-review. They implement Markdown paragraph separation between agent
narration segments — coherent, test-backed work that matches **no finding in this review**, and
another Claude session was active on this machine.

**I did not revert them**, on the assumption they are your concurrent work. A backup is at
`/tmp/review/UNSOLICITED_agent_changes.patch` if you need it. Please confirm they are yours
before committing.
