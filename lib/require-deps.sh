#!/usr/bin/env bash
# require-deps.sh - ensure commands exist, borrowing them from nix-shell when missing
# Usage: require_deps cmd[:nix-package] ... -- script [args...]
# Re-runs "script args" inside nix-shell when a command is missing; dies elsewhere.

NIX_GUARD_VAR="REQUIRE_DEPS_NIX_GUARD"
DEPS_DIM_STYLE=$'\e[2m'
DEPS_RESET_STYLE=$'\e[0m'

require_deps() {
    local specs=() missing=() packages=() spec
    while (($# > 0)) && [[ "$1" != "--" ]]; do
        specs+=("$1")
        shift
    done
    shift

    for spec in "${specs[@]}"; do
        command -v "${spec%%:*}" >/dev/null 2>&1 && continue
        missing+=("${spec%%:*}")
        packages+=("${spec##*:}")
    done
    ((${#missing[@]} == 0)) && return 0

    if [[ -n "${!NIX_GUARD_VAR:-}" ]] || ! command -v nix-shell >/dev/null 2>&1; then
        printf '%s: missing %s\n' "$(basename "$1")" "${missing[*]}" >&2
        exit 1
    fi

    if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
        printf '%sfetching %s via nix-shell%s\n' "$DEPS_DIM_STYLE" "${missing[*]}" "$DEPS_RESET_STYLE" >&2
    else
        printf 'fetching %s via nix-shell\n' "${missing[*]}" >&2
    fi
    exec env "$NIX_GUARD_VAR=1" nix-shell -p "${packages[@]}" --run "$(printf '%q ' "$@")"
}
