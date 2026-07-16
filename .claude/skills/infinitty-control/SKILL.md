---
name: infinitty-control
description: Use when controlling infinitty, driving/automating/testing terminal or TUI apps running inside it (vim, htop, REPLs), reading its screen or scrollback, sending keystrokes, or checking a command's output/exit code via the per-pane Unix control socket ($INFINITTY_SOCKET, /tmp/infinitty-*.sock).
---

# infinitty Control Socket

infinitty exposes one Unix socket per pane. Any script can read the live screen and type into the terminal — no screen-scraping, no ANSI parsing. Implementation: `Sources/infinitty/ControlServer.swift`.

## Socket discovery

- **Inside the shell infinitty spawned**: `$INFINITTY_SOCKET` (exported, mode 0600).
- **From outside**: `/tmp/infinitty-<PID>-<N>.sock` — PID is the infinitty process, N counts panes. `ls /tmp/infinitty-*.sock` and pick; `ping` each to find live ones.

## Protocol

One command per connection. Send the command, newline-terminated; read the response until EOF (socket closes after the body). Responses always end with `\n`. Writes return `ok`; failures return a line starting with `error:`.

**Bounded responses**: every response is hard-capped at 256 KiB. Oversized
bodies are truncated from the front and prefixed with a
`[truncated: showing last N bytes]` line — page with `history N` instead of
requesting everything. Connections have a 5s read/write deadline and each
client is served on its own thread, so a stalled client cannot block others.

```sh
printf 'screen\n' | nc -U "$INFINITTY_SOCKET"
```

```python
import socket
def infinitty(cmd, path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.sendall(cmd.encode() + b"\n")
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    s.close()
    return data.decode()
```

## Commands

| Command | Returns |
| --- | --- |
| `screen` | visible screen as plain text |
| `history N` | last N lines incl. scrollback (default 100, clamped 1–10000) |
| `last-output` | output of last **completed** command * |
| `last-command` | that command line as typed * |
| `exit-code` | its exit code * |
| `send TEXT` | types TEXT (no return); everything after the first space, verbatim |
| `send-line TEXT` | types TEXT then return (CR `0x0D`) |
| `reload` | re-applies the config file |
| `ping` | `pong` — liveness check |

`*` Requires OSC 133 shell integration (below); otherwise returns `error: no completed command (enable OSC 133 shell integration)`.

Gotchas:
- A newline in `send` text terminates the command — one line per connection; use `send-line` for return, multiple connections for multiple lines.
- Trailing whitespace on the request is trimmed; leading spaces after `send ` are preserved.
- `send`/`send-line` write raw bytes to the PTY, so control bytes work — see ESC below.

## The wait-for-prompt rule

**Never sleep blindly. Always poll `screen` for the text that proves the terminal is ready** (a prompt, an app's UI, expected output) **before sending keys or reading results.** Keys sent early go to the wrong program; `exit-code`/`last-output` read early return the *previous* command's values.

```sh
wait_for() {  # wait_for PATTERN [TIMEOUT_S]
  local t=${2:-10} start=$SECONDS
  until printf 'screen\n' | nc -U "$INFINITTY_SOCKET" | grep -q "$1"; do
    (( SECONDS - start >= t )) && return 1
    sleep 0.2
  done
}
```

## Driving TUI apps (vim example)

Send keys with `send`, poll `screen` between steps. ESC and other control bytes go through `printf` escapes:

```sh
S="$INFINITTY_SOCKET"
printf 'send-line vim /tmp/demo.txt\n' | nc -U "$S"
wait_for 'demo.txt'                              # vim is up
printf 'send i\n' | nc -U "$S"                   # insert mode
printf 'send hello from infinitty\n' | nc -U "$S"
printf 'send \033\n' | nc -U "$S"                # raw ESC byte back to normal mode
printf 'send-line :wq\n' | nc -U "$S"
wait_for '%%'                                    # shell prompt is back
```

Same pattern for any TUI: htop (`send q` to quit), REPLs (`send-line` expressions, poll for the result), fzf, lazygit.

## Automated test recipe

Launch, poll, assert on screen text and exit code, report PASS/FAIL:

```sh
#!/bin/zsh
S="$INFINITTY_SOCKET"
tt() { printf '%s\n' "$1" | nc -U "$S"; }
fail() { echo "FAIL: $1"; tt screen; exit 1 }

tt 'send-line ./myapp --version'
wait_for 'myapp 2\.' 10        || fail "version banner not shown"
wait_for '%%' 5                || fail "prompt did not return"
[[ $(tt exit-code) == 0 ]]     || fail "exit code $(tt exit-code)"
tt last-output | grep -q 2.1.0 || fail "wrong version in output"
echo PASS
```

Assert on `screen` for UI state, `last-output` for exact command output, `exit-code` for success — always after `wait_for` confirms the command finished (prompt visible again).

## OSC 133 shell integration

`last-output`, `last-command`, and `exit-code` need semantic prompt markers. Enable once:

```sh
echo 'source /path/to/infinitty/shell-integration/infinitty.zsh' >> ~/.zshrc
```

infinitty tracks the markers (prompt start, input start, output start, exit) by absolute line number, so "the last command's output" is an exact O(1) lookup — not a heuristic. Without integration those three commands return `error:`; `screen`/`history` always work.


## Background control (no focus stealing)

Socket commands (`send`, `send-line`, `screen`, `run`) write straight to the
pty and read the cell grid — they NEVER require infinitty to be focused or
frontmost. You can drive a pane while the user types in another app.

- Launch without stealing focus: `open -g -a Infinitty` or `INFINITTY_NO_ACTIVATE=1`.
- Agent-created panes (`new-tab` / `new-window` on the app socket) appear
  without taking keyboard focus. Only the explicit `focus <pane>` command
  brings a pane forward — use it only when the user asked to see it.
- `toggle-quick-terminal` shows or hides the persistent quick-terminal panel.
  It is intentionally user-visible; invoke it only when the user asks.

## Rendered markdown

With `markdown-render = auto` in the config, a completed command whose output
looks like markdown is auto-rendered through `glow` in place (guarded: skips
interactive/alt-screen apps, non-markdown output, and anything large). Off by
default; agents can rely on plain `cmd | glow` regardless.
