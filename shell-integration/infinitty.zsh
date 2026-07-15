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
