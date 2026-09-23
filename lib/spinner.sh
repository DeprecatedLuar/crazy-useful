#!/usr/bin/env bash
# spinner.sh - dots progress spinner for background PIDs
# Usage: spin "Label" $PID [interval]

spin() {
    local label="$1" pid="$2" interval="${3:-0.3}"
    local dots=""
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%s%-3s" "$label" "$dots"
        dots="${dots}."
        [[ ${#dots} -gt 3 ]] && dots=""
        sleep "$interval"
    done
    printf "\r\033[K"
}
