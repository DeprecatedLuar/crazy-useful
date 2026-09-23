# blank.sh - turn the display off and wake it on the first input.
#
# Wayland: wlopm switches outputs via zwlr-output-power-management-v1 and
# swayidle (ext-idle-notify-v1) fires `resume` on any mouse or key input, so
# waking never depends on compositor settings. The watcher blanks after
# BLANK_IDLE_SECONDS of inactivity (which doubles as the notification delay),
# then turns the outputs back on and exits on the first input.
# X11: `xset dpms force off` already wakes on any input by itself.

readonly BLANK_MSG="sweet dreams"
readonly BLANK_IDLE_SECONDS=1
readonly WLOPM_ALL_OUTPUTS='*'
readonly WATCHER_START_WAIT=0.3

# Prints the backend name, or "none" (and fails) when there is no display session.
blank_backend() {
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        printf 'wlopm+swayidle\n'
    elif [[ -n "${DISPLAY:-}" ]]; then
        printf 'xset\n'
    else
        printf 'none\n'
        return 1
    fi
}

blank_wayland() {
    local watcher_pid
    # Checked before anything goes dark: a missing tool must never leave a dead screen.
    require_cmd wlopm
    require_cmd swayidle

    notify "$BLANK_MSG"
    # `kill $PPID` ends the swayidle that ran the resume command.
    setsid swayidle -w \
        timeout "$BLANK_IDLE_SECONDS" "wlopm --off '$WLOPM_ALL_OUTPUTS'" \
        resume "wlopm --on '$WLOPM_ALL_OUTPUTS'; kill \$PPID" \
        >/dev/null 2>&1 &
    watcher_pid=$!

    sleep "$WATCHER_START_WAIT"
    kill -0 "$watcher_pid" 2>/dev/null || die 'swayidle failed to start; screen left on'
}

blank_x11() {
    require_cmd xset
    notify "$BLANK_MSG"
    sleep "$BLANK_IDLE_SECONDS"
    xset dpms force off
}

blank_display() {
    local backend
    backend=$(blank_backend) ||
        die 'no display session (neither WAYLAND_DISPLAY nor DISPLAY is set)'

    case "$backend" in
        wlopm+swayidle) blank_wayland ;;
        xset) blank_x11 ;;
    esac
}

# Prints "on" or "off". Off only when every output is off.
display_state() {
    local backend
    backend=$(blank_backend) ||
        die 'no display session (neither WAYLAND_DISPLAY nor DISPLAY is set)'

    case "$backend" in
        wlopm+swayidle)
            require_cmd wlopm
            if wlopm | grep -q ' on$'; then printf 'on\n'; else printf 'off\n'; fi
            ;;
        xset)
            require_cmd xset
            xset q | grep -q 'Monitor is Off' && printf 'off\n' || printf 'on\n'
            ;;
    esac
}
