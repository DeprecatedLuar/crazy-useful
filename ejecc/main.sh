#!/usr/bin/env bash
# ejecc - Quick USB ejector

set -euo pipefail

EJECT_ALL=false
[[ "${1:-}" == "-a" || "${1:-}" == "--all" ]] && EJECT_ALL=true

MAX_BUSY_PROCS=5
EXCLUDED_PROCS="lsof|awk|ejecc|grep"

# Get device info in one lsblk call using -P (key=value) format
get_device_info() {
    local dev=$1 label="" size="" mp=""
    while IFS= read -r line; do
        [[ -z "$label" && "$line" =~ LABEL=\"([^\"]+)\" ]] && label="${BASH_REMATCH[1]}"
        [[ -z "$size" && "$line" =~ SIZE=\"([^\"]+)\" ]] && size="${BASH_REMATCH[1]}"
        [[ -z "$mp" && "$line" =~ MOUNTPOINT=\"([^\"]+)\" ]] && mp="${BASH_REMATCH[1]}"
    done < <(lsblk -o LABEL,SIZE,MOUNTPOINT -P -n "$dev")
    printf '%s|%s|%s\n' "$label" "$size" "$mp"
}

declare -A labels sizes shortnames mounts
devices=()

while IFS= read -r dev; do
    IFS='|' read -r label size mp < <(get_device_info "$dev")

    # Skip unmounted devices
    [[ -z "$mp" ]] && continue

    devices+=("$dev")
    labels[$dev]="$label"
    sizes[$dev]="$size"
    shortnames[$dev]=$(basename "$dev")
    mounts[$dev]="$mp"
done < <(lsblk -o NAME,TRAN -p -n -l | awk '$2=="usb" {print $1}')

if [[ ${#devices[@]} -eq 0 ]]; then
    echo "No mounted USB found" >&2
    exit 1
fi

name() { echo "${labels[$1]:-USB} ${sizes[$1]} (${shortnames[$1]})"; }

if $EJECT_ALL; then
    selected=("${devices[@]}")
else
    for i in "${!devices[@]}"; do
        echo "$((i+1))) $(name "${devices[$i]}")"
    done
    echo
    read -p "Eject: " -a picks

    selected=()
    for p in "${picks[@]}"; do
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#devices[@]} )); then
            selected+=("${devices[$((p-1))]}")
        fi
    done

    [[ ${#selected[@]} -eq 0 ]] && exit 0
fi

for dev in "${selected[@]}"; do
    mp="${mounts[$dev]}"
    if [[ -n "$mp" && "$PWD" == "$mp"* ]]; then
        echo "cd out of USB first" >&2
        exit 1
    fi
done

sync

ejected=()
for dev in "${selected[@]}"; do
    n=$(name "$dev")
    mp="${mounts[$dev]}"

    failed=0
    while read -r part partmp; do
        [[ -z "$partmp" ]] && continue
        if ! udisksctl unmount -b "$part" --no-user-interaction &>/dev/null; then
            echo "$n busy" >&2
            lsof "$partmp" 2>/dev/null | awk -v excl="$EXCLUDED_PROCS" -v max="$MAX_BUSY_PROCS" '
                NR>1 && !seen[$1,$2]++ && $1 !~ excl { printf "  %s (%s)\n", $1, $2; if(++c>=max) exit }
            ' >&2
            failed=1
            break
        fi
    done < <(lsblk -o NAME,MOUNTPOINT -p -n -l "$dev" | tail -n +2)

    [[ $failed -eq 1 ]] && continue

    if mountpoint -q "$mp" 2>/dev/null; then
        echo "$n failed" >&2
    else
        echo "$n ejected"
        ejected+=("$n")
    fi
done

if [[ ${#ejected[@]} -gt 0 ]]; then
    notify-send -i drive-removable-media "Safe to remove" "$(printf '%s\n' "${ejected[@]}")"
fi
