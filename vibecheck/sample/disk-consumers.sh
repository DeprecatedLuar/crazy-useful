#!/usr/bin/env bash
# disk-consumers.sh - biggest space consumers under a scope, always live
#
# Output: BYTES \t PATH, largest first.
# Usage: disk-consumers.sh [PATH]

SCAN_DEPTH=1
SCAN_LIMIT=12
# Directories outside $HOME that routinely dominate a root filesystem. Each is
# reported as a single total: they are not yours to reorganise, so a breakdown
# would be noise. Absent or other-filesystem entries drop out silently.
SYSTEM_ROOTS=(/nix /var /usr /opt /srv)
# Same XDG location the trash reclaim provider resolves. Nested
# two levels under $HOME, so the depth-1 scan below folds it into ~/.local
# instead of giving it its own row — call it out explicitly.
TRASH_DIR="${XDG_TRASH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/Trash}"

scope=""
for arg in "$@"; do
    case "$arg" in
        -*)
            printf 'disk-consumers: unknown option %s\n' "$arg" >&2
            exit 2
            ;;
        *) scope="$arg" ;;
    esac
done

scoped=true
if [[ -z "$scope" ]]; then
    scope="$HOME"
    scoped=false
fi

[[ -d "$scope" ]] || {
    printf 'disk-consumers: not a directory: %s\n' "$scope" >&2
    exit 1
}

scope="$(cd -- "$scope" && pwd)"

scan() {
    # -x keeps each walk inside one filesystem; -d1 lists the scope's children,
    # and the scope's own total, which is dropped below.
    du -xb --max-depth="$SCAN_DEPTH" "$scope" 2>/dev/null \
        | awk -F'\t' -v scope="$scope" '$2 != scope'

    $scoped && return 0

    [[ -d "$TRASH_DIR" ]] && du -xb --max-depth=0 "$TRASH_DIR" 2>/dev/null

    local root
    for root in "${SYSTEM_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        case "$root" in "$scope"/*|"$scope") continue ;; esac
        du -xb --max-depth=0 "$root" 2>/dev/null
    done
}

scan | sort -k1,1nr | head -n "$SCAN_LIMIT"
