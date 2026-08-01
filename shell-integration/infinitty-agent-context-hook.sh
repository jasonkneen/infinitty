#!/bin/sh
# Provider-neutral context hook for Claude Code, Codex, and compatible CLIs.
# The hook must drain stdin before doing any work: providers write the hook
# event JSON there and may close the pipe as soon as their command returns.
set -u

input=$(cat 2>/dev/null || true)
: "${input}"

if [ -z "${INFINITTY_SOCKET:-}" ] || [ ! -S "$INFINITTY_SOCKET" ]; then
    exit 0
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || exit 0
agent_bin=${INFINITTY_AGENT_BIN:-}
if [ -z "$agent_bin" ] || [ ! -x "$agent_bin" ]; then
    agent_bin="$script_dir/../../MacOS/infinitty-agent"
fi
if [ ! -x "$agent_bin" ]; then
    agent_bin="/Applications/Infinitty.app/Contents/MacOS/infinitty-agent"
fi
[ -x "$agent_bin" ] || exit 0

event=${INFINITTY_AGENT_HOOK_EVENT:-UserPromptSubmit}
exec "$agent_bin" context --format claude --event "$event"
