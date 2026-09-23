#!/usr/bin/env bash

mapfile -t iface_ips < <(ip -4 addr show scope global | awk '
    /^[0-9]+:/ { iface = $2; gsub(/:/, "", iface) }
    /inet /    { ip = $2; gsub(/\/.*/, "", ip); if (ip != "") print iface " " ip }
')
public_ip=$(curl -sf --max-time 3 https://ifconfig.me 2>/dev/null || echo "n/a")
maxlen=6  # length of "Public"
for entry in "${iface_ips[@]}"; do
    iface="${entry%% *}"
    (( ${#iface} > maxlen )) && maxlen=${#iface}
done
for entry in "${iface_ips[@]}"; do
    printf "%-*s %s\n" "$maxlen" "${entry%% *}" "${entry##* }"
done
printf "%-*s %s\n" "$maxlen" "Public" "$public_ip"
