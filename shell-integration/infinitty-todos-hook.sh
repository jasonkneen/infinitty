#!/bin/sh
# Claude Code PostToolUse hook (matcher: TodoWrite): mirrors the agent's todo
# list into the infinitty pane header checklist. Safe no-op outside infinitty —
# $INFINITTY_SOCKET only exists in infinitty panes.
#
# Register in ~/.claude/settings.json:
#   "hooks": { "PostToolUse": [ { "matcher": "TodoWrite", "hooks": [
#     { "type": "command",
#       "command": "/absolute/path/to/shell-integration/infinitty-todos-hook.sh" }
#   ] } ] }
[ -n "$INFINITTY_SOCKET" ] || exit 0
[ -S "$INFINITTY_SOCKET" ] || exit 0
command -v nc >/dev/null 2>&1 || exit 0

todos=$(/usr/bin/python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    todos = data.get("tool_input", {}).get("todos", [])
    if isinstance(todos, list):
        print(json.dumps(todos))
except Exception:
    pass
' 2>/dev/null)
[ -n "$todos" ] || exit 0

printf 'todos %s\n' "$todos" | nc -U "$INFINITTY_SOCKET" >/dev/null 2>&1 || true
exit 0
