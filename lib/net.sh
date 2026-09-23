#!/usr/bin/env bash
# net.sh — local network utilities

# Get primary local IP via default route (most reliable)
# Falls back to hostname -I, then ifconfig
local_ip() {
    local ip

    # ip route get 1: asks "what source IP would I use to reach 1.1.1.1?"
    # follows the actual default route, unambiguous on multi-interface systems
    ip=$(ip route get 1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    [[ -n "$ip" ]] && echo "$ip" && return

    # fallback: hostname -I (first IP listed)
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" && "$ip" != "127.0.0.1" ]] && echo "$ip" && return

    # fallback: ifconfig (macOS / minimal systems)
    ip=$(ifconfig 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2; exit}')
    [[ -n "$ip" ]] && echo "$ip" && return

    return 1
}

# Expand .N shorthand to full local subnet IP
# .17 → 192.168.1.17 (or whatever subnet you're on)
expand_local_ip() {
    local input="$1"
    [[ "$input" != .* ]] && echo "$input" && return

    local ip
    ip=$(local_ip) || { echo "error: could not detect local IP" >&2; return 1; }
    echo "${ip%.*}${input}"
}
