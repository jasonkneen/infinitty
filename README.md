
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
  per byte. 16-byte POD cells in an optimized release build.
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
printf 'toggle-quick-terminal\n' | nc -U /tmp/infinitty-current.sock
printf 'focus 2\n'             | nc -U /tmp/infinitty-current.sock
printf 'activity deploying…\n' | nc -U /tmp/infinitty-current.sock  # post to the notch widget
printf 'toggle-sidebar\n'      | nc -U /tmp/infinitty-current.sock  # show/hide the Files pane
printf 'sidebar show\n'        | nc -U /tmp/infinitty-current.sock  # show|hide|toggle the Files pane
printf 'sidebar-tab chat\n'    | nc -U /tmp/infinitty-current.sock  # open/focus Files, Changes, or Chat
printf 'chat-model claude\n'   | nc -U /tmp/infinitty-current.sock  # set chat model (name/substring)
printf 'chat-effort high\n'    | nc -U /tmp/infinitty-current.sock  # set effort: auto|low|medium|high
printf 'subscribe\n'           | nc -U /tmp/infinitty-current.sock  # JSON event stream
```

Plus per-pane proxies (`send`, `send-line`, `screen`, `history`,
`last-output`, `last-command`, `exit-code` — all `<cmd> <pane-id> …`).
`subscribe` streams `pane-opened`, `pane-closed`, `title`, and `marker`
events as JSON lines. Socket-driven input lights the agent glow.

### Connected Chat Channels

Every Chat pane has a stable process-local identity (`Chat 1`, `Chat 2`, …).
Drag the circular connector in one pane header onto another pane's connector to
create or join a Channel. Linked headers show a visible badge such as
`Channel 1 · 2`, not color alone. Click that badge to open the Channel as a
first-class movable pane. Its room identity remains visible in the pane header;
the workspace exposes named participants, connected status, editable roles,
room and delegation-thread conversations, plan/dependency status,
responsibility claims, and the durable audit revision. Narrow panes switch to
People / Room / Plan sections so the workspace remains usable beside Chats.

For linked Chat panes, Channel membership is part of every real provider turn:
the agent receives its own participant name, the Channel name, exact peer
names and roles, authoritative responsibility scopes and plan ownership, and
the bounded recent Channel transcript. Accepted user prompts and provider
responses are appended to the durable room log, so a peer's next turn can read
and reference the handoff. Amp participates through the same provider-facing
context path; it is not the headless host. Renames update the stored participant
identity, closing a pane removes it from every peer's live membership, and long
provider replies are explicitly bounded for the shared transcript without
shortening the local answer.

#### Terminal CLI awareness

Agents launched inside ordinary terminal panes use the pane's authenticated
`$INFINITTY_SOCKET` rather than pretending they are Infinitty-owned Chat panes.
The bundled MCP server automatically registers recognized Claude Code, Codex,
Amp, OpenCode, Gemini, Grok, Aider, Qwen, Copilot, Cursor, Droid, Kimi, and
Goose clients as unique participants such as `Claude 1` and `Amp 2`. MCP
initialization now includes the first bounded live
Channel snapshot, so an agent does not need a discovery/tool round before it
knows its room. `infinitty_channel_self` remains available for explicit refresh
and verification; `infinitty_channel_post` publishes with the author and
Channel derived server-side from the owning pane. A caller cannot select
another pane or forge an author ID. MCP registrations are bound to the
server-observed MCP process; normal exit unregisters immediately, forced
termination is reaped by the host, and an older MCP process cannot unregister a
newer owner of the same pane.

For per-turn context without model tool selection, enable **Install Channel
context hooks** in Infinitty settings (or set `mcp-auto-register = true`). The
toggle is off by default because enabling it edits user configuration files.
The initial MCP snapshot and the explicit wrapper do not require the toggle;
native per-turn hooks do. Enabling it merges Claude `SessionStart` and
`UserPromptSubmit` hooks without overwriting existing hooks. The
provider-neutral `infinitty-agent` edge can wrap any CLI:

```sh
infinitty-agent run -- claude
infinitty-agent run --provider amp -- amp
```

When `shell-integration/infinitty.zsh` is sourced inside an Infinitty pane,
recognized CLIs are wrapped automatically. Set
`INFINITTY_AGENT_AUTO_WRAP=0` to disable that behavior. The wrapper registers
the process and preserves its PID/TTY; the context helper is also usable from
provider plugins or hooks:

```sh
infinitty-agent context --format plain
infinitty-agent context --format claude --event UserPromptSubmit
```

Even without the shell wrapper, the visual host registers a recognized
foreground CLI as soon as it appears in a pane. The wrapper remains the
provider-neutral path for headless sessions and CLIs that Infinitty does not
recognize by process name.

The same provider-neutral bridge is available to any local process through the
pane socket. Membership is queried dynamically, so joining or leaving a
Channel after the process starts works without stale environment variables:

```sh
printf 'channel-context\n' | nc -U "$INFINITTY_SOCKET"

# register/post payloads are versioned base64url JSON
register=$(printf '%s' '{"v":1,"displayName":"Ada","role":"reviewer","provider":"claude"}' \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=')
printf 'channel-register %s\n' "$register" | nc -U "$INFINITTY_SOCKET"

message=$(printf '%s' '{"v":1,"text":"Review complete."}' \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=')
printf 'channel-post %s\n' "$message" | nc -U "$INFINITTY_SOCKET"
```

Set `INFINITTY_AGENT_NAME`, `INFINITTY_AGENT_ROLE`,
`INFINITTY_AGENT_PROVIDER`, `INFINITTY_AGENT_MODEL`, or
`INFINITTY_AGENT_SESSION_ID` before launching an MCP-backed agent to override
automatic metadata. Provider and model identifiers remain opaque strings.

Visual and headless processes use one local Channel coordinator and one
tamper-evident journal. Linking endpoints from different Infinitty instances
therefore updates the same authoritative room; live instances receive the new
projection, and another process replays the journal and takes over if the
coordinator owner exits. `infinitty_channel_panel` exposes the same
list/open/focus/close/snapshot/thread-selection/message/role controls through
MCP; a headless process keeps a virtual Channel pane with the same stable
`channel-panel-<channel-id>` identity.

The local audit surface is independently queryable through
`infinitty_audit_query`. Pages contain bounded summaries, are pinned to the
first page's verified journal tip, and are returned only after both hash-chain
verification and fail-closed semantic replay. `infinitty_audit_export` writes
the complete canonical journal to an app-owned private JSONL artifact and signs
it with Infinitty's local Ed25519 authority; callers cannot choose a destination
path. `infinitty_audit_verify` rechecks the signature, payload digest, manifest,
record chain, and semantic replay without invoking provider, pane, worktree, or
other external effects. Rejected and malformed control requests are also
hash-chained with a bounded reason and SHA-256 request fingerprint without
changing room state. This is a verified local audit export, not a claim of WORM
retention or third-party compliance certification.

### Authenticated cloud agents

A room agent with `runtime: "cloud"` must include an approved
`cloudConnection`. Infinitty never accepts a raw token in a proposal and never
falls back to a local CLI. The proposal contains only a credential-free
endpoint and the name of an uppercase environment variable already present in
the addressed visual or headless host. `remoteWorkspace` is the absolute
checkout or mounted-worktree path as seen by the remote runtime; Infinitty binds
it into the human-approved digest and never pretends that a local path is
automatically mounted remotely:

```json
{
  "runtime": "cloud",
  "provider": "codex",
  "modelID": "provider-owned-opaque-model-id",
  "cloudConnection": {
    "endpointURL": "wss://codex-host.example/app-server",
    "credentialEnvironmentVariable": "CODEX_CHANNEL_TOKEN",
    "authentication": "bearer",
    "remoteWorkspace": "/srv/worktrees/channel-release/architect"
  }
}
```

Codex uses the app-server `initialize` / `thread/start` or `thread/resume` /
`turn/start` protocol, streams `item/agentMessage/delta`, and targets
`turn/interrupt` on cancellation. The approved worktree path and opaque model
identifier are sent unchanged. The upstream WebSocket app-server transport is
currently experimental, so deployments must explicitly provide an
authenticated WSS endpoint; Infinitty does not open or expose a listener.

Claude uses the Managed Agents API with an HTTPS endpoint, `agentID`,
`environmentID`, optional `vaultIDs`, and either `api_key` or `bearer`
authentication. It opens the SSE stream before posting `user.message`, treats
preview deltas as provisional, commits only authoritative `agent.message`
events, sends `user.interrupt` on cancellation, and stops for explicit human
handling when the session reports `requires_action`. Managed Agents is an
upstream beta surface.

Before either agent can run, Infinitty authenticates and prepares the remote
session, writes a provider/session/workspace receipt into the tamper-evident
Channel journal, and only then transitions the proposal to `running`. Restarted
headless hosts resume that exact remote session from the durable receipt.
Authentication, protocol, timeout, or remote failures appear in the Chat as
`System` failures and are never recorded as successful agent responses. When
the Chat is connected, the failure is also journaled as a system-authored
Channel message so peers and audit consumers can distinguish it from agent
work.

### Headless terminal/app host

Run Infinitty as a genuine windowless terminal host:

```sh
infinitty --headless ~/Documents/GitHub/myrepo
```

This path does not create `NSApplication`, windows, Metal layers, renderers, or
display links. It still launches real PTYs and exposes instance discovery,
per-terminal sockets, the app control socket, Channel state, event
subscriptions, and the same MCP terminal/Channel tools. UI-only operations such
as browser panes return an explicit unavailable error.

Amp remains an agent provider. Its non-interactive provider transport is
separate from Infinitty's headless app mode.

### MCP server

`infinitty-mcp` (built alongside the app) exposes all of it as MCP tools —
`infinitty_run`, `infinitty_list_panes`, `infinitty_screen`, `infinitty_send`,
`infinitty_split`, `infinitty_channel_self`, `infinitty_channel_post`,
`infinitty_activity`, and more:

```sh
# Installed npm/tarball release:
claude mcp add infinitty -- infinitty-mcp

# Source checkout:
swift build -c release
claude mcp add infinitty -- /path/to/titerm-agent-channels/.build/out/Products/Release/infinitty-mcp
```

The signed app, release tarball, and npm package include both
`infinitty-mcp` and the provider-neutral `infinitty-agent` helper.

`infinitty_run` is the headline: it types the command, waits for the OSC 133
done-marker, and returns `{"exitCode": …, "output": …}` in one tool call.
`infinitty_list_panes` returns stable numeric terminal ids and string handles
for Chat, Channel, Files, and Browser panes. The same handle works with
`infinitty_focus`, `infinitty_split`, `infinitty_close`, and event filtering in
both visual and headless instances.

## Open a folder from anywhere

infinitty takes a folder argument — the shell starts there:

```sh
infinitty ~/Documents/GitHub/myrepo
```

If infinitty is already running, the folder opens as a new tab in the
current window (instant — the argument is forwarded over the control
socket). `open -a Infinitty <folder>` and dropping a folder on the Dock
icon do the same. The socket commands take an optional directory too:
`new-tab [dir]`, `new-window [dir]`.

**GitHub Desktop** — Settings → Integrations → Shell → Configure Custom
Shell…:

- **Path**: `/Applications/Infinitty.app/Contents/MacOS/infinitty` — the
  binary inside the bundle; Desktop rejects the `.app` itself as "not a
  valid executable"
- **Arguments**: `%TARGET_PATH%`

## Install

```sh
npm install -g @jasonkneen/infinitty   # downloads release binaries
infinitty
```

Or grab the tarball from [GitHub Releases](https://github.com/jasonkneen/infinitty/releases).

## Build & run from source

```sh
swift build -c release
.build/out/Products/Release/infinitty
```

### Releasing

Signed + notarized releases are cut locally with one command; the full
process, one-time setup, and cert-recovery steps are in
**[RELEASING.md](RELEASING.md)**.

```sh
swift build -c release --arch arm64 --arch x86_64
./scripts/ship-signed.sh X.Y.Z
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

- **Tabs**: native macOS tabs — ⌘T new tab, ⇧⌘←/→ previous/next tab,
  ⌘1–8 select by position, ⌘9 selects the last tab, and the tab bar "+" works;
  hold ⌘ to reveal the numbers in tab titles; ⇧⌘T renames the active tab
- **Splits**: ⌘D split right, ⇧⌘D split down; right-click either split button
  to choose Terminal, Files, Chat, Channel, or Browser. Splits nest arbitrarily;
  Files contains its own Files/Changes switch, and each main tab can keep one
  Files pane plus multiple independently named Chat and Channel panes alongside
  any number of terminals. ⌘W closes the focused pane (the tab closes when its last
  terminal exits); ⇧⌥←/→/↑/↓ focuses
  and briefly highlights the nearest pane in that direction; hold ⇧⌥ to reveal
  pane numbers and the focused-pane outline, then press ⇧⌥1–9 to focus directly.
  Every pane has compact split controls in its header. Drag a pane header onto
  another pane's edge to move it, or onto the center to swap them; the blue
  preview shows the landing region before anything moves. Double-click a pane
  header or press ⇧⌘Return to zoom it, then repeat to restore the exact split tree.
- **Quick terminal**: set `quick-terminal-key = cmd+shift+space` for a persistent,
  global Quake-style terminal that slides down from the top. Its shell,
  scrollback, splits, and internal tabs stay alive while hidden. Its always-visible
  tab strip supports the `+` and selected-tab close buttons, ⌘T, ⇧⌘←/→, and
  ⌘1–9. It can autohide on
  focus loss and target the main screen, mouse screen, or menu-bar screen. The
  global key uses the macOS hot-key API and does not require Accessibility
  permission. Drag its bottom edge to resize it; the height is remembered across
  launches. ⌘W closes the focused pane (and then its tab when the last pane
  exits); ⇧⌘W hides the panel without terminating any panes.
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
- **Rename a tab**: press ⇧⌘T, choose **Rename Tab…** in the terminal-content
  right-click menu, or double-click its tab title (double-click the window
  title when there is no visible tab strip). Quick-terminal titles become
  editable directly in their tab; native tabs use an anchored rename popover.
  ⏎ commits. Clicking away also commits a quick-terminal rename; for a native
  tab, clicking elsewhere in the same terminal window commits while clicking
  outside it cancels. ⎋ or pressing ⇧⌘T again cancels and discards any
  typed text; an empty name restores the automatic title. Custom names are
  kept in memory for the lifetime of their native or quick-terminal tab; they
  are not restored after the tab closes or the app restarts.
- **Running-process indicator** (native titlebar): the active pane's
  foreground process (e.g. `vim`, `node`, `Safari`) is shown as the window
  subtitle and as a small icon in the trailing edge of the titlebar. The
  icon updates within ~2 s of a command starting/ending, or instantly when
  OSC 133 `C`/`D` markers fire. ⌃-click the icon to refocus the pane it
  describes after a tab switch.
- **⌘-click a .md path** opens it via `markdown-command` (default `glow -p`)
- **Agent glow**: a pulsing inner border while an agent drives the pane over
  the control socket (disable with `agent-glow = false`)
- **Session notch placement**: `notch-display = builtin | external | primary | all`

### Settings, window chrome, pets

- **Settings window** (⌘,): edits the config file, so changes apply live to
  every pane and persist
- **Window chrome**: standard macOS titlebar and tabs; optional traffic lights in
  `circle | square | rectangle | diamond`
- **Transparency**: `background-opacity = 0.9`, `background-blur = true`
  (frosted behind-window blur)
- **Built-in AI pet**: Infinitty's `>_<` face ships enabled by default and
  changes expression as the terminal works, waits, succeeds, or fails. Set
  `pet = none` to hide it, or `pet = r2d2` to use an installed
  `~/.codex/pets` spritesheet instead
- **Session notch**: `notch = true` shows Claude Code to the left and the
  configured Infinitty pet to the right of a centered notch. Notchless external
  screens receive the same simulated center geometry. Click the indicator for
  recent sessions grouped with their subagents, prompts, runtime model names,
  and live/idle/done state; click a session to jump to its terminal or resume it,
  Option-click to continue it in the built-in Chat pane, or right-click for all
  recovery choices.
  Infinitty's running command, exit status (OSC 133), and `infinitty_activity`
  socket/MCP messages continue to appear in the same indicator.

### Mixed Files, Chat, and Channel panes

Files, Chat, and Channel are first-class leaves in the same split tree as
terminals. The
legacy `toggle-sidebar` socket command toggles the Files pane for compatibility.

- **Files / Changes**: One pane with a compact internal switch. Files provides
  directory search, syntax-highlighted previews, and breadcrumb navigation;
  Changes provides Git status, diffs, staging, and unstaging.
- **Chat**: AI agent for conversation and terminal control. Ask questions about
  your code, execute shell commands, read the screen, or switch between panes.
  Choose your AI model (Claude, Codex, or Apple Intelligence) via the dropdown,
  and enable reasoning/thinking via the effort selector for deeper analysis.
- **Channel**: shared room coordination for linked panes. Click a linked
  Channel badge to open it, then steer the room or an individual delegation
  thread, assign participant roles, and inspect plan, responsibility, and audit
  state without merging Chat transcripts.

Each main tab owns its Files/Chat/Channel panes and nested layout independently.
Files and Chat follow the terminal focused in that tab; Channel remains bound
to its durable room ID when moved, closed, or reopened.

### Pane lifecycle ledger

For crash investigation, each run writes a synchronous structural ledger to
`~/Library/Logs/Infinitty/pane-ledger/`. Lines use a stable `tab-<n>` main-tab
ID and a literal `+` / `-` history for terminal, Files, and Chat leaves, along
with the split source, axis, and resulting pane tree. For example:

```
uptime=42.381 seq=18 tab=tab-2 + pane=chat reason=split-insert origin=split-chooser panes=[terminal:4,chat] tree=V[terminal:4,chat]
```

`Changes` is recorded as a page transition inside the Files pane, rather than
as a separate leaf. The ledger intentionally excludes terminal output, shell
commands, chat text, current directories, and file paths.

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
Sources/InfinittyKit/
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
Sources/infinitty-agent/ provider-neutral CLI wrapper/context edge
Sources/infinitty-mcp/   MCP server and terminal/Channel tools
shell-integration/       OSC 133 zsh integration plus agent hooks/wrappers
```

## License

MIT © [Jason Kneen](https://github.com/jasonkneen) · [infinitty.ai](https://infinitty.ai)
