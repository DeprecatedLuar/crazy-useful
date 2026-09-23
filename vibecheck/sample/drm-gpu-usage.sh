#!/usr/bin/env bash

PROGRAM_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROC_ROOT="/proc"
PROC_UPTIME_PATH="$PROC_ROOT/uptime"
EXPECTED_ARGUMENT_COUNT=2
SAMPLE_INTERVAL_SECONDS=1
PERCENT_SCALE=100
PERCENT_TENTHS_SCALE=1000
NANOSECONDS_PER_MICROSECOND=1000
MICROSECONDS_PER_SECOND=1000000

fail() {
    printf '%s: %s\n' "$PROGRAM_NAME" "$1" >&2
    exit 1
}

source "$SCRIPT_DIR/process-name.sh"

is_counter() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

read_monotonic_microseconds() {
    local uptime_seconds uptime_fraction remainder

    [[ -r "$PROC_UPTIME_PATH" ]] || fail "cannot read $PROC_UPTIME_PATH"
    IFS='. ' read -r uptime_seconds uptime_fraction remainder < "$PROC_UPTIME_PATH" \
        || fail "cannot parse $PROC_UPTIME_PATH"
    is_counter "$uptime_seconds" || fail "invalid uptime in $PROC_UPTIME_PATH"
    is_counter "$uptime_fraction" || fail "invalid uptime in $PROC_UPTIME_PATH"

    uptime_fraction="${uptime_fraction}000000"
    uptime_fraction="${uptime_fraction:0:6}"
    printf '%d\n' "$((
        10#$uptime_seconds * MICROSECONDS_PER_SECOND + 10#$uptime_fraction
    ))"
}

read_drm_snapshot() {
    local counters_name="$1"
    local capacities_name="$2"
    local client_pids_name="$3"
    local driver="$4"
    local pci_address="$5"
    local -n counters="$counters_name"
    local -n capacities="$capacities_name"
    local -n client_pids="$client_pids_name"
    local fdinfo_path fdinfo_content field value unit pid client engine key
    local capacity current_busy
    local -A file_busy=()
    local -A file_capacity=()

    for fdinfo_path in "$PROC_ROOT"/[0-9]*/fdinfo/[0-9]*; do
        [[ -r "$fdinfo_path" ]] || continue
        fdinfo_content=""
        IFS= read -r -d '' fdinfo_content < "$fdinfo_path" 2>/dev/null || true
        [[ -n "$fdinfo_content" ]] || continue
        [[ "$fdinfo_content" == *$'drm-driver:\t'"$driver"* ]] || continue
        [[ "$fdinfo_content" == *$'drm-pdev:\t'"$pci_address"* ]] || continue

        pid="${fdinfo_path#"$PROC_ROOT/"}"
        pid="${pid%%/*}"
        is_counter "$pid" || fail "invalid process identifier"

        client=""
        file_busy=()
        file_capacity=()
        while read -r field value unit; do
            case "$field" in
                drm-client-id:)
                    client="$value"
                    ;;
                drm-engine-capacity-*:)
                    engine="${field#drm-engine-capacity-}"
                    engine="${engine%:}"
                    file_capacity["$engine"]="$value"
                    ;;
                drm-engine-*:)
                    engine="${field#drm-engine-}"
                    engine="${engine%:}"
                    file_busy["$engine"]="$value"
                    ;;
            esac
        done <<< "$fdinfo_content"

        [[ -n "$client" ]] || fail "missing DRM client identifier"
        is_counter "$client" || fail "invalid DRM client identifier"
        client_pids["$client"]="$pid"
        for engine in "${!file_busy[@]}"; do
            [[ "$engine" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "invalid DRM engine name"
            is_counter "${file_busy[$engine]}" || fail "invalid DRM engine counter"
            capacity="${file_capacity[$engine]:-1}"
            is_counter "$capacity" || fail "invalid DRM engine capacity"
            ((capacity > 0)) || fail "invalid DRM engine capacity"

            key="$client:$engine"
            current_busy="${counters[$key]:-0}"
            if [[ ! -v "counters[$key]" ]] \
                || ((${file_busy[$engine]} > current_busy)); then
                counters["$key"]="${file_busy[$engine]}"
            fi
            if ((capacity > ${capacities[$engine]:-0})); then
                capacities["$engine"]="$capacity"
            fi
        done
    done
}

(($# == EXPECTED_ARGUMENT_COUNT)) \
    || fail "usage: $PROGRAM_NAME DRIVER PCI_ADDRESS"

driver="$1"
pci_address="$2"
[[ "$driver" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "invalid DRM driver name"
[[ "$pci_address" =~ ^[0-9a-fA-F:.]+$ ]] || fail "invalid PCI address"

declare -A initial_counters=()
declare -A initial_capacities=()
declare -A initial_client_pids=()
declare -A current_counters=()
declare -A current_capacities=()
declare -A current_client_pids=()
declare -A engine_deltas=()
declare -A process_engine_deltas=()
declare -A process_usage_tenths=()

initial_time=$(read_monotonic_microseconds)
read_drm_snapshot \
    initial_counters initial_capacities initial_client_pids \
    "$driver" "$pci_address"
sleep "$SAMPLE_INTERVAL_SECONDS" || fail "GPU sampling interval was interrupted"
current_time=$(read_monotonic_microseconds)
read_drm_snapshot \
    current_counters current_capacities current_client_pids \
    "$driver" "$pci_address"

# An empty snapshot means this driver does not expose per-client engine counters.
# Produce no value so callers can keep other GPU metrics without inventing usage.
((${#initial_counters[@]} > 0 || ${#current_counters[@]} > 0)) || exit 0

elapsed_microseconds=$((current_time - initial_time))
((elapsed_microseconds > 0)) || fail "invalid GPU sampling interval"

for key in "${!current_counters[@]}"; do
    client="${key%%:*}"
    engine="${key#*:}"
    current_busy="${current_counters[$key]}"
    if [[ -v "initial_counters[$key]" ]]; then
        initial_busy="${initial_counters[$key]}"
        ((current_busy >= initial_busy)) || continue
        busy_delta=$((current_busy - initial_busy))
    else
        # A new client's counter contains only work performed since it opened
        # the DRM device during this sample.
        busy_delta="$current_busy"
    fi
    engine_deltas["$engine"]=$((${engine_deltas["$engine"]:-0} + busy_delta))
    pid="${current_client_pids[$client]:-}"
    if [[ -n "$pid" ]]; then
        process_engine_key="$pid:$engine"
        process_engine_deltas["$process_engine_key"]=$((${process_engine_deltas["$process_engine_key"]:-0} + busy_delta))
    fi
done

highest_usage=0
for engine in "${!engine_deltas[@]}"; do
    capacity="${current_capacities[$engine]:-${initial_capacities[$engine]:-1}}"
    available_time=$((
        elapsed_microseconds * NANOSECONDS_PER_MICROSECOND * capacity
    ))
    usage=$((
        (engine_deltas["$engine"] * PERCENT_SCALE + available_time / 2)
        / available_time
    ))
    ((usage > PERCENT_SCALE)) && usage="$PERCENT_SCALE"
    ((usage > highest_usage)) && highest_usage="$usage"
done

printf 'total %d\n' "$highest_usage"

for key in "${!process_engine_deltas[@]}"; do
    pid="${key%%:*}"
    engine="${key#*:}"
    capacity="${current_capacities[$engine]:-${initial_capacities[$engine]:-1}}"
    available_time=$((
        elapsed_microseconds * NANOSECONDS_PER_MICROSECOND * capacity
    ))
    usage_tenths=$((
        (process_engine_deltas["$key"] * PERCENT_TENTHS_SCALE + available_time / 2)
        / available_time
    ))
    ((usage_tenths > PERCENT_TENTHS_SCALE)) \
        && usage_tenths="$PERCENT_TENTHS_SCALE"
    if ((usage_tenths > ${process_usage_tenths[$pid]:-0})); then
        process_usage_tenths["$pid"]="$usage_tenths"
    fi
done

for pid in "${!process_usage_tenths[@]}"; do
    usage_tenths="${process_usage_tenths[$pid]}"
    ((usage_tenths > 0)) || continue
    read_process_name process_name "$PROC_ROOT/$pid" "PID $pid"
    printf 'process %d %d %s\n' "$pid" "$usage_tenths" "$process_name"
done
