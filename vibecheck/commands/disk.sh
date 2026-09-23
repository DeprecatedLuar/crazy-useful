#!/usr/bin/env bash
# disk.sh - disk usage: filesystem header, biggest consumers, reclaimable total
# Usage: vch disk [PATH]

PROGRAM_NAME="vch"
USAGE="Usage: $PROGRAM_NAME disk [PATH]"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/.."
SYSTEM_METRICS="$LIB_DIR/get-system-metrics.sh"
CONSUMERS_SAMPLER="$LIB_DIR/sample/disk-consumers.sh"
RECLAIM_SAMPLER="$LIB_DIR/sample/reclaim.sh"
COLUMN_FORMATTER="$LIB_DIR/format/columns.sh"
SPINNER="$LIB_DIR/../lib/spinner.sh"

CONSUMER_COLUMN_COUNT=2
CONSUMER_PATH_COLUMN=1
CONSUMER_SIZE_COLUMN=2
SCAN_LABEL="Scanning"
DIM_ON=$'\033[2m'
DIM_OFF=$'\033[0m'

source "$LIB_DIR/format/bytes.sh"

target=""
for arg in "$@"; do
    case "$arg" in
        help|-h|--help)
            printf '%s\n' "$USAGE"
            exit 0
            ;;
        -*)
            printf "%s disk: unknown option '%s'\n" "$PROGRAM_NAME" "$arg" >&2
            printf '%s\n' "$USAGE" >&2
            exit 2
            ;;
        *) target="$arg" ;;
    esac
done

scope_args=()
if [[ -n "$target" ]]; then
    resolved="$(cd -- "$target" 2>/dev/null && pwd)"
    [[ -n "$resolved" ]] || {
        printf "%s disk: could not resolve '%s'\n" "$PROGRAM_NAME" "$target" >&2
        exit 1
    }
    scope_args=("$resolved")
fi

print_dim() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        printf '%s%s%s\n' "$DIM_ON" "$1" "$DIM_OFF"
    else
        printf '%s\n' "$1"
    fi
}

# The filesystem-wide header only makes sense for the whole-home view — it comes
# from the shared metric path there, so `vch disk` and the no-argument `vch`
# summary can never disagree. A scoped call gets the resolved path instead: the
# df numbers describe the mount, not the folder the user asked about.
if [[ ${#scope_args[@]} -eq 0 ]]; then
    "$SYSTEM_METRICS" disk || exit 1
else
    scope_bytes=$(du -xsb "${scope_args[0]}" 2>/dev/null | awk '{ print $1 }')
    printf '%s\t%s\n' "${scope_args[0]/#$HOME/\~}" "$(format_bytes "${scope_bytes:-0}")" \
        | "$COLUMN_FORMATTER" --columns 2 --delimiter tab --dim 1
fi

consumers_output=$(mktemp) || exit 1
reclaim_output=$(mktemp) || exit 1
trap 'rm -f "$consumers_output" "$reclaim_output"' EXIT

"$CONSUMERS_SAMPLER" "${scope_args[@]}" > "$consumers_output" 2>/dev/null &
consumers_pid=$!

# Reclaim is a property of the machine, not of a subtree, so it is sampled only
# for the default whole-home view.
reclaim_pid=""
if [[ ${#scope_args[@]} -eq 0 ]]; then
    "$RECLAIM_SAMPLER" > "$reclaim_output" 2>/dev/null &
    reclaim_pid=$!
fi

if [[ -t 1 ]]; then
    source "$SPINNER"
    spin "$SCAN_LABEL" "$consumers_pid"
fi
wait "$consumers_pid" || exit 1
[[ -n "$reclaim_pid" ]] && wait "$reclaim_pid"

printf '\n'
while IFS=$'\t' read -r bytes path; do
    [[ "$bytes" =~ ^[0-9]+$ ]] || continue
    printf '%s\t%s\n' "${path/#$HOME/\~}" "$(format_bytes "$bytes")"
done < "$consumers_output" \
    | "$COLUMN_FORMATTER" \
        --columns "$CONSUMER_COLUMN_COUNT" \
        --delimiter tab \
        --dim "$CONSUMER_PATH_COLUMN"

reclaimable=$(awk -F'\t' '{ total += $2 } END { printf "%d\n", total }' "$reclaim_output")

if ((reclaimable > 0)); then
    printf '\n'
    print_dim "$(printf '~%s reclaimable · run: %s disk reclaim' \
        "$(format_bytes "$reclaimable")" "$PROGRAM_NAME")"
fi

exit 0
