#!/usr/bin/env bash
# reclaim.sh - collect reclaimable space from every provider present on this machine
#
# Provider contract. Each executable in ../reclaim/ is a black box answering
# three verbs, and is the sole authority on its own tool:
#
#   detect   exit 0 if the owning tool exists here, non-zero otherwise
#   size     print reclaimable BYTES, as computed by the owning tool itself
#   plan     print  COMMAND \t CONSEQUENCE \t NEEDS_SUDO
#
# A provider may only exist when the owning tool can account for its own
# reclaimable bytes and ships its own command to free them. That rule is what
# keeps this machine-independent: nothing here is a curated list of paths some
# human guessed were disposable, so there is no list to rot. A location we'd
# have to guess about (~/.cache) has no provider — it shows up as a sized row
# in the consumers list and never as an action.
#
# Adding support for a new tool is one new file in ../reclaim/ and no edit here.
#
# Output: ID \t BYTES \t COMMAND \t CONSEQUENCE \t NEEDS_SUDO, largest first.
# Providers reporting zero bytes are omitted.
#
# Usage: reclaim.sh [ID ...] — always probes fresh, no caching.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_DIR="$SCRIPT_DIR/../reclaim"
PROVIDER_SUFFIX=.sh
NO_BYTES=0

wanted=()
for arg in "$@"; do
    case "$arg" in
        -*)
            printf 'reclaim: unknown option %s\n' "$arg" >&2
            exit 2
            ;;
        *) wanted+=("$arg") ;;
    esac
done

provider_wanted() {
    local id="$1" wanted

    [[ $# -eq 1 ]] && return 0
    shift
    for wanted in "$@"; do
        [[ "$id" == "$wanted" ]] && return 0
    done
    return 1
}

collect_provider() {
    local provider="$1" id bytes plan
    id="$(basename "$provider" "$PROVIDER_SUFFIX")"

    "$provider" detect >/dev/null 2>&1 || return 0

    bytes="$("$provider" size 2>/dev/null)"
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
    ((bytes > NO_BYTES)) || return 0

    plan="$("$provider" plan 2>/dev/null)" || return 0
    [[ -n "$plan" ]] || return 0

    printf '%s\t%s\t%s\n' "$id" "$bytes" "$plan"
}

collect_all() {
    local provider id
    for provider in "$PROVIDER_DIR"/*"$PROVIDER_SUFFIX"; do
        [[ -x "$provider" ]] || continue
        id="$(basename "$provider" "$PROVIDER_SUFFIX")"
        provider_wanted "$id" "$@" || continue
        collect_provider "$provider"
    done
}

collect_all "${wanted[@]}" | sort -t$'\t' -k2,2nr
