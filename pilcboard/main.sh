#!/usr/bin/env bash
# pilcboard (cb) - copy to clipboard: pipe, wrap a command, file, or text
# Usage: echo "hi" | cb          # pipe stdin
#        cb curl https://...      # wrap command, capture stdout
#        cb image.png             # copy file (MIME-aware)
#        cb "some text"           # copy literal text

_is_remote_session() {
    [[ -n "$SSH_TTY" || -n "$SSH_CONNECTION" || -n "$SSH_CLIENT" || -n "$MOSH_CONNECTION" ]]
}

# OSC 52 copies to the clipboard of the terminal emulator on the far end of
# the SSH/mosh link (i.e. the real machine), not this host's local clipboard.
_osc52_copy() {
    local data
    data=$(base64 -w0) || return 1
    local osc=$'\033]52;c;'"${data}"$'\a'
    if [[ -n "$TMUX" ]]; then
        printf '\033Ptmux;\033%s\033\\' "$osc" > /dev/tty
    else
        printf '%s' "$osc" > /dev/tty
    fi
}

_copy() {
    local mime="${1:-}"
    if _is_remote_session && [[ -w /dev/tty ]]; then
        if [[ -n "$mime" && "$mime" != text/* ]]; then
            echo "cb: OSC52 (remote clipboard) only supports text, not $mime" >&2
            return 1
        fi
        _osc52_copy
        return $?
    fi
    if [[ -n "$WAYLAND_DISPLAY" ]]; then
        if [[ -n "$mime" ]]; then
            wl-copy --type "$mime"
        else
            wl-copy
        fi
    elif [[ -n "$DISPLAY" ]]; then
        if command -v xclip &>/dev/null; then
            if [[ -n "$mime" ]]; then
                xclip -selection clipboard -t "$mime"
            else
                xclip -selection clipboard
            fi
        elif command -v xsel &>/dev/null; then
            xsel --clipboard --input
        else
            echo "cb: no X11 clipboard tool found (install xclip or xsel)" >&2
            return 1
        fi
    else
        return 0  # headless, silent no-op
    fi
}

_copy_file() {
    local file="$1"
    local mime
    if command -v file &>/dev/null; then
        mime=$(file --mime-type -b "$file")
    fi
    _copy "$mime" < "$file"
}

# Pipe mode
if ! [[ -t 0 ]]; then
    _copy
    exit $?
fi

[[ $# -eq 0 ]] && { echo "Usage: cb <text|file|command> [args...] or pipe | cb" >&2; exit 1; }

# Wrap mode: first arg is a known command
if command -v "$1" &>/dev/null; then
    "$@" | _copy
    exit $?
fi

# File mode: check cwd first, then as literal path
file=""
[[ -f "$1" ]] && file="$1"
[[ -z "$file" && -f "$PWD/$1" ]] && file="$PWD/$1"
if [[ -n "$file" ]]; then
    _copy_file "$file"
    exit $?
fi

# Literal text mode
printf '%s' "$*" | _copy
