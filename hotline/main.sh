#!/usr/bin/env bash

SESSION="hotline"
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
INPUT_SCRIPT="${ROFI_INPUT_SCRIPT:-$SCRIPT_DIR/input/input-text.sh}"
HOTLINE_DIR="${TMPDIR:-/tmp}/hotline-$USER"
HOTLINE_HISTORY="$HOTLINE_DIR/history"
NOTIFY_TITLE="☎ Hotline"
POLL_INTERVAL=0.1
HISTORY_TAIL=10
MUTE_PREFIX="mute:"
HOLD_PREFIX="hold:"

# --- Helpers ---

# Escape string for safe shell inclusion (prevents injection)
escape_for_shell() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//\$/\\\$}"
    str="${str//\`/\\\`}"
    echo "$str"
}

# Strip ANSI codes and control characters from output
strip_ansi() {
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' |
    sed 's/\x1b\][^\x07]*\x07//g' |
    sed 's/\x1b[>\()\[]//g' |
    tr -cd '\11\12\15\40-\176' |
    sed 's/.*\r\([^\r]*\)$/\1/' |
    sed '/^$/d'
}

# Format output for notification (truncate if needed)
format_notify_body() {
    local output="$1"
    local max_lines="${2:-15}"
    local head_lines="${3:-10}"

    [[ -z "$output" ]] && echo "Command completed" && return

    local lines=$(echo "$output" | wc -l)
    if [[ $lines -le $max_lines ]]; then
        echo "$output"
    else
        echo "$output" | head -"$head_lines"
        echo "..."
        echo "($((lines - head_lines)) more lines)"
    fi
}

# Send notification if notify-send available
notify() {
    local title="$1"
    local body="$2"
    command -v notify-send &>/dev/null && notify-send "$title" "$body"
}

# Read and clean output from temp file, then notify
notify_from_file() {
    local output_file="$1"
    local title="${2:-$NOTIFY_TITLE}"

    [[ ! -f "$output_file" ]] && return 1

    local output=$(cat "$output_file" 2>/dev/null)
    local clean=$(echo "$output" | strip_ansi)
    local body=$(format_notify_body "$clean")

    notify "$title" "$body"
    rm -f "$output_file"
}

# Generate temp file path for pane output
pane_output_file() {
    echo "$HOTLINE_DIR/output_${1//[^a-zA-Z0-9]/_}"
}

# --- Core Functions ---

auto_clean() {
    tmux has-session -t "$SESSION" 2>/dev/null || return

    while read -r pane_id pane_dead pane_title; do
        if [[ "$pane_dead" == "1" ]]; then
            # Notify unless muted or held (user was watching it)
            if [[ "$pane_title" != ${MUTE_PREFIX}* ]] && [[ "$pane_title" != ${HOLD_PREFIX}* ]]; then
                notify_from_file "$(pane_output_file "$pane_id")"
            fi
            tmux kill-pane -t "$pane_id" 2>/dev/null
        fi
    done < <(tmux list-panes -s -t "$SESSION" -F "#{pane_id} #{pane_dead} #{pane_title}" 2>/dev/null)
}

cmd_exec() {
    local command="$1"
    [[ -z "$command" ]] && exit 1

    # Check for prefixes
    local hold_mode=false
    local mute_mode=false

    if [[ "$command" == hold\ * ]]; then
        hold_mode=true
        command="${command#hold }"
    fi

    if [[ "$command" == mute\ * ]]; then
        mute_mode=true
        command="${command#mute }"
    fi

    if [[ "$command" == dial\ * ]]; then
        command="${command#dial }"
        local user_input=$("$INPUT_SCRIPT" normal "Input: ")
        [[ -z "$user_input" ]] && return
        command="echo \"$(escape_for_shell "$user_input")\" | $command"
    fi

    if [[ "$command" == sudo\ * ]]; then
        command="${command#sudo }"
        local password=$("$INPUT_SCRIPT" password "Password: ")
        [[ -z "$password" ]] && return

        if ! echo "$password" | sudo -S -v 2>/dev/null; then
            notify "$NOTIFY_TITLE" "Authentication failed"
            return
        fi
        command="echo \"$(escape_for_shell "$password")\" | sudo -S -p '' $command"
    fi

    mkdir -p "$HOTLINE_DIR"

    tmux has-session -t "$SESSION" 2>/dev/null || \
        tmux new-session -d -s "$SESSION"

    auto_clean

    # Create interactive pane (loads .bashrc automatically)
    if tmux list-panes -s -t "$SESSION" 2>/dev/null | grep -q .; then
        tmux split-window -t "$SESSION" 2>/dev/null && \
            tmux select-layout -t "$SESSION" tiled 2>/dev/null || \
            tmux new-window -t "$SESSION"
    fi

    # Get the target pane
    local target_pane=$(tmux list-panes -t "$SESSION" -F "#{pane_id}" | tail -1)

    # Set pane title based on mode (for auto_clean to know whether to notify)
    if $mute_mode; then
        tmux select-pane -t "$target_pane" -T "${MUTE_PREFIX}$command"
    elif $hold_mode; then
        tmux select-pane -t "$target_pane" -T "${HOLD_PREFIX}$command"
    else
        tmux select-pane -t "$target_pane" -T "$command"
    fi

    # Build final command with output capture for notifications
    local final_cmd
    local output_file=$(pane_output_file "$target_pane")

    if $hold_mode; then
        # Hold mode: wait for Enter, then exit
        final_cmd="$command; echo; read -p 'Press Enter to close...'; exit"
        tmux send-keys -t "$target_pane" "$final_cmd" Enter
    elif $mute_mode; then
        # Mute mode: just run and exit, no notification
        final_cmd="$command; exit"
        tmux send-keys -t "$target_pane" "$final_cmd" Enter
    else
        # Normal mode: capture output, wait for exit, notify, clean
        final_cmd="$command 2>&1 | tee '$output_file'; exit"
        tmux send-keys -t "$target_pane" "$final_cmd" Enter

        # Fire-and-forget from interactive terminal; block when called from GUI/scripts
        if [ -t 0 ] && [ -z "$HOTLINE_SPAWN" ]; then
            ( while tmux list-panes -t "$SESSION" -F "#{pane_id}" 2>/dev/null | grep -q "^${target_pane}$"; do
                sleep "$POLL_INTERVAL"
              done
              notify_from_file "$output_file" ) &
            disown
        else
            while tmux list-panes -t "$SESSION" -F "#{pane_id}" 2>/dev/null | grep -q "^${target_pane}$"; do
                sleep "$POLL_INTERVAL"
            done
            notify_from_file "$output_file"
        fi
    fi
}

cmd_show() {
    tmux has-session -t "$SESSION" 2>/dev/null || \
        tmux new-session -d -s "$SESSION"

    # If running in a terminal (SSH, regular terminal) AND not from GUI launcher, attach directly
    if [ -t 0 ] && [ -z "$TMUX" ] && [ -z "$HOTLINE_SPAWN" ]; then
        exec tmux attach -t "$SESSION"
    fi

    # Otherwise spawn new window (called from rofi/launcher)
    local term="${TERMINAL:-kitty}"
    command -v "$term" &>/dev/null || term="alacritty"
    command -v "$term" &>/dev/null || term="gnome-terminal"
    command -v "$term" &>/dev/null || term="xterm"

    "$term" -e tmux attach -t "$SESSION" &
}

cmd_list() {
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "No active session"
        return
    fi
    tmux list-panes -s -t "$SESSION" -F "#{pane_index}: [#{pane_current_command}] #{pane_dead}"
}

cmd_yellowpage() {
    if [[ ! -f "$HOTLINE_HISTORY" ]]; then
        echo "No history"
        notify "☎ Hotline" "No history"
        return
    fi
    local history=$(tail -"$HISTORY_TAIL" "$HOTLINE_HISTORY")
    echo "$history"
    notify "$NOTIFY_TITLE" "$history"
}

resolve_history() {
    local input="$1"

    # If doesn't start with !, return as-is
    [[ "$input" != !* ]] && echo "$input" && return

    # Handle !! (last command)
    if [[ "$input" == "!!" ]]; then
        [[ ! -f "$HOTLINE_HISTORY" ]] && echo "$input" && return
        local last_cmd=$(tail -1 "$HOTLINE_HISTORY" 2>/dev/null)
        [[ -z "$last_cmd" ]] && echo "$input" && return
        echo "$last_cmd"
        return
    fi

    # Handle !! with suffix (like !! | grep foo)
    if [[ "$input" == "!!"* ]]; then
        [[ ! -f "$HOTLINE_HISTORY" ]] && echo "$input" && return
        local last_cmd=$(tail -1 "$HOTLINE_HISTORY" 2>/dev/null)
        [[ -z "$last_cmd" ]] && echo "$input" && return
        echo "${input/!!/$last_cmd}"
        return
    fi

    # Handle !-n (n commands back)
    if [[ "$input" =~ ^!-([0-9]+)(.*) ]]; then
        local n="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"
        [[ ! -f "$HOTLINE_HISTORY" ]] && echo "$input" && return
        local cmd=$(tail -"$n" "$HOTLINE_HISTORY" 2>/dev/null | head -1)
        [[ -z "$cmd" ]] && echo "$input" && return
        echo "${cmd}${rest}"
        return
    fi

    # If we can't resolve it, return original
    echo "$input"
}

save_to_history() {
    local cmd="$1"
    # Don't save history expansions themselves or special keywords
    [[ "$cmd" == "!!"* ]] && return
    [[ "$cmd" == "pickup" ]] && return
    [[ "$cmd" == "list" ]] && return
    [[ "$cmd" == "yellowpage" || "$cmd" == "ylpg" ]] && return

    mkdir -p "$HOTLINE_DIR"
    echo "$cmd" >> "$HOTLINE_HISTORY"
}

cmd_input() {
    if ! command -v rofi &>/dev/null; then
        echo "rofi not found" >&2
        exit 1
    fi

    # Toggle: if rofi is running, kill it
    if pgrep -x rofi >/dev/null; then
        pkill -x rofi
        exit 0
    fi

    local input
    input=$("$INPUT_SCRIPT" normal "")

    [[ -z "$input" ]] && exit 0

    # Re-invoke hotline with input as arguments, mark as coming from GUI
    exec env HOTLINE_SPAWN=1 hotline $input
}

show_help() {
    cat <<EOF
Usage: hotline [command]

Commands:
    (none)            Open rofi prompt
    launcher          Open rofi prompt
    pickup            Attach to tmux session
    list              List running panes
    yellowpage, ylpg  Show last 10 commands
    help, -h, --help  Show this help

Prefixes (combine with any command):
    hold <cmd>    Keep pane open after command
    mute <cmd>    Silent execution (no notification)
    dial <cmd>    Prompt for input, pipe to command
    sudo <cmd>    Prompt for password

History:
    !!            Repeat last command
    !! | grep x   Last command piped to grep
    !-N           N commands back

Examples:
    hotline ls -la
    hotline hold htop
    hotline mute ./build.sh
    hotline dial grep
    hotline sudo apt update
EOF
}

cmd_deps() {
    declare -A deps=(
        [tmux]="required"
        [rofi]="GUI prompt (optional)"
        [notify-send]="desktop notifications (optional)"
    )
    ok=true
    for dep in "${!deps[@]}"; do
        if command -v "$dep" &>/dev/null; then
            printf "  [ok]      %-16s %s\n" "$dep" "${deps[$dep]}"
        else
            printf "  [missing] %-16s %s\n" "$dep" "${deps[$dep]}"
            [[ "${deps[$dep]}" == "required" ]] && ok=false
        fi
    done
    $ok || { echo ""; echo "missing required dependencies"; exit 1; }
}

# --- Entry Point ---

main() {
    case "$1" in
        ""|launcher)     cmd_input ;;
        -h|--help|help)  show_help ;;
        deps)            cmd_deps ;;
        pickup)          cmd_show ;;
        list)            cmd_list ;;
        yellowpage|ylpg) cmd_yellowpage ;;
        *)
            local resolved
            resolved=$(resolve_history "$*")
            save_to_history "$resolved"
            cmd_exec "$resolved"
            ;;
    esac
}

main "$@"
