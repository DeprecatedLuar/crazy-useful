# power.sh - suspend and hibernate via systemd.

readonly SUS_MSG="ඞ"
readonly SUS_APP="sus"
# Give the notification time to render before the machine goes down.
readonly SUSPEND_DELAY=1
readonly POWER_STATE_FILE="/sys/power/state"
# zram is RAM-backed: it cannot hold a hibernation image.
readonly RAM_SWAP_PATTERN='^/dev/zram'

suspend_now() {
    require_cmd systemctl
    systemctl suspend
}

# Suspend with a notification and a short delay first.
suspend_with_notice() {
    notify "$SUS_MSG" "$SUS_APP"
    sleep "$SUSPEND_DELAY"
    suspend_now
}

# Kernel supports hibernation AND at least one non-zram swap device exists.
hibernate_available() {
    grep -qw disk "$POWER_STATE_FILE" 2>/dev/null || return 1
    swapon --show=NAME --noheadings 2>/dev/null | grep -qv "$RAM_SWAP_PATTERN"
}

hibernate_now() {
    hibernate_available ||
        die 'hibernate unavailable - needs kernel disk state and disk-backed swap (zram cannot hold a hibernation image)'
    systemctl hibernate
}
