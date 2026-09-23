#!/usr/bin/env bash
# sleepctl - screen blanking, suspend, lock and idle inhibition behind one entrypoint.
#
# Orchestrator only: routes a verb to the module that owns it.

set -uo pipefail

SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly SELF_DIR
readonly USAGE="Usage: sleepctl <command> [args]

Commands:
  screen-off           turn the screen off; wakes on input
  suspend              systemctl suspend
  lock                 lock the session (loginctl lock-session)
  hibernate            systemctl hibernate (refuses without disk-backed swap)
  keep-awake           idle inhibitor: [on|off|toggle|status|kill] [--for 30m|--until 23:30]
  status               show display, keep-awake and hibernate state
  help                 show this help"

# shellcheck source=common.sh
source "$SELF_DIR/common.sh"
# shellcheck source=blank.sh
source "$SELF_DIR/blank.sh"
# shellcheck source=power.sh
source "$SELF_DIR/power.sh"
# shellcheck source=lock.sh
source "$SELF_DIR/lock.sh"
# shellcheck source=inhibit.sh
source "$SELF_DIR/inhibit.sh"

show_status() {
    printf 'display: %s\n' "$(display_state)"
    printf 'keep-awake: %s\n' "$(inhibit_status)"
    if hibernate_available; then
        printf 'hibernate: available\n'
    else
        printf 'hibernate: unavailable\n'
    fi
}

dispatch() {
    local verb="${1:-}"
    (($# > 0)) && shift

    case "$verb" in
        screen-off) blank_display ;;
        suspend) suspend_now ;;
        sus) suspend_with_notice ;;
        lock) lock_session ;;
        hibernate) hibernate_now ;;
        keep-awake) inhibit_main "$@" ;;
        status) show_status ;;
        help|--help|-h) printf '%s\n' "$USAGE" ;;
        "") printf '%s\n' "$USAGE" >&2; return 2 ;;
        *) warn "unknown command: $verb"; printf '%s\n' "$USAGE" >&2; return 2 ;;
    esac
}

dispatch "$@"
