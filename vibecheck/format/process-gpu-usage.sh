#!/usr/bin/env bash

PROGRAM_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_ROW_FORMATTER="$SCRIPT_DIR/process-rows.sh"
MAX_DISPLAYED_PROCESSES=8
PERCENT_TENTHS_DIVISOR=10

fail() {
    printf '%s: %s\n' "$PROGRAM_NAME" "$1" >&2
    exit 1
}

is_counter() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

format_percent() {
    local usage_tenths="$1"
    printf '%d.%d%%' \
        "$((usage_tenths / PERCENT_TENTHS_DIVISOR))" \
        "$((usage_tenths % PERCENT_TENTHS_DIVISOR))"
}

process_records=()
while read -r record first second remainder; do
    [[ -n "$record" ]] || continue
    case "$record" in
        total)
            continue
            ;;
        process)
            pid="$first"
            usage_tenths="$second"
            process_name="$remainder"
            is_counter "$pid" || fail "invalid process identifier '$pid'"
            is_counter "$usage_tenths" || fail "invalid GPU usage for PID $pid"
            [[ -n "$process_name" ]] || fail "missing process name for PID $pid"
            ((usage_tenths > 0)) || continue
            process_records+=(
                "$usage_tenths"$'\t'"$pid"$'\t'"$process_name"
            )
            ;;
        *)
            fail "unknown GPU sample record '$record'"
            ;;
    esac
done

((${#process_records[@]} > 0)) || exit 0
if ! sorted_output=$(printf '%s\n' "${process_records[@]}" \
    | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2n); then
    fail "could not sort process GPU usage"
fi
mapfile -t sorted_processes <<< "$sorted_output"

process_rows=()
for process_record in "${sorted_processes[@]}"; do
    ((${#process_rows[@]} < MAX_DISPLAYED_PROCESSES)) || break
    IFS=$'\t' read -r usage_tenths pid process_name <<< "$process_record"
    process_rows+=(
        "$(format_percent "$usage_tenths")"$'\t'"$process_name"$'\t'"($pid)"
    )
done

if ! printf '%s\n' "${process_rows[@]}" | "$PROCESS_ROW_FORMATTER"; then
    fail "could not format process GPU usage"
fi
