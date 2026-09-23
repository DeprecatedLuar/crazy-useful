#!/usr/bin/env bash
# Reclaim provider: trash
# Verbs: detect | size | plan   (contract documented in ../sample/reclaim.sh)

# Trash is not a guess like ~/.cache: its whole purpose is "already marked for
# deletion", and gio ships the exact command that empties it.
TRASH_DIR="${XDG_TRASH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/Trash}"
TRASH_RECLAIM_COMMAND='gio trash --empty'
TRASH_CONSEQUENCE='trashed files are permanently deleted'
TRASH_NEEDS_SUDO=0

detect() {
    command -v gio >/dev/null 2>&1 && [[ -d "$TRASH_DIR/files" ]]
}

size() {
    du -sb "$TRASH_DIR/files" 2>/dev/null | awk '{ printf "%d\n", $1 }'
}

plan() {
    printf '%s\t%s\t%s\n' \
        "$TRASH_RECLAIM_COMMAND" "$TRASH_CONSEQUENCE" "$TRASH_NEEDS_SUDO"
}

case "${1:-}" in
    detect|size|plan) "$1" ;;
    *)
        printf 'trash reclaim provider: expected detect, size or plan\n' >&2
        exit 2
        ;;
esac
