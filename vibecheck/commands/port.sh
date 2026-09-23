#!/usr/bin/env bash

PROGRAM_NAME="vch"
USAGE="Usage: $PROGRAM_NAME port PORT"

case "${1:-}" in
    help|-h|--help)
        printf '%s\n' "$USAGE"
        exit 0
        ;;
    "")
        printf '%s: a port number is required\n' "$PROGRAM_NAME" >&2
        printf '%s\n' "$USAGE" >&2
        exit 2
        ;;
    *[!0-9]*)
        printf "%s: invalid port '%s'\n" "$PROGRAM_NAME" "$1" >&2
        exit 2
        ;;
esac

if [[ $# -gt 1 ]]; then
    printf '%s: port accepts exactly one argument\n' "$PROGRAM_NAME" >&2
    printf '%s\n' "$USAGE" >&2
    exit 2
fi

port="$1"

result=$(lsof -i ":$port" -t 2>/dev/null | head -1)
if [[ -n "$result" ]]; then
    ps -p "$result" -o pid=,comm= | awk '{printf "PID %s: %s\n", $1, $2}'
else
    echo "Literally nothing on :$port"
fi
