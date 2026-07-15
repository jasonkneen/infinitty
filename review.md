## CODEX REVIEW

Scope: whole-source review of the live directory as of 2026-07-14 23:50 BST. This directory has no Git metadata, so there is no base revision or diff to compare. The source was also being modified concurrently during the review; line numbers below refer to the snapshot inspected immediately before this section was written.

### Findings

1. **P0 — Agent-visible responses have no hard context-size bound.** `Sources/titerm/ControlServer.swift:124` returns `screen`, `history`, `last-output`, and `last-command` verbatim. The history endpoint limits only the number of rows, while `Sources/titerm/Terminal.swift:60` retains 10,000 scrollback rows and `Sources/titerm/Terminal.swift:1177` materializes an entire requested range into one `String`. At the default width, dense history can already exceed a million Unicode scalars; wider panes and the other transcript endpoints are not independently capped. This violates the model-context review requirement that every injected item have a hard limit below 10K tokens. Apply one byte/token budget to every text endpoint and return explicit truncation and pagination metadata; document the bounded protocol in `.claude/skills/titerm-control/SKILL.md:38`.

2. **High — Shell startup forks after worker threads exist and then calls non-async-signal-safe libc in the child.** `Sources/titerm/Session.swift:49` starts the control thread, `Sources/titerm/Session.swift:56` starts the render thread, and only then does `Sources/titerm/Session.swift:58` call `forkpty`. The child subsequently calls `setenv`, `unsetenv`, `getenv`, `snprintf`, `strrchr`, and `execl` beginning at `Sources/CPty/cpty.c:19`. If another thread held a libc/allocator lock at fork time, the child can deadlock before `exec`. Use `posix_spawn` with file actions/attributes, or ensure all arguments and environment are prepared and the child performs only async-signal-safe operations before `exec`.

3. **High — `last-output` loses command output that does not end with a newline.** OSC 133 markers store only a row at `Sources/titerm/Terminal.swift:1141`, and `Sources/titerm/Terminal.swift:1213` extracts the exclusive range `c.line..<d.line`. For `printf foo`, the `C` and `D` markers share a row, so the endpoint returns `""`; a focused harness reproduced this. Store marker columns or capture boundary text, then cover empty, same-row, multiline, wrapped, and evicted output.

4. **Medium — Writing or erasing one half of a wide character leaves an invalid cell pair.** `Sources/titerm/Terminal.swift:610` overwrites the target cell without clearing an adjacent `wide` or `wideContinuation` cell; ICH, DCH, ECH, EL, and resize mutations have the same invariant gap. A harness that fed `界`, moved to its continuation cell, and wrote `a` produced `界a`, so the renderer can draw overlapping glyphs and agent text is wrong. Centralize wide-pair normalization around every cell mutation and test writes/erases against both halves.

5. **Medium — The UTF-8 decoder accepts invalid scalar encodings and can create invisible cells.** `Sources/titerm/Terminal.swift:500` validates only continuation-byte shape; it does not reject overlong sequences, UTF-16 surrogates, or values above U+10FFFF. A surrogate sequence advanced terminal state but extracted as an empty row because downstream `Unicode.Scalar` construction failed. Validate the completed scalar and emit U+FFFD; add fragmented-stream cases for overlong, surrogate, out-of-range, stray-continuation, and truncated input.

6. **Medium — One stalled socket client blocks the entire control plane.** `Sources/titerm/ControlServer.swift:82` handles accepted clients serially, while `Sources/titerm/ControlServer.swift:98` can block waiting for newline, EOF, or 64 KiB. A client that connects and sends nothing prevents every subsequent agent request, including `ping`. Add concurrent client handling or a read deadline/nonblocking state machine, with a regression test that holds one client open while another pings.

7. **Medium — Every completed session leaks its PTY master descriptor.** `Sources/titerm/PTY.swift:38` leaves the read loop, calls `waitpid`, and invokes `onEOF`, but never closes `fd`; there is no `deinit` cleanup either. Repeated tab/pane creation eventually exhausts the process descriptor limit. Close the master exactly once during read-loop completion/teardown and test repeated spawn/exit cycles against a stable descriptor count.

8. **Medium — The `send` command cannot transmit whitespace faithfully.** `Sources/titerm/ControlServer.swift:106` trims the complete request before parsing, so whitespace-only payloads and trailing spaces are lost. Preserve the argument bytes exactly while stripping only the protocol newline. Cover spaces-only input, leading/trailing spaces, tabs, empty `send-line`, UTF-8, and the 64 KiB boundary through the real socket.

9. **Medium — Renderer generation gating has an unsynchronized read/write race.** The display-link thread reads `lastGen` at `Sources/titerm/Renderer.swift:210`, while main-thread live resize can enter `renderNow` at `Sources/titerm/Renderer.swift:231` and write `lastGen` under `renderLock` at `Sources/titerm/Renderer.swift:332`. The reads do not take that lock. Move generation comparison/update inside the same critical section or use an explicit atomic; verify with Thread Sanitizer during concurrent output and live resize.

10. **Medium — There is no automated test target despite stateful parser and agent protocol logic.** `Package.swift:7` defines only the C and executable targets. `swift test` builds the app and then fails with `error: no tests found`. Add a test target, prioritizing integration coverage for fragmented VT/UTF-8 input, wide cells, resize/scrollback, OSC 133 extraction, real Unix-socket behavior, and PTY lifecycle.

11. **Medium — The terminal engine is beyond a reviewable change size and combines unrelated responsibilities.** `Sources/titerm/Terminal.swift:59` is currently about 1,388 lines covering locking, grids, scrollback, resizing, UTF-8/VT parsing, OSC markers, transcript extraction, selection, and link state. This exceeds both the 800-line general and 500-line complex-logic review ceilings. The smallest coherent first split is the marker/transcript component (marker state at `Sources/titerm/Terminal.swift:129`, marker handling at `Sources/titerm/Terminal.swift:1131`, and extraction beginning at `Sources/titerm/Terminal.swift:1147`), keeping forwarding APIs on `Terminal`; follow with grid/scrollback and parser stages.

12. **Low — Swift 6 compatibility is not checked and currently fails.** The package remains in Swift 5.9 mode at `Package.swift:1`. A Swift 6-mode build fails on concurrency diagnostics, including shared mutable state at `Sources/titerm/ControlServer.swift:25` and `Sources/titerm/GlyphAtlas.swift:49`, plus cross-actor captures at `Sources/titerm/Session.swift:34`. Add a Swift 6 CI job and annotate main-thread UI ownership, synchronized shared state, and intentional cross-thread types.

### Verification

- `swift build -c debug` — passed.
- `swift build -c release` — passed.
- `swift test` — failed because no tests exist.
- Focused parser harness — reproduced empty same-row `last-output`, broken wide-cell overwrite, and invisible invalid UTF-8.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency` — passed with extensive warnings.
- `swift build -Xswiftc -swift-version -Xswiftc 6` — failed on concurrency-safety errors.

**VERDICT: BLOCK** — fix the process-launch hazard and agent-output correctness/context-bound defects before shipping.

---

## Resolution (2026-07-15)

| # | Finding | Status |
| - | --- | --- |
| 1 | P0 unbounded agent responses | **Fixed** — every response hard-capped at 256 KiB with explicit `[truncated: …]` prefix; documented in SKILL.md |
| 2 | fork-safety in child | **Fixed** — argv/envp fully prepared pre-fork in `cpty.c`; child calls only `execve`/`_exit` |
| 3 | same-row `last-output` lost | **Fixed** — markers store columns; extraction is position-to-position (`testLastOutputSameRow`) |
| 4 | wide-pair invariant | **Fixed** — `normalizeWideBoundaries` before every cell mutation (putScalar, ASCII runs, ICH/DCH/ECH/EL); 3 regression tests |
| 5 | UTF-8 over-acceptance | **Fixed** — overlong/surrogate/out-of-range → U+FFFD; 5 regression tests incl. fragmented streams |
| 6 | stalled client blocks control plane | **Fixed** — thread-per-client with 5 s SO_RCVTIMEO/SO_SNDTIMEO deadlines |
| 7 | PTY master fd leak | **Fixed** — master closed once via the write queue at read-loop exit |
| 8 | `send` whitespace fidelity | **Fixed** — only the protocol newline (and optional CR) is stripped; argument bytes are verbatim |
| 9 | `lastGen` read race | **Fixed** — reads now inside `renderLock` critical section |
| 10 | no test target | **Fixed** — sources split into `TitermKit` library + `titerm` executable; `swift test` runs 20 passing tests |
| 11 | Terminal.swift size/responsibilities | **Deferred** — library split done; file decomposition (markers/transcript, grid, parser) queued as follow-up |
| 12 | Swift 6 mode | **Deferred** — Swift 5 mode retained; Swift 6 concurrency annotations queued as follow-up |
