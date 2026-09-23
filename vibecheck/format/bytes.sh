#!/usr/bin/env bash
# bytes.sh - sourceable byte formatting shared by disk consumers and reclaim rows
# Usage: source bytes.sh
#   format_bytes 26843545600        ->  26G
#   parse_bytes "1.944GB" 1000      ->  1944000000
#
# Reclaim providers report sizes in whatever unit their owning tool prints, so
# parse_bytes takes the base explicitly: docker humanizes with SI units (1000),
# systemd and coreutils use binary units (1024).

BYTE_UNITS=(B K M G T P)
BYTE_STEP=1024
BYTE_FRACTION_THRESHOLD=10
BYTE_SI_STEP=1000

format_bytes() {
    local bytes="${1:-0}"

    awk -v bytes="$bytes" -v step="$BYTE_STEP" -v threshold="$BYTE_FRACTION_THRESHOLD" '
        BEGIN {
            split("'"${BYTE_UNITS[*]}"'", units, " ")
            unit = 1
            while (bytes >= step && unit < length(units)) {
                bytes /= step
                unit++
            }
            if (unit == 1)
                printf "%d%s\n", bytes, units[unit]
            else if (bytes < threshold)
                printf "%.1f%s\n", bytes, units[unit]
            else
                printf "%.0f%s\n", bytes, units[unit]
        }'
}

parse_bytes() {
    local size="${1:-0}" base="${2:-$BYTE_STEP}"

    awk -v size="$size" -v base="$base" '
        BEGIN {
            if (match(size, /^[0-9.]+/) == 0) { print 0; exit }
            value = substr(size, 1, RLENGTH) + 0
            unit = substr(size, RLENGTH + 1)
            sub(/[iI]?[bB]$/, "", unit)

            power = index("BKMGTP", toupper(substr(unit, 1, 1))) - 1
            if (power < 0) power = 0
            for (i = 0; i < power; i++) value *= base
            printf "%d\n", value
        }'
}
