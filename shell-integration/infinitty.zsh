# infinitty shell integration — OSC 133 semantic prompts.
#
# Marks prompt/command/output boundaries and exit codes so infinitty (and any
# agent on $INFINITTY_SOCKET) can answer "what did the last command output?"
# precisely instead of scraping the screen.
#
# Install: source this from ~/.zshrc, e.g.
#   [[ -n $INFINITTY_SOCKET ]] && source /path/to/infinitty.zsh

export INFINITTY_SOCKET=${INFINITTY_SOCKET:-$TITERM_SOCKET}
[[ -n $INFINITTY_SOCKET ]] || return 0

_infinitty_precmd() {
    # D = previous command finished (with exit code), A = new prompt starts.
    print -Pn "\e]133;D;%?\a"
    print -n "\e]133;A\a"
}

_infinitty_preexec() {
    # C = command output starts now.
    print -n "\e]133;C\a"
}

typeset -ag precmd_functions preexec_functions
if (( ! ${precmd_functions[(I)_infinitty_precmd]} )); then
    precmd_functions+=(_infinitty_precmd)
fi
if (( ! ${preexec_functions[(I)_infinitty_preexec]} )); then
    preexec_functions+=(_infinitty_preexec)
fi

# B = prompt ends / input begins (appended invisibly to the prompt).
if [[ $PROMPT != *'133;B'* ]]; then
    PROMPT="${PROMPT}%{$(print -n "\e]133;B\a")%}"
fi

# Optional provider-neutral agent wrapping. The shell integration is only
# sourced inside an Infinitty pane, so this gives recognized CLIs a stable
# registration/identity path without parsing arbitrary PTY traffic. Set
# INFINITTY_AGENT_AUTO_WRAP=0 to keep shell integration marker-only.
if [[ ${INFINITTY_AGENT_AUTO_WRAP:-1} != 0 && -z ${INFINITTY_AGENT_WRAPPED:-} ]]; then
    _infinitty_shell_file="${(%):-%N}"
    _infinitty_agent_bin="${INFINITTY_AGENT_BIN:-}"
    if [[ -z $_infinitty_agent_bin || ! -x $_infinitty_agent_bin ]]; then
        _infinitty_agent_bin="${_infinitty_shell_file:A:h:h:h}/MacOS/infinitty-agent"
    fi
    if [[ ! -x $_infinitty_agent_bin ]]; then
        _infinitty_agent_bin="/Applications/Infinitty.app/Contents/MacOS/infinitty-agent"
    fi
    if [[ -x $_infinitty_agent_bin ]]; then
        _infinitty_agent_invoke() {
            local provider="$1"
            shift
            "$_infinitty_agent_bin" run --provider "$provider" -- "$provider" "$@"
        }
        for _infinitty_provider in claude codex opencode gemini amp grok aider qwen \
            copilot cursor droid kimi goose; do
            if command -v "$_infinitty_provider" >/dev/null 2>&1; then
                eval "${_infinitty_provider}() { _infinitty_agent_invoke ${_infinitty_provider} \"\$@\"; }"
            fi
        done
        unset _infinitty_provider
    fi
    # Keep the resolved helper path: `_infinitty_agent_invoke` reads it when a
    # wrapped command is eventually entered, which may be long after this file
    # was sourced.
    unset _infinitty_shell_file
fi
