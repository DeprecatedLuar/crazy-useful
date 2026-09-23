#!/usr/bin/env bash
# Reclaim provider: npm
# Verbs: detect | size | plan   (contract documented in ../sample/reclaim.sh)

# npm reports its own cache location, and documents the cache as disposable —
# every entry is content-addressed and re-fetched on demand. Sizing the directory
# npm itself names is therefore exactly what `npm cache clean` frees.
NPM_RECLAIM_COMMAND='npm cache clean --force'
NPM_CONSEQUENCE='packages are re-downloaded on next install'
NPM_NEEDS_SUDO=0

npm_cache_dir() {
    npm config get cache 2>/dev/null
}

detect() {
    local dir
    command -v npm >/dev/null 2>&1 || return 1
    dir=$(npm_cache_dir)
    [[ -n "$dir" && -d "$dir" ]]
}

size() {
    du -sb "$(npm_cache_dir)" 2>/dev/null | awk '{ printf "%d\n", $1 }'
}

plan() {
    printf '%s\t%s\t%s\n' \
        "$NPM_RECLAIM_COMMAND" "$NPM_CONSEQUENCE" "$NPM_NEEDS_SUDO"
}

case "${1:-}" in
    detect|size|plan) "$1" ;;
    *)
        printf 'npm reclaim provider: expected detect, size or plan\n' >&2
        exit 2
        ;;
esac
