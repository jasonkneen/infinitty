#!/bin/sh
# Explicit launcher for any CLI. It preserves the CLI's TTY and PID while
# registering the process as the terminal's Channel participant.
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || exit 70
agent_bin=${INFINITTY_AGENT_BIN:-}
if [ -z "$agent_bin" ] || [ ! -x "$agent_bin" ]; then
    agent_bin="$script_dir/../../MacOS/infinitty-agent"
fi
if [ ! -x "$agent_bin" ]; then
    agent_bin="/Applications/Infinitty.app/Contents/MacOS/infinitty-agent"
fi
[ -x "$agent_bin" ] || {
    echo "infinitty-agent-run: infinitty-agent binary not found" >&2
    exit 70
}

exec "$agent_bin" run -- "$@"
