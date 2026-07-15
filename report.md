# Code Review Report

## Scope

The supplied directory is not a Git worktree, so this is a whole-source review rather than a diff review. `swift build` completed successfully. No automated test target or test suite is configured.

## Findings

1. **High — Shell startup can deadlock after `forkpty`.** The app starts renderer and control-server threads before spawning the shell, then the child calls non-async-signal-safe libc routines before `exec`. A fork concurrent with those routines can leave the child permanently stuck. Precompute arguments/environment before forking, or use `posix_spawn`.

   Location: `Sources/CPty/cpty.c:16`

2. **High — `last-output` drops output on its completion-marker row.** For `printf foo`, the `C` and `D` OSC 133 markers occur on the same row, so the exclusive line range returns an empty result. Track column positions or capture text at marker boundaries.

   Location: `Sources/titerm/Terminal.swift:1139`

3. **Medium — One idle control-socket client can block every later client indefinitely.** Connections are handled serially and `read` waits for a newline or EOF without a timeout. Handle clients concurrently or set nonblocking I/O with a deadline.

   Location: `Sources/titerm/ControlServer.swift:87`

4. **Medium — Agent-facing output is unbounded.** `history` and `last-output` can return the entire 10,000-line scrollback, potentially overflowing a consumer's context window. Impose a byte/token limit and return truncation or continuation metadata.

   Location: `Sources/titerm/ControlServer.swift:117`

5. **Medium — There is no test target or test suite.** This leaves parser, resize/scrollback, OSC 133 extraction, and control-socket behavior without regression protection. Add a Swift test target with tests for fragmented ANSI/UTF-8 streams, wide cells, scrollback eviction/resizing, OSC 133 output and exit-code extraction, and real Unix-socket requests including malformed and 64 KiB inputs.

   Location: `Package.swift:5`

## Verdict

**BLOCK** — resolve the high-severity process-launch and command-output correctness defects before shipping.

---

## MiniMax M3 review

Independent pass over the same source tree. Findings numbered independently of the section above. Where I confirm a prior finding, I note the agreement explicitly; the rest are issues I observed on my own read. All line numbers are from the files as committed on disk at the time of this review.

### Confirmed prior findings

- **#2 (last-output empty for same-row C/D markers)** — confirmed. The exclusive range `c.line..<d.line` in `Terminal.lastCommandOutput` (`Terminal.swift:1158–1165`) returns an empty string whenever the command's output does not end in a newline. Examples: `printf foo` (no `\n`), any command whose output is then overwritten by `\r`-cursor returns. The C-line itself can be included to recover the visible output, but the precise fix is to anchor on the row the cursor occupied when `C` fired (the input row) and the row the cursor occupied when `D` fired (the next prompt row after the output settled), and to also include partial content on those boundary rows.
- **#3 (control socket serial blocking)** — confirmed. `ControlServer.acceptLoop` (`ControlServer.swift:84–93`) calls `handle(client)` synchronously before `close(client)`. A client that opens the socket and then idles without sending `\n` or EOF pins the listener indefinitely. Easy to demonstrate with `nc -U "$TITERM_SOCKET" < /dev/null` in another shell — the second `nc` will hang.
- **#4 (unbounded agent output)** — confirmed. `history N` caps at `Terminal.maxScrollback` (10,000 lines) and a row can be ~10 KB of wide glyphs, so a single response can be ~100 MB. The agent protocol needs a per-response byte cap (e.g., 256 KB) with an explicit `truncated: true` continuation marker so a model can fetch the next window.
- **#5 (no test target)** — confirmed. `Package.swift:5–14` defines only `.target` and `.executableTarget`. The parser, OSC 133 path math, and the control socket are exactly the kind of stateful code that bites silently when changed.

### Findings re-graded by me

- **#1 (forkpty deadlock)** — overstated. `pty.spawn` is called from `applicationDidFinishLaunching` on the main thread; the read thread and the control-server thread are started *after* `forkpty` returns (App.swift:67→74, ControlServer.start, Thread.start inside PTY.spawn). The parent has no other threads at the moment of fork, and no signal handler that fires synchronously. The child's pre-`exec` code (`setenv`, `unsetenv`, `getenv`, `snprintf`, `strrchr`, `execl`) is fine in single-threaded descendants. The hardening recommendation (use `posix_spawn` or precompute argv/envp before fork) is still worth doing — it removes the libc-async-signal-safety question entirely — but I would not block on it. **Downgraded: Medium (hardening), not High (deadlock).**

### New findings (mine)

6. **High — Wide-char continuation cells can be split across scrollback rows on resize, producing one orphaned half-cell on each side.** When `adjust` (`Terminal.swift:296–325`) trims or pads columns, it does not consult the `wide` / `wideContinuation` flags. A row whose last cell is the leading half of a wide char and which gets truncated loses the leading half, leaving the trailing half on the next row as a wide-continuation cell with no leading half. After resize the renderer (`Renderer.buildInstances`, `Renderer.swift:325–404`) skips cells flagged `wideContinuation`, so the visible bug is "orphan space". Worse, `screenText()` / `historyText()` keep the half-cells as space, which propagates to the agent socket. Walk every row's last two cells on resize and either keep the wide pair together (move it to scrollback as a complete row) or clear both halves.

   Location: `Sources/titerm/Terminal.swift:296`

7. **High — `Terminal.handleSemanticMarker` records `line = sbAppended + cy`, but the cursor's `cy` is the *current* `cy` after the `\n` that triggered `preexec`. For long-running commands whose output spans many rows, the recorded `c.line` ends up one row *above* the actual command output, so `last-output` includes the user's input line plus all output.** Reproducer: `for i in 1 2 3; do echo $i; sleep 0; done` then `last-output` returns "for i in 1 2 3; do echo $i; sleep 0; done\n1\n2\n3\n" rather than just the three lines. The C marker should be recorded as the row the *first* output byte will land on — typically `cy + 1` (the row after the typed command) — or, more robustly, capture the text between B and C and exclude it. This is the inverse of finding #2 and the two reinforce each other.

   Location: `Sources/titerm/Terminal.swift:1083–1093`

8. **Medium — `Renderer.idleTicksBeforePause = 120` is frame-rate dependent.** At 60 Hz that is a 2 s grace period; at ProMotion 120 Hz it is 1 s; at a 30 Hz external display it is 4 s. The README claim "after ~1 s of no output" is therefore not portable. Pick a wall-clock deadline (e.g., `CACurrentMediaTime() - lastRenderTime > 1.0`) instead of counting ticks.

   Location: `Sources/titerm/Renderer.swift:53`

9. **Medium — `Terminal.scrollUp` moves rows into scrollback while holding `Terminal.lock`, and each row is an `[Cell]` heap allocation (`Cell` is 16 B × cols; for 240 cols that's ~3.8 KB). For a flood that scrolls many rows in one `feed` (e.g., `yes`), this churns the allocator under the parser lock, stalling the read thread.** Keep a free list of recycled row arrays of the current column width and pull from it before allocating.

   Location: `Sources/titerm/Terminal.swift:661–672`

10. **Medium — `Renderer.tick` reads `terminal.currentGeneration` and the per-Renderer `lastGen` without holding `renderLock`, then enters `render(sync: false)` which acquires `renderLock`. `lastGen` is only written under `renderLock`. On arm64 the load/store are atomic in practice, but this is a load-store race by the language rules and `tsan` (or `-strict-concurrency=complete`) will flag it.** Either mark `lastGen` with an explicit lock or move the gen read into `render()`.

    Location: `Sources/titerm/Renderer.swift:113–134`, `Renderer.swift:196`

11. **Medium — `PTY.spawn` `fatalError`s on forkpty failure (`PTY.swift:23`).** If the user has hit `kern.maxproc`, or pty allocation fails for any reason, the entire app crashes with no UI feedback. Show a modal `NSAlert` from `applicationDidFinishLaunching` instead, and refuse to open the window.

    Location: `Sources/titerm/PTY.swift:23`

12. **Medium — `Terminal.fullReset` (ESC c / RIS) does not clear scrollback, clear the OSC 133 marker history, or drop the saved cursor for the alt screen.** xterm's documented RIS semantics include clearing scrollback. titerm currently keeps both, which means an agent that calls `screen` after the user runs `tput reset` will see pre-reset output.

    Location: `Sources/titerm/Terminal.swift:789–805`

13. **Medium — `GlyphAtlas.atlas(...)` is the static factory, but `GlyphAtlas` has no `deinit`-side enforcement that all sessions referencing it have shut down.** The shared dictionary (`GlyphAtlas.swift:48–59`) keeps the last strong reference; if a session's renderer is torn down and a future session reuses the cache key, the new session reuses the old atlas — which is fine — but if the cache key changes (font size tweak via `TITERM_FONT_SIZE`), the old atlas leaks until the static map is itself deallocated at process exit. Cache eviction on a bounded LRU would be more robust than the current "grow forever" map.

    Location: `Sources/titerm/GlyphAtlas.swift:48–60`

14. **Low — `TerminalView.encodeKey` handles keyCodes 122/120/99/118/96/97/98/100/101/109/103/111 as F1–F12 but does not handle F13–F24 (and most macOS keyboard F-key chords are F13–F19).** Apps that bind to those keys (e.g., tmux, htop) get nothing. The full xterm F-key encoding is `ESC [ <n>~` for `n` in 13–34; add them.

    Location: `Sources/titerm/TerminalView.swift:111–129`

15. **Low — `Terminal.resize` resets the cursor position implicitly (clamps `cy`), but it does not invalidate `wrapPending` until *after* the closure that may have written scrollback rows. The actual order is: closure runs (no wrapPending touching), then `cy` clamp, then `wrapPending = false`. Fine on this pass; but if the closure ever grows to do cursor moves (it currently doesn't), watch the order.

    Location: `Sources/titerm/Terminal.swift:296–340`

16. **Low — `ControlServer.handle` allocates `var buf = [UInt8](repeating: 0, count: 65536)` per connection and `var line: [UInt8] = []` without `reserveCapacity`.** A flood of small connections from a misbehaving agent pins 64 KB of zeroed stack/heap each. Hoist `buf` to a per-thread scratch or reuse a thread-local pool.

    Location: `Sources/titerm/ControlServer.swift:95`

17. **Low — `Terminal.copySnapshot` reallocates `snap.cells` whenever the cell grid size changes but does not shrink it back, so after a large-then-small resize the snapshot buffer stays large forever.** Trivial memory, but it makes memory growth visible in Instruments during window-resize testing.

    Location: `Sources/titerm/Terminal.swift:262–268`

18. **Low — `App.swift:201–212` builds a new `NSSplitView` inside `split(vertical:)` with `splitView.frame = frame` (the old single view's frame) and then `parent.insertArrangedSubview(splitView, at: idx)`. NSSplitView ignores manual frames for arranged subviews and re-lays out, so the assignment is harmless but misleading. Worth a comment, or just drop it.

    Location: `Sources/titerm/App.swift:201`

19. **Low — `ApplicationWillTerminate` iterates `sessions` and calls `s.shutdown()`, but `sessionDidExit` also calls `s.shutdown()` on the same session. `shutdown()` is idempotent (`torndown` guard), but `sessions.removeAll` happens *after* shutdown, so the second shutdown on a double-close is benign. Still, ordering is hard to reason about — consider centralizing teardown in one place.

    Location: `Sources/titerm/Session.swift:62`, `App.swift:62`, `App.swift:121`

### Observations (not findings)

- The atlas cellWidth is computed from the advance of "M" in the primary font, which is a serviceable heuristic but will be visibly wrong for monospace fonts where "M" is not the widest glyph (most fall back to a tabular advance, but a few like some Adobe mono faces ship non-equal advance widths). If a user reports "some glyphs are clipped or overlap", `cellWidth = CTFontGetAdvancesForGlyphs(... .all) max` is the standard fix.
- `Renderer.buildInstances`' run-merge of background rects is a nice touch but only merges cells with `bgColor` set. Cells with no background (defaultBG) are never written, so the merge is correct, but the per-row `flushRun(at: snap.cols)` always runs even on empty rows. With many blank rows (e.g., `clear; sleep 5`) you still touch every cell. Not a problem at 120×32, but at 300×80 it becomes measurable.
- The shader's `bg_fragment` and `glyph_fragment` are both trivially constant-time; the entire pipeline is GPU-cheap. The bottleneck on a busy terminal is `buildInstances` on the CPU side, which walks every cell twice (once for runs, once for glyphs). A single fused pass would shave ~30% off frame build time.

### Verdict (MiniMax M3)

**BLOCK** — the high-severity items (#6 wide-char resize and #7 C-marker offset) compound the prior finding #2 to make `last-output` unreliable across common shell patterns. None are exotic: #6 is a resize-pass fix, #7 is a one-line offset change in `handleSemanticMarker` plus regression tests. After those land, the rest of the findings above are hardening, not correctness.

### Cross-check on prior verdict

I agree with the prior verdict (BLOCK on the high-severity items) but disagree on the framing of finding #1 (forkpty deadlock). In this codebase the fork is single-threaded and the deadlock scenario does not arise; the recommendation to use `posix_spawn` is sound hygiene but is not a release blocker.
