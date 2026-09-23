#!/usr/bin/env bash

PROGRAM_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_ROW_FORMATTER="$SCRIPT_DIR/process-rows.sh"
OTHER_ACTIVITY_LABEL="other activity"
EMPTY_ACTIVITY_LABEL="No measurable process activity"
MAX_DISPLAYED_PROCESSES=8
PERCENT_TENTHS_SCALE=1000
PERCENT_TENTHS_DIVISOR=10
ROUNDING_DIVISOR=2

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

total_busy_delta=""
total_delta=""
process_records=()

while read -r record first second remainder; do
    [[ -n "$record" ]] || continue
    case "$record" in
        total)
            [[ -z "$remainder" ]] || fail "unexpected fields in total CPU record"
            total_busy_delta="$first"
            total_delta="$second"
            ;;
        logical)
            continue
            ;;
        process)
            pid="$first"
            process_delta="$second"
            process_name="$remainder"
            is_counter "$pid" || fail "invalid process identifier '$pid'"
            is_counter "$process_delta" || fail "invalid CPU counter for PID $pid"
            [[ -n "$process_name" ]] || fail "missing process name for PID $pid"
            process_records+=("$process_delta"$'\t'"$pid"$'\t'"$process_name")
            ;;
        *)
            fail "unknown CPU sample record '$record'"
            ;;
    esac
done

is_counter "$total_busy_delta" || fail "missing total busy CPU counter"
is_counter "$total_delta" || fail "missing total CPU counter"
((total_delta > 0)) || fail "empty total CPU sampling interval"
((total_busy_delta <= total_delta)) || fail "total busy CPU counter exceeds total"

sorted_processes=()
if ((${#process_records[@]} > 0)); then
    if ! sorted_output=$(printf '%s\n' "${process_records[@]}" \
        | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2n); then
        fail "could not sort process CPU usage"
    fi
    mapfile -t sorted_processes <<< "$sorted_output"
fi

displayed_pids=()
displayed_names=()
displayed_percentages=()
displayed_ticks=0

for process_record in "${sorted_processes[@]}"; do
    IFS=$'\t' read -r process_delta pid process_name <<< "$process_record"
    usage_tenths=$(((process_delta * PERCENT_TENTHS_SCALE + total_delta / ROUNDING_DIVISOR) / total_delta))
    ((usage_tenths > 0)) || break
    ((${#displayed_pids[@]} < MAX_DISPLAYED_PROCESSES)) || break

    percentage="$(format_percent "$usage_tenths")"
    displayed_pids+=("$pid")
    displayed_names+=("$process_name")
    displayed_percentages+=("$percentage")
    displayed_ticks=$((displayed_ticks + process_delta))
done

((displayed_ticks <= total_busy_delta)) \
    || fail "displayed process CPU time exceeds total busy CPU time"
other_ticks=$((total_busy_delta - displayed_ticks))
other_usage_tenths=$(((other_ticks * PERCENT_TENTHS_SCALE + total_delta / ROUNDING_DIVISOR) / total_delta))
other_percentage="$(format_percent "$other_usage_tenths")"

process_rows=()
for ((index = 0; index < ${#displayed_pids[@]}; index++)); do
    process_rows+=(
        "${displayed_percentages[index]}"$'\t'"${displayed_names[index]}"$'\t'"(${displayed_pids[index]})"
    )
done

if ((other_usage_tenths > 0)); then
    process_rows+=("$other_percentage"$'\t'"$OTHER_ACTIVITY_LABEL")
elif ((${#displayed_pids[@]} == 0)); then
    process_rows+=("$EMPTY_ACTIVITY_LABEL")
fi

if ! printf '%s\n' "${process_rows[@]}" | "$PROCESS_ROW_FORMATTER"; then
    fail "could not format process CPU usage"
fi
