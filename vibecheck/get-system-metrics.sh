#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COLUMN_FORMATTER="$SCRIPT_DIR/format/columns.sh"
METRIC_HEADER_FORMATTER="$SCRIPT_DIR/format/metric-header.sh"
CPU_USAGE_SAMPLER="$SCRIPT_DIR/sample/cpu-usage.sh"
DRM_GPU_USAGE_SAMPLER="$SCRIPT_DIR/sample/drm-gpu-usage.sh"
NVIDIA_PROCESS_USAGE_SAMPLER="$SCRIPT_DIR/sample/nvidia-process-usage.sh"
CPU_USAGE_FORMATTER="$SCRIPT_DIR/format/cpu-usage.sh"
PROCESS_CPU_USAGE_FORMATTER="$SCRIPT_DIR/format/process-cpu-usage.sh"
PROCESS_GPU_USAGE_FORMATTER="$SCRIPT_DIR/format/process-gpu-usage.sh"
PROCESS_ROW_FORMATTER="$SCRIPT_DIR/format/process-rows.sh"
NVIDIA_GPU_INDEX=0
PERCENT_SCALE=100
ROUNDING_DIVISOR=2
SECONDARY_LINE_COLUMN_COUNT=1
SECONDARY_LINE_COLUMN=1
FORMAT_SECONDARY_LINE=(
    "$COLUMN_FORMATTER"
    --columns "$SECONDARY_LINE_COLUMN_COUNT"
    --dim "$SECONDARY_LINE_COLUMN"
)

format_metric_header() {
    "$METRIC_HEADER_FORMATTER" "$@"
}

read_igpu_metrics() {
    local driver_path device_path igpu_driver igpu_pci_address

    igpu_card=$(for card in /sys/class/drm/card[0-9]; do
        [[ -f "$card/gt_cur_freq_mhz" ]] && printf '%s\n' "$card" && break
    done)
    [[ -n "$igpu_card" ]] || return 1

    cur_freq=$(cat "$igpu_card/gt_cur_freq_mhz" 2>/dev/null)
    max_freq=$(cat "$igpu_card/gt_max_freq_mhz" 2>/dev/null)
    driver_path=$(readlink -f "$igpu_card/device/driver" 2>/dev/null)
    device_path=$(readlink -f "$igpu_card/device" 2>/dev/null)
    igpu_driver="${driver_path##*/}"
    igpu_pci_address="${device_path##*/}"
    igpu_usage=""
    igpu_usage_output=""

    if [[ -n "$igpu_driver" && -n "$igpu_pci_address" ]]; then
        igpu_usage_output=$(
            "$DRM_GPU_USAGE_SAMPLER" "$igpu_driver" "$igpu_pci_address"
        ) || return 1
        while read -r record value remainder; do
            [[ "$record" == "total" ]] || continue
            [[ "$value" =~ ^[0-9]+$ && -z "$remainder" ]] || return 1
            igpu_usage="$value"
            break
        done <<< "$igpu_usage_output"
    fi
}

build_igpu_header_values() {
    igpu_header_values=()
    [[ -n "$igpu_usage" ]] && igpu_header_values+=("${igpu_usage}%")
    [[ -n "$pkg_temp" ]] \
        && igpu_header_values+=(--suffix "${pkg_temp%%.*}°" "C")
    if [[ -n "$cur_freq" && -n "$max_freq" ]]; then
        igpu_header_values+=(--pair "$cur_freq" "/${max_freq} MHz")
    fi
}

format_igpu_processes() {
    [[ -n "$igpu_usage_output" ]] || return 0
    if ! "$PROCESS_GPU_USAGE_FORMATTER" <<< "$igpu_usage_output"; then
        printf 'Could not format iGPU process rows\n' >&2
        return 1
    fi
}

format_nvidia_processes() {
    local usage_output

    usage_output=$("$NVIDIA_PROCESS_USAGE_SAMPLER" "$NVIDIA_GPU_INDEX") \
        || return 1
    [[ -n "$usage_output" ]] || return 0
    if ! "$PROCESS_GPU_USAGE_FORMATTER" <<< "$usage_output"; then
        printf 'Could not format NVIDIA process rows\n' >&2
        return 1
    fi
}

is_decimal() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_positive_decimal() {
    is_decimal "$1" && [[ "$1" =~ [1-9] ]]
}

read_nvidia_metrics() {
    local raw_metrics parsed_metrics

    if ! raw_metrics=$(nvidia-smi \
        --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1); then
        return 1
    fi
    parsed_metrics=$(awk -F',' '{
        for (field = 1; field <= 4; field++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $field)
        }
        print $1, $2, $3, $4
    }' <<< "$raw_metrics")
    read -r nvidia_usage nvidia_temp nvidia_mem_used nvidia_mem_total \
        <<< "$parsed_metrics"

    is_decimal "$nvidia_usage" \
        && is_decimal "$nvidia_temp" \
        && is_decimal "$nvidia_mem_used" \
        && is_decimal "$nvidia_mem_total"
}

read_amd_metrics() {
    local raw_metrics

    if ! raw_metrics=$(sensors 2>/dev/null | awk '
        /^amdgpu-/,/^$/ {
            if (/^edge:/ && temp == "") {
                match($0, /\+([0-9.]+)/, value)
                temp = value[1]
            }
            if (/^power1:/ && power == "") {
                match($0, /([0-9.]+) W/, current)
                match($0, /cap = ([0-9.]+) W/, maximum)
                power = current[1]
                cap = maximum[1]
            }
        }
        END { printf "%s\t%s\t%s\n", temp, power, cap }
    '); then
        return 1
    fi
    IFS=$'\t' read -r amd_temp amd_power amd_power_cap <<< "$raw_metrics"
    is_decimal "$amd_temp"
}

format_amd_header() {
    local label="$1"
    local values=()

    values+=(--suffix "${amd_temp%%.*}°" "C")
    if is_decimal "$amd_power" && is_decimal "$amd_power_cap"; then
        values+=(--pair "$amd_power" "/${amd_power_cap} W")
    elif is_decimal "$amd_power"; then
        values+=("${amd_power} W")
    fi
    format_metric_header "$label" "${values[@]}"
}

# Parse flags
show_all=false
metrics=()
for arg in "$@"; do
    if [[ "$arg" == "--all" ]]; then
        show_all=true
    else
        metrics+=("$arg")
    fi
done
[[ ${#metrics[@]} -eq 0 ]] && metrics=(cpu ram gpu fan bat disk)

# Dependency check - warn about missing tools
MISSING_DEPS=()
command -v free &>/dev/null || MISSING_DEPS+=("free (install procps/procps-ng)")
command -v sensors &>/dev/null || MISSING_DEPS+=("sensors (install lm-sensors)")
command -v lspci &>/dev/null || MISSING_DEPS+=("lspci (install pciutils)")

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo "Warning: Missing dependencies for full metrics:" >&2
    printf "  - %s\n" "${MISSING_DEPS[@]}" >&2
    echo >&2
fi

for metric in "${metrics[@]}"; do
    case "$metric" in
        cpu)
            if ! cpu_usage_output=$("$CPU_USAGE_SAMPLER"); then
                exit 1
            fi
            mapfile -t cpu_usage_lines <<< "$cpu_usage_output"
            read -r record busy_delta total_delta <<< "${cpu_usage_lines[0]}"
            [[ "$record" == "total" ]] || {
                printf 'Invalid CPU sample: missing total record\n' >&2
                exit 1
            }
            usage=$(((busy_delta * PERCENT_SCALE + total_delta / ROUNDING_DIVISOR) / total_delta))
            temp=$(sensors 2>/dev/null | grep -E '^(Package id 0|Tctl|Core 0|temp1):' | head -1 | awk '{match($0, /\+([0-9.]+)/, a); print a[1]}')
            cur_freq=$(awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count/1000000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)
            max_freq=$(awk '{print $1/1000000; exit}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
            cpu_header_values=("${usage}%")
            if [[ -n "$temp" ]]; then
                cpu_header_values+=(--suffix "${temp%%.*}°" "C")
            fi
            if [[ -n "$cur_freq" && -n "$max_freq" ]]; then
                cpu_header_values+=(--pair "$cur_freq" "/${max_freq} GHz")
            fi
            if [[ ${#metrics[@]} -eq 1 ]]; then
                # Detailed output
                format_metric_header CPU "${cpu_header_values[@]}" || exit 1
                echo ""
                if ! "$CPU_USAGE_FORMATTER" <<< "$cpu_usage_output"; then
                    exit 1
                fi
                echo ""
                if ! "$PROCESS_CPU_USAGE_FORMATTER" <<< "$cpu_usage_output"; then
                    exit 1
                fi
            else
                printf 'CPU %s%%' "$usage"
                [[ -n "$temp" ]] && printf ' (%s°C)' "${temp%%.*}"
                if [[ -n "$cur_freq" && -n "$max_freq" ]]; then
                    printf ' @ %s/%sGHz' "$cur_freq" "$max_freq"
                fi
                printf '\n'
            fi
            ;;
        ram)
            if ! ram_stats=$(LC_ALL=C free -b | awk '/^Mem:/ {
                bytes_per_gib = 1024 * 1024 * 1024
                percent = 100
                total = $2
                free = $4
                cache = $6
                available = $7
                used = total - free - cache

                printf "%.0f %.1f %.1f %.0f %.0f %.1f", \
                    used / total * percent, \
                    used / bytes_per_gib, \
                    total / bytes_per_gib, \
                    cache / total * percent, \
                    free / total * percent, \
                    available / bytes_per_gib
            }' FS='[[:space:]]+'); then
                printf 'Could not read RAM metrics\n' >&2
                exit 1
            fi
            [[ -n "$ram_stats" ]] || {
                printf 'Could not find RAM metrics\n' >&2
                exit 1
            }
            read -r ram_usage ram_used_gib ram_total_gib \
                ram_cache_percent ram_free_percent ram_available_gib <<< "$ram_stats"
            if [[ ${#metrics[@]} -eq 1 ]]; then
                format_metric_header RAM \
                    "${ram_usage}%" \
                    --pair "$ram_used_gib" "/${ram_total_gib} GiB" || exit 1
                ram_detail_row=$(printf '%s%% cache · %s%% free · %s GiB available' \
                    "$ram_cache_percent" "$ram_free_percent" "$ram_available_gib")
                if ! printf '%s\n' "$ram_detail_row" | "${FORMAT_SECONDARY_LINE[@]}"; then
                    printf 'Could not format RAM details\n' >&2
                    exit 1
                fi
                echo ""

                if [[ "$show_all" == true ]]; then
                    # Show all processes
                    ram_process_rows=$(ps aux --sort=-%mem | awk 'NR>1 && $4>0 {
                        cmd=$11; gsub(/^.*\//, "", cmd)
                        printf "%.1f%%\t%s\t(%s)\n", $4, cmd, $2
                    }')
                else
                    # Show processes >1%
                    ram_process_rows=$(ps aux --sort=-%mem | awk 'NR>1 && $4>1 {
                        cmd=$11; gsub(/^.*\//, "", cmd)
                        printf "%.0f%%\t%s\t(%s)\n", $4, cmd, $2
                    }')

                    # Add background summary
                    ram_background_row=$(ps aux --no-headers | awk '
                        $4 <= 1 && $4 > 0 {sum += $4; count++}
                        END {
                            if (count > 0) {
                                printf "%.0f%%\tbackground\t(%d processes)", sum, count
                            }
                        }
                    ')
                    if [[ -n "$ram_background_row" ]]; then
                        [[ -n "$ram_process_rows" ]] && ram_process_rows+=$'\n'
                        ram_process_rows+="$ram_background_row"
                    fi
                fi
                if [[ -n "$ram_process_rows" ]]; then
                    if ! "$PROCESS_ROW_FORMATTER" <<< "$ram_process_rows"; then
                        exit 1
                    fi
                fi
            else
                printf 'RAM %s%%\n' "$ram_usage"
            fi
            ;;
        gpu)
            # Detect hybrid setup
            has_igpu=$(lspci 2>/dev/null | grep -qi '00:02.0.*vga' && echo 1)
            discrete_addr=$(lspci -D 2>/dev/null | grep -iE 'vga|3d' | grep -v '0000:00:02' | awk '{print $1}' | head -1)
            pkg_temp=$(sensors 2>/dev/null | grep -E '^Package id 0:' | sed 's/^[^+]*+\([0-9.]*\).*/\1/')

            # iGPU utilization is sampled from per-client DRM engine busy time.
            if [[ -n "$has_igpu" ]]; then
                read_igpu_metrics || exit 1
                if [[ -n "$cur_freq" && -n "$max_freq" && "$max_freq" -gt 0 ]]; then
                    if [[ ${#metrics[@]} -eq 1 ]]; then
                        build_igpu_header_values
                        format_metric_header iGPU "${igpu_header_values[@]}" || exit 1
                        echo ""
                        format_igpu_processes || exit 1
                        [[ -n "$discrete_addr" ]] && echo ""
                    else
                        printf 'iGPU'
                        [[ -n "$igpu_usage" ]] && printf ' %s%%' "$igpu_usage"
                        [[ -n "$pkg_temp" ]] && printf ' (%s°C)' "${pkg_temp%%.*}"
                        printf ' @ %s/%sMHz' "$cur_freq" "$max_freq"
                        printf '\n'
                    fi
                elif [[ -n "$discrete_addr" ]]; then
                    if [[ ${#metrics[@]} -eq 1 ]]; then
                        format_metric_header iGPU detected || exit 1
                    else
                        printf 'iGPU detected\n'
                    fi
                fi
            fi

            # dGPU with stats
            if [[ -n "$discrete_addr" ]]; then
                power_state=$(cat "/sys/bus/pci/devices/$discrete_addr/power/runtime_status" 2>/dev/null)
                if [[ "$power_state" == "suspended" ]]; then
                    if [[ ${#metrics[@]} -eq 1 ]]; then
                        format_metric_header dGPU suspended || exit 1
                    else
                        printf 'dGPU suspended\n'
                    fi
                elif command -v nvidia-smi &>/dev/null; then
                    if read_nvidia_metrics; then
                        if [[ ${#metrics[@]} -eq 1 ]]; then
                            format_metric_header dGPU \
                                "${nvidia_usage}%" \
                                --suffix "${nvidia_temp%%.*}°" "C" \
                                --pair "$nvidia_mem_used" "/${nvidia_mem_total} MiB" || exit 1
                            if is_positive_decimal "$nvidia_usage"; then
                                echo ""
                                format_nvidia_processes || exit 1
                            fi
                        else
                            printf 'dGPU %s%% (%s°C)\n' \
                                "$nvidia_usage" "${nvidia_temp%%.*}"
                        fi
                    else
                        if [[ ${#metrics[@]} -eq 1 ]]; then
                            format_metric_header dGPU unavailable || exit 1
                        else
                            printf 'dGPU unavailable\n'
                        fi
                    fi
                elif sensors 2>/dev/null | grep -q '^amdgpu-'; then
                    if read_amd_metrics; then
                        if [[ ${#metrics[@]} -eq 1 ]]; then
                            format_amd_header dGPU || exit 1
                        else
                            printf 'dGPU %s°C\n' "${amd_temp%%.*}"
                        fi
                    else
                        if [[ ${#metrics[@]} -eq 1 ]]; then
                            format_metric_header dGPU unavailable || exit 1
                        else
                            printf 'dGPU unavailable\n'
                        fi
                    fi
                else
                    if [[ ${#metrics[@]} -eq 1 ]]; then
                        format_metric_header dGPU unavailable || exit 1
                    else
                        printf 'dGPU unavailable\n'
                    fi
                fi
            elif command -v nvidia-smi &>/dev/null; then
                # Single NVIDIA GPU (no hybrid)
                if read_nvidia_metrics; then
                    if [[ ${#metrics[@]} -eq 1 ]]; then
                        format_metric_header GPU \
                            "${nvidia_usage}%" \
                            --suffix "${nvidia_temp%%.*}°" "C" \
                            --pair "$nvidia_mem_used" "/${nvidia_mem_total} MiB" || exit 1
                    else
                        printf 'GPU %s%% (%s°C)\n' \
                            "$nvidia_usage" "${nvidia_temp%%.*}"
                    fi
                else
                    if [[ ${#metrics[@]} -eq 1 ]]; then
                        format_metric_header GPU unavailable || exit 1
                    else
                        printf 'GPU unavailable\n'
                    fi
                fi
            elif sensors 2>/dev/null | grep -q '^amdgpu-'; then
                # Single AMD GPU (no hybrid)
                if read_amd_metrics; then
                    if [[ ${#metrics[@]} -eq 1 ]]; then
                        format_amd_header GPU || exit 1
                    else
                        printf 'GPU %s°C\n' "${amd_temp%%.*}"
                    fi
                else
                    if [[ ${#metrics[@]} -eq 1 ]]; then
                        format_metric_header GPU unavailable || exit 1
                    else
                        printf 'GPU unavailable\n'
                    fi
                fi
            else
                if [[ ${#metrics[@]} -eq 1 ]]; then
                    format_metric_header GPU "not detected" || exit 1
                else
                    printf 'GPU not detected\n'
                fi
            fi
            ;;
        igpu)
            has_igpu=$(lspci 2>/dev/null | grep -qi '00:02.0.*vga' && echo 1)
            pkg_temp=$(sensors 2>/dev/null | grep -E '^Package id 0:' | sed 's/^[^+]*+\([0-9.]*\).*/\1/')

            if [[ -n "$has_igpu" ]]; then
                read_igpu_metrics || exit 1
                if [[ -n "$cur_freq" && -n "$max_freq" && "$max_freq" -gt 0 ]]; then
                    build_igpu_header_values
                    format_metric_header iGPU "${igpu_header_values[@]}" || exit 1
                    echo ""
                    format_igpu_processes || exit 1
                else
                    format_metric_header iGPU detected || exit 1
                fi
            else
                format_metric_header iGPU "not detected" || exit 1
            fi
            ;;
        dgpu)
            discrete_addr=$(lspci -D 2>/dev/null | grep -iE 'vga|3d' | grep -v '0000:00:02' | awk '{print $1}' | head -1)

            if [[ -n "$discrete_addr" ]]; then
                power_state=$(cat "/sys/bus/pci/devices/$discrete_addr/power/runtime_status" 2>/dev/null)
                if [[ "$power_state" == "suspended" ]]; then
                    format_metric_header dGPU suspended || exit 1
                elif command -v nvidia-smi &>/dev/null; then
                    if read_nvidia_metrics; then
                        format_metric_header dGPU \
                            "${nvidia_usage}%" \
                            --suffix "${nvidia_temp%%.*}°" "C" \
                            --pair "$nvidia_mem_used" "/${nvidia_mem_total} MiB" || exit 1
                        if is_positive_decimal "$nvidia_usage"; then
                            echo ""
                            format_nvidia_processes || exit 1
                        fi
                    else
                        format_metric_header dGPU unavailable || exit 1
                    fi
                elif sensors 2>/dev/null | grep -q '^amdgpu-'; then
                    if read_amd_metrics; then
                        format_amd_header dGPU || exit 1
                    else
                        format_metric_header dGPU unavailable || exit 1
                    fi
                else
                    format_metric_header dGPU unavailable || exit 1
                fi
            elif command -v nvidia-smi &>/dev/null; then
                # Single NVIDIA GPU (no hybrid)
                if read_nvidia_metrics; then
                    format_metric_header GPU \
                        "${nvidia_usage}%" \
                        --suffix "${nvidia_temp%%.*}°" "C" \
                        --pair "$nvidia_mem_used" "/${nvidia_mem_total} MiB" || exit 1
                    if is_positive_decimal "$nvidia_usage"; then
                        echo ""
                        format_nvidia_processes || exit 1
                    fi
                else
                    format_metric_header GPU unavailable || exit 1
                fi
            else
                format_metric_header dGPU "not detected" || exit 1
            fi
            ;;
        fan|fans)
            fan_stats=$(sensors 2>/dev/null | awk '/^fan[0-9]+:/ && /RPM/ {
                name = $1
                gsub(/:/, "", name)
                match($0, /[[:space:]]+([0-9]+) RPM/, current)
                match($0, /max = ([0-9]+) RPM/, maximum)
                printf "%s\t%s\t%s\n", toupper(name), current[1], maximum[1]
            }')
            if [[ ${#metrics[@]} -eq 1 ]]; then
                while IFS=$'\t' read -r fan_name fan_current fan_max; do
                    [[ -n "$fan_name" && -n "$fan_current" ]] || continue
                    if [[ "$fan_max" =~ ^[1-9][0-9]*$ ]]; then
                        fan_percent=$((fan_current * PERCENT_SCALE / fan_max))
                        format_metric_header "$fan_name" \
                            "${fan_percent}%" \
                            --pair "$fan_current" "/${fan_max} RPM" || exit 1
                    else
                        format_metric_header "$fan_name" "${fan_current} RPM" || exit 1
                    fi
                done <<< "$fan_stats"
            else
                fan_average=$(awk -F'\t' '{sum += $2; count++} END {
                    if (count > 0) printf "%.0f", sum / count
                }' <<< "$fan_stats")
                if [[ -n "$fan_average" ]]; then
                    printf 'FAN %srpm\n' "$fan_average"
                fi
            fi
            ;;
        bat)
            for psu in /sys/class/power_supply/*; do
                [[ "$(cat "$psu/type" 2>/dev/null)" == "Battery" ]] || continue
                capacity=$(cat "$psu/capacity" 2>/dev/null)
                status=$(cat "$psu/status" 2>/dev/null)
                if [[ -n "$capacity" ]]; then
                    if [[ ${#metrics[@]} -eq 1 ]]; then
                        battery_values=("${capacity}%")
                        [[ -n "$status" ]] && battery_values+=("${status,,}")
                        format_metric_header BAT "${battery_values[@]}" || exit 1
                    else
                        printf 'BAT %s%%' "$capacity"
                        [[ -n "$status" ]] && printf ' (%s)' "$status"
                        printf '\n'
                    fi
                fi
            done
            ;;
        disk|storage)
            if [[ ${#metrics[@]} -eq 1 ]]; then
                disk_stats=$(df -hP \
                    -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs \
                    2>/dev/null | awk 'NR > 1 {
                        usage = $5
                        gsub(/%/, "", usage)
                        printf "%s\t%s\t%s\t%s\n", usage, $3, $2, $6
                    }')
            else
                disk_stats=$(df -hP / 2>/dev/null | awk 'NR == 2 {
                    usage = $5
                    gsub(/%/, "", usage)
                    printf "%s\t%s\t%s\t%s\n", usage, $3, $2, $6
                }')
            fi
            [[ -n "$disk_stats" ]] || {
                printf 'Could not read disk metrics\n' >&2
                exit 1
            }
            while IFS=$'\t' read -r disk_usage disk_used disk_total disk_mount; do
                if [[ ${#metrics[@]} -eq 1 ]]; then
                    disk_primary="${disk_usage}%"
                    ((disk_usage >= 90)) && disk_primary+=" full"
                    format_metric_header DISK \
                        "$disk_primary" \
                        --pair "$disk_used" "/$disk_total" \
                        "$disk_mount" || exit 1
                else
                    printf 'DISK %s%%\n' "$disk_usage"
                fi
            done <<< "$disk_stats"
            ;;
    esac
done
