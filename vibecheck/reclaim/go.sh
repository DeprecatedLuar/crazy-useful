#!/usr/bin/env bash
# Reclaim provider: go
# Verbs: detect | size | plan   (contract documented in ../sample/reclaim.sh)

# `go env` names both caches and `go clean` ships flags for each, so the measured
# directories and the reclaim command line up one-for-one. GOMODCACHE is included
# because module downloads are verifiably re-fetchable via the checksum database.
GO_CACHE_VARS=(GOCACHE GOMODCACHE)
GO_RECLAIM_COMMAND='go clean -cache -modcache'
GO_CONSEQUENCE='next build re-downloads and recompiles'
GO_NEEDS_SUDO=0

go_cache_dirs() {
    go env "${GO_CACHE_VARS[@]}" 2>/dev/null
}

detect() {
    local dir
    command -v go >/dev/null 2>&1 || return 1
    while read -r dir; do
        [[ -n "$dir" && -d "$dir" ]] && return 0
    done < <(go_cache_dirs)
    return 1
}

size() {
    local dir dirs=()
    while read -r dir; do
        [[ -n "$dir" && -d "$dir" ]] && dirs+=("$dir")
    done < <(go_cache_dirs)

    [[ ${#dirs[@]} -gt 0 ]] || { printf '0\n'; return; }
    du -sb "${dirs[@]}" 2>/dev/null | awk '{ total += $1 } END { printf "%d\n", total }'
}

plan() {
    printf '%s\t%s\t%s\n' \
        "$GO_RECLAIM_COMMAND" "$GO_CONSEQUENCE" "$GO_NEEDS_SUDO"
}

case "${1:-}" in
    detect|size|plan) "$1" ;;
    *)
        printf 'go reclaim provider: expected detect, size or plan\n' >&2
        exit 2
        ;;
esac
