#!/usr/bin/env bash

REQUIRE_DEPS="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../lib/require-deps.sh"
EMPTY_SLOT_MARKER="No Module Installed"
DMIDECODE_MEMORY_TYPE=17
SUDO_HINT="for more info try with sudo"
DIM_STYLE=$'\e[2m'
RESET_STYLE=$'\e[0m'

# Prints one "slot|size|type|speed|vendor" line per populated memory stick.
parse_memory_devices() {
    awk -F': ' -v empty="$EMPTY_SLOT_MARKER" '
        function flush() {
            if (size != "" && size != empty)
                printf "%s|%s|%s|%s|%s\n", slot, size, type, speed, vendor
            size = slot = type = speed = vendor = ""
        }
        /^Memory Device/ { flush() }
        /^\tSize:/ { size = $2 }
        /^\tLocator:/ { slot = $2 }
        /^\tType:/ { type = $2 }
        /^\tConfigured (Memory|Clock) Speed:/ { speed = $2 }
        /^\tManufacturer:/ { vendor = $2 }
        END { flush() }
    '
}

components=("$@")
[[ ${#components[@]} -eq 0 ]] && components=(machine cpu ram gpu disk)

if [[ " ${components[*]} " == *" ram "* ]]; then
    source "$REQUIRE_DEPS"
    require_deps dmidecode -- "$0" "$@"
fi

for component in "${components[@]}"; do
    case "$component" in
        machine)
            dmi=/sys/class/dmi/id
            sys_vendor=$(cat "$dmi/sys_vendor" 2>/dev/null)
            product=$(cat "$dmi/product_name" 2>/dev/null)
            product_ver=$(cat "$dmi/product_version" 2>/dev/null)
            board_vendor=$(cat "$dmi/board_vendor" 2>/dev/null)
            board=$(cat "$dmi/board_name" 2>/dev/null)

            if [[ -n "$product" && "$product" != "To Be Filled By O.E.M." && "$product" != "None" ]]; then
                label="${sys_vendor:+$sys_vendor }$product${product_ver:+ $product_ver}"
                printf "Machine: %s\n" "$label"
            fi
            if [[ -n "$board" && "$board" != "To Be Filled By O.E.M." && "$board" != "None" ]]; then
                printf "Board: %s%s\n" "${board_vendor:+$board_vendor }" "$board"
            fi
            ;;
        cpu)
            model=$(LC_ALL=C lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2}')
            cores=$(LC_ALL=C lscpu | awk -F: '/^Core\(s\) per socket/ {gsub(/^[ \t]+/, "", $2); print $2}')
            threads=$(LC_ALL=C lscpu | awk -F: '/^CPU\(s\):/ {gsub(/^[ \t]+/, "", $2); print $2}')
            freq=$(LC_ALL=C lscpu | awk -F: '/CPU max MHz/ {gsub(/^[ \t]+/, "", $2); printf "%.1f", $2/1000}')
            [[ -z "$freq" ]] && freq=$(LC_ALL=C lscpu | awk -F: '/CPU MHz/ {gsub(/^[ \t]+/, "", $2); printf "%.1f", $2/1000}')
            [[ -n "$model" ]] && printf "CPU: %s (%s cores / %s threads @ %sGHz)\n" "$model" "$cores" "$threads" "$freq"
            ;;
        ram)
            total=$(LC_ALL=C free -h | awk '/^Mem:/ {print $2}')
            if ! raw=$(LC_ALL=C sudo -n "$(command -v dmidecode)" -t "$DMIDECODE_MEMORY_TYPE" 2>/dev/null); then
                printf "RAM: %s\n" "$total"
                if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
                    printf "%s%s%s\n" "$DIM_STYLE" "$SUDO_HINT" "$RESET_STYLE" >&2
                else
                    printf "%s\n" "$SUDO_HINT" >&2
                fi
                continue
            fi
            mapfile -t sticks < <(parse_memory_devices <<<"$raw")
            printf "RAM: %s (%d stick%s)\n" "$total" "${#sticks[@]}" "$([[ ${#sticks[@]} -eq 1 ]] || echo s)"
            for stick in "${sticks[@]}"; do
                IFS='|' read -r slot size type speed vendor <<<"$stick"
                printf "  %s: %s %s%s%s\n" "$slot" "$size" "$type" "${speed:+ @ $speed}" "${vendor:+ ($vendor)}"
            done
            ;;
        gpu)
            # All GPUs via lspci (most reliable)
            while read -r gpu; do
                [[ -n "$gpu" ]] && printf "GPU: %s\n" "$(echo "$gpu" | sed 's/.*: //')"
            done < <(lspci | grep -i 'vga\|3d\|display')
            ;;
        disk)
            lsblk -d -o NAME,SIZE,MODEL --noheadings 2>/dev/null | while read -r name size model; do
                [[ "$name" == loop* || "$name" == zram* ]] && continue
                [[ -z "$model" ]] && model="(unknown)"
                printf "DISK: /dev/%s %s %s\n" "$name" "$size" "$model"
            done
            ;;
    esac
done
