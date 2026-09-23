#!/usr/bin/env bash

PROGRAM_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COLUMN_FORMATTER="$SCRIPT_DIR/columns.sh"
DISPLAY_LABEL="CPU"
GRID_COLUMN_COUNT=2
OUTPUT_COLUMN_COUNT=4
LEFT_LABEL_COLUMN=1
LEFT_PERCENT_COLUMN=2
RIGHT_LABEL_COLUMN=3
RIGHT_PERCENT_COLUMN=4
COLUMN_GAP_WIDTH=2
PERCENT_SCALE=100
ROUNDING_DIVISOR=2
FORMAT_CPU_COLUMNS=(
    "$COLUMN_FORMATTER"
    --delimiter tab
    --columns "$OUTPUT_COLUMN_COUNT"
    --dim "$LEFT_LABEL_COLUMN"
    --right "$LEFT_PERCENT_COLUMN"
    --dim "$RIGHT_LABEL_COLUMN"
    --right "$RIGHT_PERCENT_COLUMN"
    --gap "$COLUMN_GAP_WIDTH"
)

fail() {
    printf '%s: %s\n' "$PROGRAM_NAME" "$1" >&2
    exit 1
}

is_counter() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

cpu_labels=()
cpu_usages=()

while read -r record first second remainder; do
    [[ -n "$record" ]] || continue
    case "$record" in
        total|process)
            continue
            ;;
        logical)
            cpu_id="$first"
            busy_delta="$second"
            total_delta="$remainder"
            ;;
        *)
            fail "unknown CPU sample record '$record'"
            ;;
    esac

    is_counter "$cpu_id" || fail "invalid logical CPU identifier '$cpu_id'"
    is_counter "$busy_delta" || fail "invalid busy counter for CPU$cpu_id"
    is_counter "$total_delta" || fail "invalid total counter for CPU$cpu_id"
    ((total_delta > 0)) || fail "empty sampling interval for CPU$cpu_id"
    ((busy_delta <= total_delta)) || fail "busy counter exceeds total for CPU$cpu_id"

    cpu_label="${DISPLAY_LABEL}${cpu_id}"
    cpu_usage=$(((busy_delta * PERCENT_SCALE + total_delta / ROUNDING_DIVISOR) / total_delta))
    cpu_labels+=("$cpu_label")
    cpu_usages+=("$cpu_usage")
done

((${#cpu_labels[@]} > 0)) || fail "no logical CPU usage was provided"

row_count=$((${#cpu_labels[@]} + GRID_COLUMN_COUNT - 1))
row_count=$((row_count / GRID_COLUMN_COUNT))
cpu_rows=()

for ((row = 0; row < row_count; row++)); do
    cpu_row="${cpu_labels[row]}"$'\t'"${cpu_usages[row]}%"
    right_index=$((row + row_count))
    if ((right_index < ${#cpu_labels[@]})); then
        cpu_row+=$'\t'"${cpu_labels[right_index]}"$'\t'"${cpu_usages[right_index]}%"
    fi
    cpu_rows+=("$cpu_row")
done

if ! printf '%s\n' "${cpu_rows[@]}" | "${FORMAT_CPU_COLUMNS[@]}"; then
    fail "could not format logical CPU usage"
fi
