# Infinitty responsiveness — review & fixes

**Date:** 2026-07-21  
**Branch:** `dev`  
**Goal:** Keep the product claim honest — a high-power terminal that does not lock up under load.

---

## Verdict

The core architecture still matches the README: **main never parses PTY bytes**, writes are async, render runs on its own display-link thread, and control sockets sit on utility QoS.

Absolute **“NEVER locks up”** was overstated in a few paths. Those holes are closed below. Text floods, agent control, and live resize were already on solid ground; images, first-history load, long `feed` batches, and a few AppKit/GPU edges were not.

---

## Design (unchanged principles)

| Thread | QoS | Job |
| --- | --- | --- |
| PTY read | `.userInitiated` | 256 KB batched reads + VT parse |
| Render | `.userInteractive` | CADisplayLink → Metal encode |
| PTY write | `.userInitiated` serial queue | keystrokes / paste (never blocks UI) |
| Image decode | `.userInitiated` queue | OSC 1337 / kitty (new) |
| Markdown | `.utility` | optional glow re-render (already off-lock) |
| Control socket | `.utility` | agent queries |
| Main | — | input events + window management |

Shared terminal state: one cell grid behind a single unfair lock, held briefly. Renderer takes snapshots; parser never waits on the GPU.

---

## What was wrong

### P0 — Image decode under the terminal lock

OSC 1337 and kitty graphics ran ImageIO / base64 / file I/O / zlib **inside** `process()` while `feed` held the lock. Large inline images could freeze:

- the renderer (no snapshots)
- AppKit main (keystrokes, resize, selection all wait on the same lock)

### P1 — Shell history load under the lock

First `HintEngine.suggest` could synchronously read and parse `~/.zsh_history` (up to 5k lines) while still under the terminal lock from `feed` → one-time input stall.

### P1 — Long `feed` batches

`feed` held the lock for an entire kernel-sized buffer (up to 256 KB). Under `yes` / big `cat`, main could only sneak in keystrokes between buffers — lag, not hard freeze.

### P2 — Glyph build under `renderLock`

`copySnapshot` + `buildInstances` (including cold-path CoreText rasterization) ran while holding `renderLock`. Main callers (`applyConfig`, `updateScale`, `petHitRect`) could hitch.

### P2 — Unbounded `nextDrawable`

Inflight GPU slots were timed out (100 ms); `CAMetalLayer.nextDrawable()` was not. GPU starvation could park the render thread indefinitely (picture frozen; input usually still live).

### P3 — Smaller issues

- `NSSound.beep()` from the PTY thread  
- Idle display-link pause counted **frames** (Hz-dependent; not truly “~1 s”)  
- `PTY.spawn` `fatalError` on forkpty failure crashed the whole app  

---

## What we fixed

### 1. Async image pipeline (`Terminal.swift`)

- Under lock: parse cheap metadata, copy payload, queue a job, capture absLine/col/cell metrics.  
- Off lock (`infinitty.image`): base64, file read, zlib, ImageIO.  
- Under lock again: place sprite; **only advance cursor if it is still at the capture site**.  
- Covers OSC 1337 File= and kitty `q` / `t` / `T`. Store/delete/place-from-store stay cheap and sync.

### 2. Chunked feed (`Terminal.swift`)

- Unlock every **16 KB** so main can interleave resize/keystrokes during floods.  
- Hints refresh only on the **last** chunk of a batch.  
- Image jobs drain after each chunk unlock.

### 3. History preload (`HintEngine.swift`)

- Histfile load starts on `aiQueue` at engine init.  
- `suggest()` only reads the in-memory cache + CLI specs + AI cache — **no File I/O** under the terminal lock.  
- First ~100 ms may miss history matches; CLI completions still work.

### 4. Slimmer render critical section (`Renderer.swift`)

- Under `renderLock`: copy atlas/theme/pet/inset pointers only.  
- Outside: `copySnapshot` + `buildInstances` (glyph rasterize uses atlas’s own lock).  
- `layer.allowsNextDrawableTimeout = true` so a saturated GPU drops frames instead of wedging the render thread.  
- Idle pause: **1.0 s wall-clock** via `CACurrentMediaTime()`, not 120 frames.

### 5. Spawn + bell hygiene (`PTY.swift`, `Session.swift`)

- `spawn` returns `Bool`; failure shows a sheet and tears the pane down — no process-wide crash.  
- Bell → `NSSound.beep` + pet animator on **main**.

---

## Verification

```
swift build                          # ok
swift test --filter TerminalTests    # 20/20 pass
```

Not re-run live in this pass: README’s 18.8 MB `cat` timing, GPU saturation, or interactive `imgcat` under flood. Recommended smoke checks:

1. `yes` (or large `cat`) while typing and scrolling  
2. Live window resize during flood  
3. Inline image (`imgcat` / kitty) while the terminal is busy  
4. First open with a huge `HISTFILE` + hints on  

---

## Residual risk (honest)

| Scenario | Expected now |
| --- | --- |
| Multi‑MB text flood | UI stays usable; keystroke latency much lower than pre-chunking |
| Agent socket + human typing | Fine (utility QoS, client caps, deadlines) |
| Live resize under load | Fine (no GPU wait on main) |
| Large inline images | Decode off-lock; may appear a frame late; cursor advance skipped if site moved |
| Saturated GPU | Dropped frames / nil drawable; input should continue |
| First keystrokes before hist load | History ghost text may lag briefly |

The slogan is much closer to true. Remaining latency under pathological floods is lock-hold time for pure VT parse (unavoidable without a larger redesign), not File I/O or ImageIO on the hot path.

---

## Files touched

- `Sources/InfinittyKit/Terminal.swift`  
- `Sources/InfinittyKit/HintEngine.swift`  
- `Sources/InfinittyKit/Renderer.swift`  
- `Sources/InfinittyKit/PTY.swift`  
- `Sources/InfinittyKit/Session.swift`  
