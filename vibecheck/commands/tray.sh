#!/usr/bin/env bash

items=$(gdbus call --session \
    --dest org.kde.StatusNotifierWatcher \
    --object-path /StatusNotifierWatcher \
    --method org.freedesktop.DBus.Properties.Get \
    org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "Error: StatusNotifierWatcher not available"
    exit 1
fi

echo "$items" | sed "s/^<(//; s/)>,$//" | grep -oP "'[^']+'" | tr -d "'" | while read -r item; do
    bus_name=$(echo "$item" | cut -d'/' -f1)
    obj_path=$(echo "$item" | cut -d'/' -f2-)
    obj_path="/$obj_path"

    title=$(gdbus call --session \
        --dest "$bus_name" \
        --object-path "$obj_path" \
        --method org.freedesktop.DBus.Properties.Get \
        org.kde.StatusNotifierItem Title 2>/dev/null | \
        grep -oP "'\K[^']+(?=')")

    if [ -z "$title" ]; then
        title=$(gdbus call --session \
            --dest "$bus_name" \
            --object-path "$obj_path" \
            --method org.freedesktop.DBus.Properties.Get \
            org.kde.StatusNotifierItem Id 2>/dev/null | \
            grep -oP "'\K[^']+(?=')")
    fi

    pid=$(gdbus call --session \
        --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetConnectionUnixProcessID \
        "$bus_name" 2>/dev/null | grep -oP '\d+(?=,\))')

    if [ -z "$title" ] || [[ "$title" =~ ^(chrome_status_icon|:1\.) ]]; then
        if [ -n "$pid" ]; then
            cmdline=$(ps -p "$pid" -o args= 2>/dev/null)

            if [[ "$cmdline" =~ /usr/lib/([^/]+)/ ]]; then
                title="${BASH_REMATCH[1]}"
            elif [[ "$cmdline" =~ /([^/]+)/app\.asar ]]; then
                title="${BASH_REMATCH[1]}"
            else
                proc_name=$(ps -p "$pid" -o comm= 2>/dev/null)
                if [ -n "$proc_name" ] && [ "$proc_name" != "electron" ] && [ "$proc_name" != "xdg-dbus-proxy" ]; then
                    title="$proc_name"
                fi
            fi
        fi
    fi

    [ -z "$title" ] && title="$bus_name"

    if [ -n "$pid" ]; then
        echo "$title ($pid)"
    else
        echo "$title"
    fi
done
