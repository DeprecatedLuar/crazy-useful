#!/usr/bin/env bash
# Reclaim provider: docker
# Verbs: detect | size | plan   (contract documented in ../sample/reclaim.sh)
# shared: format/bytes.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../format/bytes.sh"

DOCKER_UNIT_BASE=$BYTE_SI_STEP
DOCKER_PROBE_TIMEOUT=3
# `docker system prune -a` reclaims images, stopped containers, networks and
# build cache. It does NOT touch local volumes (that needs --volumes), and
# volumes can hold real data, so they are excluded from the size as well.
DOCKER_PRUNED_TYPES='^(Images|Containers|Build Cache)$'
DOCKER_RECLAIM_COMMAND='docker system prune -a -f'
DOCKER_CONSEQUENCE='images are re-pullable · volumes untouched'
DOCKER_NEEDS_SUDO=0

detect() {
    command -v docker >/dev/null 2>&1 || return 1
    timeout "$DOCKER_PROBE_TIMEOUT" docker info >/dev/null 2>&1
}

size() {
    local total=0 type reclaimable

    while IFS='|' read -r type reclaimable; do
        [[ "$type" =~ $DOCKER_PRUNED_TYPES ]] || continue
        # Reclaimable reads like "1.944GB (84%)" — keep the size, drop the share.
        reclaimable="${reclaimable%% *}"
        total=$((total + $(parse_bytes "$reclaimable" "$DOCKER_UNIT_BASE")))
    done < <(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null)

    printf '%s\n' "$total"
}

plan() {
    printf '%s\t%s\t%s\n' \
        "$DOCKER_RECLAIM_COMMAND" "$DOCKER_CONSEQUENCE" "$DOCKER_NEEDS_SUDO"
}

case "${1:-}" in
    detect|size|plan) "$1" ;;
    *)
        printf 'docker reclaim provider: expected detect, size or plan\n' >&2
        exit 2
        ;;
esac
