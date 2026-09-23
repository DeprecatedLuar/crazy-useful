#!/usr/bin/env bash
# Reclaim provider: nix
# Verbs: detect | size | plan   (contract documented in ../sample/reclaim.sh)

# `nix store gc` deletes store paths no profile generation references any more.
# It deliberately does NOT run `nix-collect-garbage -d`, which would additionally
# delete old generations: that costs you every rollback point, and its total is
# not knowable in advance. The number reported here is exactly what the command
# below frees, so the two always agree.
#
# `nix path-info --size` reports each path's own size. The -S/--closure-size
# variant is wrong here: it sums each path's dependencies too, counting shared
# store paths once per dependent and overshooting the whole store.
NIX_DEAD_PATH_BATCH=200
NIX_RECLAIM_COMMAND='nix store gc'
NIX_CONSEQUENCE='unreferenced store paths · rollback generations kept'
NIX_NEEDS_SUDO=0

detect() {
    command -v nix >/dev/null 2>&1 && [[ -d /nix/store ]]
}

size() {
    nix-store --gc --print-dead 2>/dev/null \
        | xargs -r -n "$NIX_DEAD_PATH_BATCH" nix path-info --size 2>/dev/null \
        | awk '{ total += $2 } END { printf "%d\n", total }'
}

plan() {
    printf '%s\t%s\t%s\n' \
        "$NIX_RECLAIM_COMMAND" "$NIX_CONSEQUENCE" "$NIX_NEEDS_SUDO"
}

case "${1:-}" in
    detect|size|plan) "$1" ;;
    *)
        printf 'nix reclaim provider: expected detect, size or plan\n' >&2
        exit 2
        ;;
esac
