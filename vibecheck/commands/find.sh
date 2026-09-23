#!/usr/bin/env bash

if [[ "$1" == "-p" ]]; then
    pid="$2"
    if [[ -z "$pid" ]]; then
        echo "Usage: find.sh -p <pid>"
        exit 1
    fi

    if ps -p "$pid" &>/dev/null; then
        comm=$(ps -p "$pid" -o comm= 2>/dev/null)
        cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs | awk '{printf "%.0f", $1}')
        mem=$(ps -p "$pid" -o %mem= 2>/dev/null | xargs | awk '{printf "%.0f", $1}')
        cmd=$(ps -p "$pid" -o args= 2>/dev/null)

        echo "$pid ($comm)"
        echo "CPU ${cpu}% | RAM ${mem}%"
        echo "$cmd"
        exit 0
    else
        exit 1
    fi
else
    name="$1"
    if [[ -z "$name" ]]; then
        echo "Usage: find.sh <process_name>"
        exit 1
    fi

    # Try process name first (fast)
    pids=$(pgrep -i "$name")

    # Fallback to full command line search (exclude self and search processes)
    if [[ -z "$pids" ]]; then
        pids=$(pgrep -f "$name" | while read -r pid; do
            cmd=$(ps -p "$pid" -o args= 2>/dev/null)
            # Filter out vch/find.sh/pgrep search commands
            if [[ ! "$cmd" =~ (vch|find\.sh|pgrep).*"$name" ]]; then
                echo "$pid"
            fi
        done)
    fi

    # Keep fzf fallback for edge cases
    if [[ -z "$pids" ]]; then
        pids=$(ps -eo pid,comm --no-headers | fzf --filter="$name" -1 | awk '{print $1}')
    fi

    if [[ -n "$pids" ]]; then
        echo "$pids" | while read -r pid; do
            comm=$(ps -p "$pid" -o comm= 2>/dev/null)

            # If it's a script wrapper, extract the script name
            if [[ "$comm" =~ ^(bash|sh|python|python3|node|ruby|perl)$ ]]; then
                script=$(ps -p "$pid" -o args= 2>/dev/null | awk '{print $2}' | xargs basename)
                [[ -n "$script" ]] && echo "$script [$comm] ($pid)" || echo "$comm ($pid)"
            else
                [[ -n "$comm" ]] && echo "$comm ($pid)"
            fi
        done
    fi

    exit 0
fi
