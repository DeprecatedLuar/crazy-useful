# inhibit.sh - idle inhibitor (the keep-awake engine).
#
# A `systemd-inhibit ... sleep` child holds the idle lock; its PID and optional
# deadline live in a runtime-dir state file, which is the only state and never
# survives a reboot.

readonly RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
readonly PID_FILE="$RUNTIME_DIR/keep-awake.pid"
readonly INHIBITOR_REASON="User requested idle inhibition"
readonly INHIBITOR_COMM="systemd-inhibit"
readonly NOTIFICATION_APP="keep-awake"
readonly NOTIFICATION_TITLE="Idle inhibition"
readonly ENABLED_MESSAGE="Enabled"
readonly DISABLED_MESSAGE="Disabled"
readonly STOP_WAIT_SECONDS=1
readonly STOP_POLL_INTERVAL=0.05
readonly INHIBIT_USAGE="Usage: sleepctl keep-awake [on] [--for DURATION|--until TIME]
       sleepctl keep-awake toggle [--for DURATION|--until TIME]
       sleepctl keep-awake status|off|stop|kill"

INHIBITOR_PID=
FOREGROUND_CLEANED=0

is_running() {
    local pid

    [[ -r "$PID_FILE" ]] || return 1
    read -r pid < "$PID_FILE"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == "$INHIBITOR_COMM" ]]
}

remove_state_file() {
    rm -f "$PID_FILE" || {
        warn "failed to remove state file: $PID_FILE"
        return 1
    }
}

clear_stale_state() {
    if ! is_running && [[ -e "$PID_FILE" ]]; then
        remove_state_file
    fi
}

wait_for_exit() {
    local deadline=$((SECONDS + STOP_WAIT_SECONDS))
    while is_running && ((SECONDS < deadline)); do
        sleep "$STOP_POLL_INTERVAL"
    done
}

notify_state() {
    notify "$1" "$NOTIFICATION_APP"
}

format_duration() {
    local total_minutes=$(($1 / 60))
    local hours=$((total_minutes / 60))
    local minutes=$((total_minutes % 60))

    if ((hours > 0)); then
        printf '%dh %dm' "$hours" "$minutes"
    else
        printf '%dm' "$minutes"
    fi
}

# "30m" / "2h" -> seconds
parse_duration() {
    local value unit

    if [[ "$1" =~ ^([1-9][0-9]*)(m|h)$ ]]; then
        value=${BASH_REMATCH[1]}
        unit=${BASH_REMATCH[2]}
    else
        warn 'duration must be a positive number followed by m or h'
        return 1
    fi

    if [[ "$unit" == m ]]; then
        printf '%s\n' "$((value * 60))"
    else
        printf '%s\n' "$((value * 3600))"
    fi
}

# "HH:MM" / "HH:MMam" / "HH:MMpm" -> epoch of the next occurrence
parse_until() {
    local time="$1"
    local hour minute suffix target now

    if [[ "$time" =~ ^([0-9]{1,2}):([0-9]{2})(am|pm)?$ ]]; then
        hour=${BASH_REMATCH[1]}
        minute=${BASH_REMATCH[2]}
        suffix=${BASH_REMATCH[3]}
    else
        warn 'time must use HH:MM, HH:MMam, or HH:MMpm'
        return 1
    fi

    if ((10#$minute > 59)); then
        warn 'minutes must be between 00 and 59'
        return 1
    fi
    if [[ -n "$suffix" ]] && ((10#$hour < 1 || 10#$hour > 12)); then
        warn '12-hour time must use an hour between 1 and 12'
        return 1
    fi
    if [[ -z "$suffix" ]] && ((10#$hour > 23)); then
        warn '24-hour time must use an hour between 00 and 23'
        return 1
    fi

    target=$(date -d "today $time" +%s 2>/dev/null) || {
        warn "could not parse time: $time"
        return 1
    }
    now=$(date +%s)
    if ((target <= now)); then
        target=$(date -d "tomorrow $time" +%s 2>/dev/null) || {
            warn "could not calculate next occurrence: $time"
            return 1
        }
    fi
    printf '%s\n' "$target"
}

prepare_start() {
    if is_running; then
        warn 'already enabled (use "sleepctl keep-awake stop" to disable it)'
        return 1
    fi
    clear_stale_state || return 1
    command -v systemd-inhibit >/dev/null 2>&1 || {
        warn 'systemd-inhibit not found'
        return 1
    }
}

# args: deadline (epoch, empty = indefinite), label
start_inhibitor() {
    local deadline="$1"
    local label="$2"
    local hold=infinity

    if [[ -n "$deadline" ]]; then
        hold=$((deadline - $(date +%s)))
        ((hold > 0)) || {
            warn 'deadline has already passed'
            return 1
        }
    fi

    systemd-inhibit --what=idle --why="$INHIBITOR_REASON" --mode=block sleep "$hold" &
    INHIBITOR_PID=$!
    printf '%s\n%s\n' "$INHIBITOR_PID" "$deadline" > "$PID_FILE" || {
        kill "$INHIBITOR_PID"
        warn "failed to write state file: $PID_FILE"
        return 1
    }
    if ! is_running; then
        remove_state_file
        warn 'inhibitor failed to start'
        return 1
    fi
    notify_state "$ENABLED_MESSAGE${label:+ $label}"
}

cleanup_foreground() {
    ((FOREGROUND_CLEANED)) && return 0
    FOREGROUND_CLEANED=1
    kill "$INHIBITOR_PID" 2>/dev/null || true
    remove_state_file
    notify_state "$DISABLED_MESSAGE"
}

inhibit_status() {
    local -a state
    local deadline remaining

    clear_stale_state || return 1
    if ! is_running; then
        printf 'off\n'
        return 0
    fi

    mapfile -t state < "$PID_FILE"
    deadline=${state[1]:-}
    if [[ "$deadline" =~ ^[0-9]+$ && "$deadline" -gt 0 ]]; then
        remaining=$((deadline - $(date +%s)))
        if ((remaining <= 0)); then
            printf 'off\n'
        else
            printf 'on — %s remaining\n' "$(format_duration "$remaining")"
        fi
    else
        printf 'on — indefinite\n'
    fi
}

start_background() {
    prepare_start || return 1
    start_inhibitor "$1" "$2" || return 1
    printf 'keep-awake: enabled%s\n' "${2:+ $2}"
}

run_foreground() {
    prepare_start || return 1
    start_inhibitor "$1" "$2" || return 1
    printf 'keep-awake: enabled%s (press Ctrl+C to disable)\n' "${2:+ $2}"
    trap cleanup_foreground EXIT INT TERM HUP
    wait "$INHIBITOR_PID"
}

# arg: signal (default TERM, escalating to KILL if the process lingers)
stop_inhibitor() {
    local signal="${1:-TERM}"
    local pid

    if ! is_running; then
        clear_stale_state || return 1
        warn 'not running (use "sleepctl keep-awake on" to enable it)'
        return 1
    fi

    read -r pid < "$PID_FILE"
    kill "-$signal" "$pid"
    wait_for_exit
    if is_running; then
        kill -KILL "$pid"
        wait_for_exit
    fi
    remove_state_file || return 1
    notify_state "$DISABLED_MESSAGE"
}

toggle_inhibitor() {
    if is_running; then
        stop_inhibitor
    else
        start_background "$@"
    fi
}

# Entry point: parses keep-awake arguments and runs the chosen action.
inhibit_main() {
    local action=foreground
    local deadline=
    local label=

    while (($# > 0)); do
        case "$1" in
            on) action=background ;;
            status|off|stop|kill|toggle) action="$1" ;;
            --for)
                (($# >= 2)) || { warn '--for needs a duration'; return 2; }
                [[ -z "$deadline" ]] || { warn 'use only one of --for or --until'; return 2; }
                local seconds
                seconds=$(parse_duration "$2") || return 2
                deadline=$(($(date +%s) + seconds))
                label="for $(format_duration "$seconds")"
                shift
                ;;
            --until)
                (($# >= 2)) || { warn '--until needs a time'; return 2; }
                [[ -z "$deadline" ]] || { warn 'use only one of --for or --until'; return 2; }
                deadline=$(parse_until "$2") || return 2
                label="until $2"
                shift
                ;;
            --help|-h)
                printf '%s\n' "$INHIBIT_USAGE"
                return 0
                ;;
            *)
                warn "unknown argument: $1"
                return 2
                ;;
        esac
        shift
    done

    case "$action" in
        foreground) run_foreground "$deadline" "$label" ;;
        background) start_background "$deadline" "$label" ;;
        status) inhibit_status ;;
        off|stop) stop_inhibitor ;;
        kill) stop_inhibitor KILL ;;
        toggle) toggle_inhibitor "$deadline" "$label" ;;
    esac
}

