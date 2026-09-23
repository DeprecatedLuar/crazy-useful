#!/usr/bin/env bash
# rec - unified recording: screen, desktop audio, mic

STATE="${TMPDIR:-/tmp}/rec.state"
OUT_DIR="${MEDIA:-$HOME/Media}/rec"
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/fix-color.sh"
TIMESTAMP=$(date +%y-%m-%d_%H-%M)
STOP_TIMEOUT=20
DAEMON=false
NOTIFY=false

_die()     { echo "$*" >&2; exit 1; }
_log()     { echo "$*"; }
_need()    { command -v "$1" &>/dev/null || _die "$1 not found"; }
_notify()  { command -v notify-send &>/dev/null && notify-send -a "rec" "$@" || true; }

_load_state() {
    [[ -f "$STATE" ]] || return 1
    # shellcheck disable=SC1090
    source "$STATE" 2>/dev/null || { rm -f "$STATE"; return 1; }
}

_save_state() {
    printf 'PID=%s\nFILE="%s"\nMODE="%s"\n' "$1" "$2" "$3" > "$STATE"
}

_alive() {
    kill -0 "$PID" 2>/dev/null
}

_unique_filename() {
    local base="$1"
    local ext="$2"
    local file="${base}.${ext}"

    if [[ ! -e "$file" ]]; then
        echo "$file"
        return
    fi

    local n=1
    while [[ -e "${base} (${n}).${ext}" ]]; do
        ((n++))
    done
    echo "${base} (${n}).${ext}"
}

_wait_exit() {
    local timeout=$STOP_TIMEOUT
    while _alive && (( timeout-- > 0 )); do sleep 0.3; done
}

_hold() {
    local pid=$1
    trap 'printf "\r\033[K"; cmd_stop; exit 0' INT

    local start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        local now=$(date +%s)
        local elapsed=$((now - start))
        printf "\r%02d:%02d" $((elapsed / 60)) $((elapsed % 60))
        sleep 1
    done
    echo

    trap - INT
}

_audio_fmt() {
    ffmpeg -hide_banner -devices 2>/dev/null | grep -q '\bpipewire\b' && echo pipewire || echo pulse
}

_get_monitor() {
    if command -v pactl &>/dev/null; then
        pactl list short sources 2>/dev/null | awk '/\.monitor/{print $2; exit}'
    else
        wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
            | awk -F'"' '/node\.name/{print $2".monitor"; exit}'
    fi
}

_get_mic() {
    if command -v pactl &>/dev/null; then
        pactl list short sources 2>/dev/null | awk '!/\.monitor/{print $2; exit}'
    else
        wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null \
            | awk -F'"' '/node\.name/{print $2; exit}'
    fi
}

cmd_status() {
    if _load_state && _alive; then
        _log "recording [$MODE] → $FILE"
    else
        _log "not recording"
    fi
}

cmd_stop() {
    _load_state || { _log "not recording"; return; }
    _alive || { _log "not recording"; rm -f "$STATE"; return; }
    kill -SIGINT "$PID" 2>/dev/null
    _wait_exit
    fix_color "$FILE"
    _log "saved $(basename "$FILE")"
    _notify "Recording saved" "$(basename "$FILE")"
    rm -f "$STATE"
}

cmd_delete() {
    _load_state || { _log "not recording"; return; }
    local file="$FILE" pid="$PID"
    if kill -0 "$pid" 2>/dev/null; then
        kill -SIGINT "$pid" 2>/dev/null
        _wait_exit
    fi
    rm -f "$file" "$STATE"
    _log "deleted $(basename "$file")"
    _notify "Recording deleted" "$(basename "$file")"
}

cmd_screen() {
    _load_state && _alive && _die "already recording [$MODE]"
    _need wf-recorder

    local audio=none
    for arg in "$@"; do
        case "$arg" in
            --mic) audio=mic ;;
            --notify) NOTIFY=true ;;
        esac
    done

    mkdir -p "$OUT_DIR/video"
    local name="screen"
    [[ "$audio" == mic ]] && name="screen-mic"
    local file=$(_unique_filename "$OUT_DIR/video/${TIMESTAMP}_${name}" "mp4")

    local -a args=(-f "$file")

    if [[ "$audio" == mic ]]; then
        local mic; mic=$(_get_mic)
        args+=(--audio "${mic:-default}")
    fi

    wf-recorder "${args[@]}" &>/dev/null &
    local pid=$!
    _save_state "$pid" "$file" "screen${audio:+:$audio}"
    _log "recording screen${audio:+ + $audio}"
    [[ "$NOTIFY" == true ]] && _notify "Recording started" "Screen${audio:+ + $audio}"
    [[ "$DAEMON" == true ]] || _hold "$pid"
}

cmd_desktop() {
    _load_state && _alive && _die "already recording [$MODE]"
    _need wf-recorder

    local audio=desktop
    for arg in "$@"; do
        case "$arg" in
            --mic)             audio=mic ;;
            --no-audio|--mute) audio=none ;;
            --notify)          NOTIFY=true ;;
        esac
    done

    mkdir -p "$OUT_DIR/video"
    local name="desktop"
    [[ "$audio" == mic ]] && name="desktop-mic"
    [[ "$audio" == none ]] && name="screen-mute"
    local file=$(_unique_filename "$OUT_DIR/video/${TIMESTAMP}_${name}" "mp4")

    local -a args=(-f "$file")

    if [[ "$audio" == mic ]]; then
        local mic; mic=$(_get_mic)
        args+=(--audio "${mic:-default}")
    elif [[ "$audio" == desktop ]]; then
        local monitor; monitor=$(_get_monitor)
        [[ -n "$monitor" ]] || _die "no audio monitor found (use --mute to skip audio)"
        args+=(--audio "$monitor")
    fi

    wf-recorder "${args[@]}" &>/dev/null &
    local pid=$!
    _save_state "$pid" "$file" "desktop:$audio"
    _log "recording desktop + $audio"
    [[ "$NOTIFY" == true ]] && _notify "Recording started" "Desktop + $audio"
    [[ "$DAEMON" == true ]] || _hold "$pid"
}

cmd_audio() {
    _load_state && _alive && _die "already recording [$MODE]"
    _need ffmpeg

    for arg in "$@"; do
        case "$arg" in
            --notify) NOTIFY=true ;;
        esac
    done

    local monitor; monitor=$(_get_monitor)
    [[ -n "$monitor" ]] || _die "no audio monitor found"

    mkdir -p "$OUT_DIR/audio"
    local file=$(_unique_filename "$OUT_DIR/audio/${TIMESTAMP}_desktop" "opus")

    ffmpeg -loglevel error -f "$(_audio_fmt)" -i "$monitor" -c:a libopus -b:a 64k "$file" &>/dev/null &
    local pid=$!
    _save_state "$pid" "$file" "audio"
    _log "recording desktop audio"
    [[ "$NOTIFY" == true ]] && _notify "Recording started" "Desktop audio"
    [[ "$DAEMON" == true ]] || _hold "$pid"
}

cmd_mic() {
    _load_state && _alive && _die "already recording [$MODE]"
    _need ffmpeg

    for arg in "$@"; do
        case "$arg" in
            --notify) NOTIFY=true ;;
        esac
    done

    mkdir -p "$OUT_DIR/audio"
    local file=$(_unique_filename "$OUT_DIR/audio/${TIMESTAMP}_mic" "opus")

    local mic; mic=$(_get_mic)
    ffmpeg -loglevel error -f "$(_audio_fmt)" -i "${mic:-default}" -c:a libopus -b:a 64k "$file" &>/dev/null &
    local pid=$!
    _save_state "$pid" "$file" "mic"
    _log "recording mic"
    [[ "$NOTIFY" == true ]] && _notify "Recording started" "Microphone"
    [[ "$DAEMON" == true ]] || _hold "$pid"
}

cmd_check() {
    local ok=true
    for dep in ffmpeg wf-recorder; do
        if command -v "$dep" &>/dev/null; then
            echo "  [ok] $dep"
        else
            echo "  [missing] $dep"
            ok=false
        fi
    done
    if command -v pactl &>/dev/null; then
        echo "  [ok] pactl (audio backend)"
    elif command -v wpctl &>/dev/null; then
        echo "  [ok] wpctl (audio backend)"
    else
        echo "  [missing] audio backend (need pactl or wpctl)"
        ok=false
    fi
    $ok || { echo ""; _die "some dependencies missing"; }
}

# Parse global flags
while [[ "$1" == -* ]]; do
    case "$1" in
        -d|--daemon) DAEMON=true; shift ;;
        -n|--notify) NOTIFY=true; shift ;;
        *) break ;;
    esac
done

case "$1" in
    deps)            cmd_check ;;
    screen)   shift; cmd_screen "$@" ;;
    desktop)  shift; cmd_desktop "$@" ;;
    audio)    shift; cmd_audio "$@" ;;
    mic)      shift; cmd_mic "$@" ;;
    stop)                      cmd_stop ;;
    delete|--rm|--remove)     cmd_delete ;;
    status)          cmd_status ;;
    *)
        echo "usage: rec [-d] [-n] <command> [options]"
        echo ""
        echo "  rec screen             record screen only (no audio)"
        echo "  rec screen --mic       record screen + microphone"
        echo "  rec desktop            record screen + desktop audio"
        echo "  rec desktop --mic      record screen + microphone"
        echo "  rec desktop --mute     record screen, no audio"
        echo "  rec audio              record desktop audio only"
        echo "  rec mic                record microphone only"
        echo "  rec stop               stop and save"
        echo "  rec delete|--rm        stop and discard"
        echo "  rec status             show recording state"
        echo ""
        echo "  -d, --daemon           run in background (default: hold terminal, Ctrl+C to stop)"
        echo "  -n, --notify           send notification when recording starts (stop always notifies)"
        ;;
esac
