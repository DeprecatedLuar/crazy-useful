#!/usr/bin/env bash
# Reclaim provider: uv
# Verbs: detect | size | plan   (contract documented in ../sample/reclaim.sh)

# uv names its own cache directory and ships `uv cache clean` for exactly this.
UV_RECLAIM_COMMAND='uv cache clean'
UV_CONSEQUENCE='wheels are re-downloaded on next sync'
UV_NEEDS_SUDO=0

uv_cache_dir() {
    uv cache dir 2>/dev/null
}

detect() {
    local dir
    command -v uv >/dev/null 2>&1 || return 1
    dir=$(uv_cache_dir)
    [[ -n "$dir" && -d "$dir" ]]
}

size() {
    du -sb "$(uv_cache_dir)" 2>/dev/null | awk '{ printf "%d\n", $1 }'
}

plan() {
    printf '%s\t%s\t%s\n' \
        "$UV_RECLAIM_COMMAND" "$UV_CONSEQUENCE" "$UV_NEEDS_SUDO"
}

case "${1:-}" in
    detect|size|plan) "$1" ;;
    *)
        printf 'uv reclaim provider: expected detect, size or plan\n' >&2
        exit 2
        ;;
esac
