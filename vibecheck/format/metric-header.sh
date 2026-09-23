#!/usr/bin/env bash

PROGRAM_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COLUMN_FORMATTER="$SCRIPT_DIR/columns.sh"
HEADER_SEPARATOR="·"
PAIR_OPTION="--pair"
SUFFIX_OPTION="--suffix"
NORMAL_SEGMENT="normal"
DIM_SUFFIX_SEGMENT="dim_suffix"
LABEL_COLUMN=1
LABEL_MINIMUM_WIDTH=4
NO_COLUMN_GAP=0

fail() {
    printf '%s: %s\n' "$PROGRAM_NAME" "$1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME LABEL VALUE [VALUE ...]

Format a metric header with a dimmed label and separators.

Structured values:
  --pair CURRENT REFERENCE  Join a current value to a dimmed reference value
  --suffix VALUE SUFFIX     Join a value to a dimmed suffix

Examples:
  $PROGRAM_NAME CPU 8% --suffix 53° C --pair 3.9 '/4.5 GHz'
  $PROGRAM_NAME RAM 35% --pair 6.8 '/19.3 GiB'
EOF
}

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

label="${1:-}"
[[ -n "$label" ]] || fail "a metric label is required"
shift

segment_types=()
segment_values=()
segment_references=()
while (($# > 0)); do
    if [[ "$1" == "$PAIR_OPTION" || "$1" == "$SUFFIX_OPTION" ]]; then
        option="$1"
        (($# >= 3)) || fail "$option requires a value and dimmed suffix"
        [[ -n "$2" && -n "$3" ]] \
            || fail "$option values cannot be empty"
        segment_types+=("$DIM_SUFFIX_SEGMENT")
        segment_values+=("$2")
        segment_references+=("$3")
        shift 3
    else
        [[ -n "$1" ]] && {
            segment_types+=("$NORMAL_SEGMENT")
            segment_values+=("$1")
            segment_references+=("")
        }
        shift
    fi
done
((${#segment_types[@]} > 0)) || fail "at least one metric value is required"

cells=("$label")
dim_columns=("$LABEL_COLUMN")
gap_after_widths=()

for ((index = 0; index < ${#segment_types[@]}; index++)); do
    if ((index > 0)); then
        cells+=("$HEADER_SEPARATOR")
        dim_columns+=("${#cells[@]}")
    fi

    cells+=("${segment_values[index]}")
    if [[ "${segment_types[index]}" == "$DIM_SUFFIX_SEGMENT" ]]; then
        primary_column=${#cells[@]}
        cells+=("${segment_references[index]}")
        reference_column=${#cells[@]}
        dim_columns+=("$reference_column")
        gap_after_widths+=("$primary_column:$NO_COLUMN_GAP")
    fi
done

header_row="${cells[0]}"
for ((column = 1; column < ${#cells[@]}; column++)); do
    header_row+=$'\t'"${cells[column]}"
done

format_header=(
    "$COLUMN_FORMATTER"
    --delimiter tab
    --columns "${#cells[@]}"
    --min-width "$LABEL_COLUMN:$LABEL_MINIMUM_WIDTH"
)
for column in "${dim_columns[@]}"; do
    format_header+=(--dim "$column")
done
for width in "${gap_after_widths[@]}"; do
    format_header+=(--gap-after "$width")
done

if ! printf '%s\n' "$header_row" | "${format_header[@]}"; then
    fail "could not format metric header"
fi
