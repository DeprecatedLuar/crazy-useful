#!/usr/bin/env bash

PROGRAM_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROC_ROOT="/proc"
PROC_STAT_PATH="$PROC_ROOT/stat"
SAMPLE_INTERVAL_SECONDS=1
MINIMUM_CPU_LABEL_COUNT=2

fail() {
    printf '%s: %s\n' "$PROGRAM_NAME" "$1" >&2
    exit 1
}

source "$SCRIPT_DIR/process-name.sh"

is_counter() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

read_cpu_snapshot() {
    local totals_name="$1"
    local busy_name="$2"
    local labels_name="$3"
    local -n totals="$totals_name"
    local -n busy="$busy_name"
    local -n labels="$labels_name"
    local label user nice system idle iowait irq softirq steal remainder
    local value

    [[ -r "$PROC_STAT_PATH" ]] || fail "cannot read $PROC_STAT_PATH"

    while read -r label user nice system idle iowait irq softirq steal remainder; do
        [[ "$label" =~ ^cpu([0-9]+)?$ ]] || continue

        for value in "$user" "$nice" "$system" "$idle" "$iowait" "$irq" "$softirq" "$steal"; do
            is_counter "$value" || fail "invalid CPU counters in $PROC_STAT_PATH"
        done

        labels+=("$label")
        busy["$label"]=$((user + nice + system + irq + softirq + steal))
        totals["$label"]=$((busy["$label"] + idle + iowait))
    done < "$PROC_STAT_PATH"

    ((${#labels[@]} >= MINIMUM_CPU_LABEL_COUNT)) \
        || fail "no per-CPU counters found in $PROC_STAT_PATH"
}

read_process_snapshot() {
    local ticks_name="$1"
    local starts_name="$2"
    local names_name="$3"
    local -n ticks="$ticks_name"
    local -n starts="$starts_name"
    local -n names="$names_name"
    local stat_path pid stat_line stat_fields process_name
    local state ppid pgrp session tty_nr tpgid flags
    local minflt cminflt majflt cmajflt utime stime cutime cstime
    local priority nice_value thread_count interval_timer start_time remainder
    local process_count=0

    for stat_path in "$PROC_ROOT"/[0-9]*/stat; do
        [[ -r "$stat_path" ]] || continue
        pid="${stat_path#"$PROC_ROOT/"}"
        pid="${pid%%/*}"
        ((pid == $$ || pid == PPID)) && continue

        IFS= read -r stat_line < "$stat_path" || continue
        stat_fields="${stat_line##*) }"
        [[ "$stat_fields" != "$stat_line" ]] || fail "invalid process counters in $stat_path"

        read -r state ppid pgrp session tty_nr tpgid flags \
            minflt cminflt majflt cmajflt utime stime cutime cstime \
            priority nice_value thread_count interval_timer start_time remainder \
            <<< "$stat_fields"
        is_counter "$utime" || fail "invalid user CPU counter in $stat_path"
        is_counter "$stime" || fail "invalid system CPU counter in $stat_path"
        is_counter "$start_time" || fail "invalid start time in $stat_path"

        read_process_name process_name "$PROC_ROOT/$pid" "PID $pid"

        ticks["$pid"]=$((utime + stime))
        starts["$pid"]="$start_time"
        names["$pid"]="$process_name"
        ((process_count++))
    done

    ((process_count > 0)) || fail "no process CPU counters found in $PROC_ROOT"
}

declare -A initial_cpu_totals=()
declare -A initial_cpu_busy=()
declare -A current_cpu_totals=()
declare -A current_cpu_busy=()
declare -A initial_process_ticks=()
declare -A initial_process_starts=()
declare -A initial_process_names=()
declare -A current_process_ticks=()
declare -A current_process_starts=()
declare -A current_process_names=()
initial_cpu_labels=()
current_cpu_labels=()

# Bracket the process interval inside the aggregate CPU interval. This keeps
# attributed process time from exceeding the sampled total during normal races.
read_cpu_snapshot initial_cpu_totals initial_cpu_busy initial_cpu_labels
read_process_snapshot initial_process_ticks initial_process_starts initial_process_names
sleep "$SAMPLE_INTERVAL_SECONDS" || fail "CPU sampling interval was interrupted"
read_process_snapshot current_process_ticks current_process_starts current_process_names
read_cpu_snapshot current_cpu_totals current_cpu_busy current_cpu_labels

for label in "${initial_cpu_labels[@]}"; do
    [[ -v "current_cpu_totals[$label]" ]] || fail "$label disappeared while sampling"

    total_delta=$((current_cpu_totals["$label"] - initial_cpu_totals["$label"]))
    busy_delta=$((current_cpu_busy["$label"] - initial_cpu_busy["$label"]))
    ((total_delta > 0)) || fail "invalid sampling interval for $label"
    ((busy_delta >= 0)) || fail "CPU counters moved backwards for $label"

    if [[ "$label" == "cpu" ]]; then
        printf 'total %d %d\n' "$busy_delta" "$total_delta"
    else
        printf 'logical %s %d %d\n' "${label#cpu}" "$busy_delta" "$total_delta"
    fi
done

for pid in "${!current_process_ticks[@]}"; do
    [[ -v "initial_process_ticks[$pid]" ]] || continue
    [[ "${current_process_starts[$pid]}" == "${initial_process_starts[$pid]}" ]] || continue

    process_delta=$((current_process_ticks["$pid"] - initial_process_ticks["$pid"]))
    ((process_delta > 0)) || continue
    printf 'process %d %d %s\n' \
        "$pid" "$process_delta" "${current_process_names[$pid]}"
done
