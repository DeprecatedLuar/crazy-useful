#!/usr/bin/env bash
# Reclaim provider: pip
# Verbs: detect | size | plan   (contract documented in ../sample/reclaim.sh)
# shared: format/bytes.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../format/bytes.sh"

# pip reports its own cache size via `pip cache info`, which prints one
# "... size: 1.2 MB" line per cache section (index pages, locally built wheels).
# Summing those lines is pip's own accounting, and `pip cache purge` clears
# exactly those sections.
PIP_BINARIES=(pip3 pip)
PIP_SIZE_PATTERN='size: '
PIP_CONSEQUENCE='wheels are rebuilt or re-downloaded'
PIP_NEEDS_SUDO=0

pip_binary() {
    local binary
    for binary in "${PIP_BINARIES[@]}"; do
        command -v "$binary" >/dev/null 2>&1 && { printf '%s\n' "$binary"; return 0; }
    done
    return 1
}

detect() {
    local binary
    binary=$(pip_binary) || return 1
    "$binary" cache dir >/dev/null 2>&1
}

size() {
    local binary total=0 reported
    binary=$(pip_binary) || { printf '0\n'; return; }

    while read -r reported; do
        total=$((total + $(parse_bytes "$reported")))
    done < <("$binary" cache info 2>/dev/null | awk -v pattern="$PIP_SIZE_PATTERN" '
        index($0, pattern) { print $(NF - 1) $NF }')

    printf '%s\n' "$total"
}

plan() {
    local binary
    binary=$(pip_binary) || return 1
    printf '%s\t%s\t%s\n' \
        "$binary cache purge" "$PIP_CONSEQUENCE" "$PIP_NEEDS_SUDO"
}

case "${1:-}" in
    detect|size|plan) "$1" ;;
    *)
        printf 'pip reclaim provider: expected detect, size or plan\n' >&2
        exit 2
        ;;
esac
