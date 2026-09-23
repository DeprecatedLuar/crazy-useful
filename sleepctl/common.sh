# common.sh - shared helpers. No state of its own, no side effects beyond
# notifications and diagnostics.

readonly NOTIFY_APP="sleepctl"

warn() {
    printf 'sleepctl: %s\n' "$1" >&2
}

die() {
    warn "$1"
    exit "${2:-1}"
}

notify() {
    local message="$1"
    local app_name="${2:-$NOTIFY_APP}"

    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send --app-name="$app_name" "$message" || warn 'notification failed'
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}
