
# infinitty

<img align="left" width="100" height="100" alt="436305ef-b7fb-40cd-9526-766c153b2ec2 Background Removed" src="https://github.com/user-attachments/assets/1059db5e-a3f9-400f-b0bd-6e95e77213a6" />

A GPU-native macOS terminal emulator built for two audiences: humans who never
want to see a frozen terminal again, and **agents/LLMs**, which get a
first-class machine interface to the live terminal instead of screen-scraping.

Pure Swift + Metal. No Electron, no web view, no frameworks beyond the OS.

## Measured performance

On an Apple Silicon MacBook (M3), release build:

- `cat` of a 18.8 MB / 2,000,000-line file: **0.95 s** (~20 MB/s, ~2.1M lines/s)
- UI stays fully responsive during output floods (input, scrolling, and the
  control socket all keep working — verified during the benchmark)
- Idle cost: zero GPU frames, and the render display link **pauses itself**
  after ~1 s of no output, so idle CPU is zero too

## Why it doesn't freeze

The design rule: **the main thread never touches bytes**.

| Thread | QoS | Job |
| --- | --- | --- |
| PTY read | `.userInitiated` (P-core) | 256 KB batched reads + VT parsing |
| Render | `.userInteractive` (P-core) | CADisplayLink → Metal encode |
| PTY write | `.userInitiated` serial queue | keystrokes/paste, never blocks UI |
| Control socket | `.utility` (E-core) | agent queries |
| Main | — | input events + window management only |

QoS classes are how macOS decides P-core vs E-core placement on Apple
Silicon: latency-critical work lands on performance cores, the agent control
plane on efficiency cores.

Shared state is one cell grid behind a single `os_unfair_lock`, held for
microseconds: the parser applies whole kernel-buffer batches, the renderer
snapshots rows by reference (copy-on-write does the rest). Nothing waits on
anything slow while holding it.

## Why it's fast

- **Parsing**: single-pass VT state machine with a bulk fast path — printable
  ASCII runs are blitted straight into row memory, skipping the state machine
  per byte. 16-byte POD cells, `-Ounchecked` release build.
- **Rendering**: instanced Metal quads — one draw call for run-merged
  background rects, one for glyphs, one for decorations. Glyphs rasterize once
  (CoreText, device-pixel scale) into an R8 shelf-packed atlas; after warmup a
  frame is just three instanced draws. Triple-buffered, `framebufferOnly`,
  opaque layer.
- **Damage gating**: frames render only when the terminal generation counter
  changes. A flood of output coalesces to the display's refresh rate; the
  parser never waits for the GPU.
- **Resize**: during live resize infinitty switches to synchronous
  `presentsWithTransaction` presentation, so content stays glued to the window
  edge — no jelly, no white flash.
- **Scrolling**: rows are reference-swapped, not copied; scrollback is a ring
  of 10,000 rows.

## Built for agents

infinitty exposes a control socket at `$INFINITTY_SOCKET` (exported to the shell,
`0600`, one command per connection, newline-terminated):

```
printf 'screen\n'        | nc -U "$INFINITTY_SOCKET"   # visible screen as text
printf 'history 500\n'   | nc -U "$INFINITTY_SOCKET"   # last N lines incl. scrollback
printf 'last-output\n'   | nc -U "$INFINITTY_SOCKET"   # output of last command *
printf 'last-command\n'  | nc -U "$INFINITTY_SOCKET"   # the command line itself *
printf 'exit-code\n'     | nc -U "$INFINITTY_SOCKET"   # its exit code *
printf 'send-line ls\n'  | nc -U "$INFINITTY_SOCKET"   # type into the terminal
printf 'send text\n'     | nc -U "$INFINITTY_SOCKET"   # type without return
```

`*` needs OSC 133 semantic prompts — source `shell-integration/infinitty.zsh`
from your `~/.zshrc`. infinitty parses the markers (prompt start, input start,
output start, exit) and tracks command regions by absolute line number, so
"give me exactly the last command's output" is an O(1) lookup, not a heuristic.

An agent driving a shell can therefore: run a command, wait, read precisely
its output and exit code, and never parse ANSI soup. That's the interface a
model wants.

### App-level API (control infinitty from other apps)

One socket per infinitty process, discoverable at `/tmp/infinitty-current.sock`:

```
printf 'list\n'                | nc -U /tmp/infinitty-current.sock  # panes as JSON
printf 'run 1 make test\n'     | nc -U /tmp/infinitty-current.sock  # sync: {"exitCode":0,"output":…}
printf 'new-tab\n'             | nc -U /tmp/infinitty-current.sock  # returns new pane id
printf 'split 1 right\n'       | nc -U /tmp/infinitty-current.sock
printf 'focus 2\n'             | nc -U /tmp/infinitty-current.sock
printf 'activity deploying…\n' | nc -U /tmp/infinitty-current.sock  # post to the notch widget
printf 'subscribe\n'           | nc -U /tmp/infinitty-current.sock  # JSON event stream
```

Plus per-pane proxies (`send`, `send-line`, `screen`, `history`,
`last-output`, `last-command`, `exit-code` — all `<cmd> <pane-id> …`).
`subscribe` streams `pane-opened`, `pane-closed`, `title`, and `marker`
events as JSON lines. Socket-driven input lights the agent glow.

### MCP server

`infinitty-mcp` (built alongside the app) exposes all of it as MCP tools —
`infinitty_run`, `infinitty_list_panes`, `infinitty_screen`, `infinitty_send`,
`infinitty_split`, `infinitty_activity`, and more:

```sh
claude mcp add infinitty -- ~/Documents/GitHub/infinitty/.build/release/infinitty-mcp
```

`infinitty_run` is the headline: it types the command, waits for the OSC 133
done-marker, and returns `{"exitCode": …, "output": …}` in one tool call.

## Install

```sh
npm install -g @jasonkneen/infinitty   # downloads release binaries
infinitty
```

Or grab the tarball from [GitHub Releases](https://github.com/jasonkneen/infinitty/releases).

## Build & run from source

```sh
swift build -c release
.build/release/infinitty
```

### Releasing

Signed + notarized releases are cut locally with one command; the full
process, one-time setup, and cert-recovery steps are in
**[RELEASING.md](RELEASING.md)**.

```sh
swift build -c release --arch arm64 --arch x86_64
./scripts/ship-signed.sh 0.1.1
```

Requires macOS 14+ and Xcode command line tools. `$SHELL` is spawned as a
login shell with `TERM=xterm-256color` and `COLORTERM=truecolor`.

### Configuration

Config file at `~/.config/infinitty/infinitty.conf` (or `~/.infinitty.conf`), see
`infinitty.conf.example`:

```ini
font         = Berkeley Mono   # any installed font (default: SF Mono)
font-style   = Thin            # face style: Thin, Light, Medium, SemiBold, ...
font-thicken = false           # ghostty-style stroke thickening
font-size    = 13              # points
margin       = 8               # window content margin, points
line-spacing = 1.0             # line height multiplier
kerning      = 1.0             # cell width multiplier (letter spacing)
foreground   = #D7DAE0         # hex or basic color names
background   = #0F1216
cursor-color = #AEB8C4
```

**Live reload**: the config file is watched — edits apply to every open pane
within ~150 ms. Also ⌘R, or `printf 'reload\n' | nc -U "$INFINITTY_SOCKET"`.

**Ghostty compatibility**: Ghostty key names work (`font-family`,
`window-padding-x/y`, `adjust-cell-width` / `adjust-cell-height` in `%` or
pixels, `font-thicken`), and if no infinitty config exists, the keys infinitty
understands are read from `~/.config/ghostty/config` automatically.

Environment variables override everything: `INFINITTY_FONT`, `INFINITTY_FONT_SIZE`,
`INFINITTY_MARGIN`, `INFINITTY_LINE_SPACING`, `INFINITTY_KERNING`; `INFINITTY_CONFIG`
points at an alternate config file.

### Nerd Fonts

Works out of the box: icon/powerline glyphs (Private Use Area) resolve
through a fallback chain of installed Nerd Fonts even when the primary font
lacks them, icons are centered in their cell, and powerline separators
(U+E0B0–U+E0BF) are stretched from their outlines to fill the cell exactly —
seamless prompt segments at any line spacing. Set `INFINITTY_FONT` to a Nerd
Font to use one everywhere.

### Tabs, splits, mouse, selection

- **Tabs**: native macOS tabs — ⌘T new tab, ⌘N new window, tab bar "+" works
- **Splits**: ⌘D split right, ⇧⌘D split down, arbitrarily nested; ⌘W closes
  the focused pane (tab closes when its last pane exits)
- **Mouse reporting**: click/drag/motion/scroll forwarded to apps that ask
  (vim, tmux, htop, lazygit; modes 9/1000/1002/1003, SGR + legacy encoding).
  Hold **Shift** to scroll local scrollback or select while an app owns the mouse.
- **Selection & copy**: drag to select (scrollback-stable), double-click for
  word, triple-click for line, ⌘C copies
- **Links**: hold ⌘ and hover to highlight URLs; ⌘-click opens them
- **Drag & drop**: files dropped on the window insert shell-escaped paths;
  dropped text pastes (bracketed when apps ask)
- **Shift+Enter** sends CSI-u `13;2u` — newline-without-submit in Claude Code
  and other modern TUIs
- **Inline images**: both major protocols — iTerm2 OSC 1337 `File=` and the
  kitty graphics protocol (chunked base64, PNG + raw RGB/RGBA incl. zlib,
  direct & temp-file transmission, transmit/put/query/delete with protocol
  responses so `kitten icat`, yazi, chafa detect support). Images scroll with
  content and live in scrollback.
- **Window dragging is titlebar-only**; drags in the grid always select.
  Right-click for context menu: copy/paste, 4-way splits, rename tab, reset.
- **Rename the active tab**: ⌃-click **Rename Tab…** in the right-click menu,
  or **double-click the titlebar** (the area where the active tab's title
  is drawn). An inline field pops over the titlebar — ⏎ commits, ⎋ cancels,
  empty restores the automatic title.
- **⌘-click a .md path** opens it via `markdown-command` (default `glow -p`)
- **Agent glow**: a pulsing inner border while an agent drives the pane over
  the control socket (disable with `agent-glow = false`)
- **Notch widget placement**: `notch-display = builtin | external | primary | all`

### Settings, window chrome, pets

- **Settings window** (⌘,): edits the config file, so changes apply live to
  every pane and persist
- **Titlebar**: `titlebar = transparent | hidden`; traffic lights in
  `circle | square | rectangle | diamond`
- **Transparency**: `background-opacity = 0.9`, `background-blur = true`
  (frosted behind-window blur)
- **Codex pets**: `pet = r2d2` renders your installed `~/.codex/pets`
  spritesheets animated in the corner — idle loop normally, running loop
  while output flows
- **Notch live activity**: `notch = true` shows a slim strip beside the
  MacBook notch with the running command and its exit status (OSC 133)

## Terminal feature coverage

Full xterm-256color core: CSI cursor/erase/insert/delete/scroll-region ops,
SGR incl. bold/faint/italic/underline/inverse/strikethrough, 16/256/truecolor,
alt screen (vim, htop, tmux), origin mode, DEC line-drawing charset, tab
stops, bracketed paste, DECALN, DA/DSR reports, wide (CJK) characters,
OSC 0/2 titles, OSC 133 semantic prompts.

## Honest limitations

- No IME/dead-key composition, no ligatures
- Emoji render monochrome (alpha atlas; color atlas is a planned second texture)
- Combining characters are dropped rather than composed
- URLs that wrap across lines aren't detected as one link
- Titlebar/chrome changes apply to new windows, not already-open ones
- `swift test` covers the terminal engine; UI interactions are manual

## Architecture map

```
Sources/CPty/            C shim: forkpty + TIOCSWINSZ (zero Swift/C friction)
Sources/infinitty/
  Terminal.swift         cell grid, scrollback ring, VT parser, OSC 133 markers
  Theme.swift            16-byte Cell, color encoding, 256-color palette
  GlyphAtlas.swift       CoreText -> shelf-packed R8 Metal atlas
  Renderer.swift         instanced Metal pipelines, display-link render thread
  Shaders.swift          MSL source (compiled at startup)
  PTY.swift              read thread, serial write queue
  ControlServer.swift    $INFINITTY_SOCKET agent interface (one per pane)
  TerminalView.swift     keyboard/mouse encoding, scrollback, live-resize
  Session.swift          one pane = terminal + pty + renderer + view + socket
  Config.swift           INFINITTY_* environment configuration
  App.swift, main.swift  windows, native tabs, split panes, menu
shell-integration/       OSC 133 zsh hook
```

## License

MIT © [Jason Kneen](https://github.com/jasonkneen) · [infinitty.ai](https://infinitty.ai)
