# Launch infinitty with a folder argument (GitHub Desktop et al.)

Date: 2026-07-15
Status: approved (new-tab reuse behavior confirmed by Jason)

## Problem

GitHub Desktop's custom-shell integration spawns an executable with the repo
path substituted for `%TARGET_PATH%`. Today:

- Pointing Desktop at `/Applications/Infinitty.app` fails validation — it
  requires an executable *file*; the Mach-O lives at
  `Infinitty.app/Contents/MacOS/infinitty`.
- infinitty ignores argv entirely, so the folder argument is swallowed.
- The spawned shell inherits the app process cwd (`/` from Finder).
- A second direct-exec launch starts a second app instance.
- No `application(_:open:)` handler, so `open -a Infinitty <folder>` and
  Finder drag-to-Dock do nothing.

## Behavior

`infinitty <folder>`:

- **No instance running** → app launches; first window's shell starts in
  `<folder>`.
- **Instance running** → forward `new-tab <folder>` + `focus` over the app
  control socket (`$INFINITTY_APP_SOCKET`, else `/tmp/infinitty-current.sock`)
  and exit 0. New tab in the current window, raised (human-initiated, unlike
  agent panes). Stale/dead socket → fall back to normal launch.
- Path rules: `~` expanded; relative paths resolved against the caller's cwd;
  a file path uses its parent directory; nonexistent path → ignored (normal
  launch). Args starting with `-` are skipped (AppKit debug flags).

Also: `open -a Infinitty <folder>` and dropping a folder on the Dock icon open
a tab at that folder via `application(_:open:)` + a `public.folder`
`CFBundleDocumentTypes` entry in the bundle's Info.plist.

## Changes

1. `Sources/CPty` — `cpty_spawn_shell(..., const char *cwd)`; child calls
   `chdir(cwd)` between forkpty and execve (async-signal-safe; preserves the
   envp-pre-fork safety rule). chdir failure → shell starts in inherited cwd.
2. `PTY.spawn(cols:rows:socketPath:cwd:)` passthrough.
3. `TerminalSession` — optional `workingDirectory`, used at spawn.
4. `LaunchOptions` (new, InfinittyKit) — pure argv→folder parser, unit-tested.
5. `Sources/infinitty/main.swift` — parse argv; forward-or-launch as above.
6. `AppControlServer` — `new-tab [cwd]`, `new-window [cwd]` (optional path,
   rest of line). `new-tab` with zero windows creates one.
7. `infinitty-mcp` — optional `cwd` property on `infinitty_new_tab` /
   `infinitty_new_window`.
8. `scripts/make-app.sh` — `CFBundleDocumentTypes` (`public.folder`).
9. README — GitHub Desktop setup: Path
   `/Applications/Infinitty.app/Contents/MacOS/infinitty`, Arguments
   `%TARGET_PATH%`.

## Out of scope

⌘T inheriting the current pane's cwd; a `--new-window` flag; `split` cwd.

## Testing

- Unit: `LaunchOptionsTests` (tilde, relative, file→parent, nonexistent,
  dash-arg skipping); existing suite stays green.
- Manual: Desktop custom shell end-to-end, `open -a`, second-launch
  forwarding, stale-socket fallback.
