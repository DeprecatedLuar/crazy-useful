#!/usr/bin/env bash

LIB_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
CMD_DIR="$LIB_DIR/commands"
METRIC_COLUMN_COUNT=3
METRIC_DETAIL_COLUMN=3
FORMAT_METRICS=(
    "$LIB_DIR/format/columns.sh"
    --columns "$METRIC_COLUMN_COUNT"
    --dim "$METRIC_DETAIL_COLUMN"
)

case "${1:-}" in
    help|-h|--help)
        "$CMD_DIR/help.sh"
        ;;
    tray)
        "$CMD_DIR/tray.sh"
        ;;
    ports|--ports)
        shift
        "$CMD_DIR/ports.sh" "$@"
        ;;
    port|--port)
        shift
        "$CMD_DIR/port.sh" "$@"
        ;;
    :*)
        port="${1#:}"
        "$CMD_DIR/port.sh" "$port"
        ;;
    cpu)
        "$LIB_DIR/get-system-metrics.sh" "$@"
        ;;
    ram|gpu|igpu|dgpu|fan|fans|bat)
        "$LIB_DIR/get-system-metrics.sh" "$@"
        ;;
    disk|storage)
        shift
        if [[ "${1:-}" == reclaim ]]; then
            shift
            "$CMD_DIR/disk-reclaim.sh" "$@"
        else
            "$CMD_DIR/disk.sh" "$@"
        fi
        ;;
    ip)
        "$CMD_DIR/ip.sh"
        ;;
    net|internet)
        "$CMD_DIR/net.sh"
        ;;
    hw|hardware)
        shift
        "$CMD_DIR/hardware.sh" "$@"
        ;;
    "")
        "$LIB_DIR/get-system-metrics.sh" | "${FORMAT_METRICS[@]}"
        ;;
    -*)
        printf "vch: unknown option '%s'\n" "$1" >&2
        printf "Try 'vch --help' for usage.\n" >&2
        exit 2
        ;;
    .|..|~|*/*)
        # Path-shaped arguments are a disk lookup. A bare word stays a process
        # search even when a directory of that name exists, so `vch firefox`
        # never changes meaning based on the current directory.
        "$CMD_DIR/disk.sh" "$@"
        ;;
    *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            output=$("$CMD_DIR/port.sh" "$1" 2>/dev/null)
            if [[ "$output" == "Literally nothing on :"* ]]; then
                if ! "$CMD_DIR/find.sh" -p "$1" 2>/dev/null; then
                    echo "I didn't find anything"
                fi
            else
                echo "$output"
            fi
        else
            output=$("$CMD_DIR/find.sh" "$1" 2>/dev/null)
            if [[ -n "$output" ]]; then
                echo "$output"
            else
                echo "I didn't find anything"
            fi
        fi
        ;;
esac
