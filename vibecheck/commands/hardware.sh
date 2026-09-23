#!/usr/bin/env bash

components=("$@")
[[ ${#components[@]} -eq 0 ]] && components=(machine cpu ram gpu disk)

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
            # Try to get RAM type/speed (works without sudo on some systems)
            speed=$(cat /sys/devices/system/memory/*/speed 2>/dev/null | head -1)
            if [[ -n "$speed" ]]; then
                printf "RAM: %s @ %sMHz\n" "$total" "$speed"
            else
                printf "RAM: %s\n" "$total"
            fi
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
