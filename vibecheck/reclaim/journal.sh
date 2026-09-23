#!/usr/bin/env bash
# Reclaim provider: journal
# Verbs: detect | size | plan   (contract documented in ../sample/reclaim.sh)

# systemd names archived journal files with an '@' (system@<seq>-<seq>.journal);
# the currently-written ones are plain system.journal / user-N.journal. Vacuuming
# removes archived files only, so summing exactly those files is what the command
# below frees. `journalctl --disk-usage` is not usable here: it reports the total
# including the active journals, which vacuum never deletes.
JOURNAL_DIR=/var/log/journal
JOURNAL_ARCHIVED_GLOB='*@*.journal*'
JOURNAL_RECLAIM_COMMAND='journalctl --vacuum-time=1s'
JOURNAL_CONSEQUENCE='archived logs discarded · current boot kept'
JOURNAL_NEEDS_SUDO=1

detect() {
    command -v journalctl >/dev/null 2>&1 && [[ -d "$JOURNAL_DIR" ]]
}

size() {
    find "$JOURNAL_DIR" -type f -name "$JOURNAL_ARCHIVED_GLOB" -printf '%s\n' 2>/dev/null \
        | awk '{ total += $1 } END { printf "%d\n", total }'
}

plan() {
    printf '%s\t%s\t%s\n' \
        "$JOURNAL_RECLAIM_COMMAND" "$JOURNAL_CONSEQUENCE" "$JOURNAL_NEEDS_SUDO"
}

case "${1:-}" in
    detect|size|plan) "$1" ;;
    *)
        printf 'journal reclaim provider: expected detect, size or plan\n' >&2
        exit 2
        ;;
esac
