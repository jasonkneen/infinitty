#!/bin/sh
set -u
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || exit 0
INFINITTY_AGENT_HOOK_EVENT=UserPromptSubmit \
    exec "$script_dir/infinitty-agent-context-hook.sh" "$@"
