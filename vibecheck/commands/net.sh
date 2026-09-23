#!/usr/bin/env bash

_net_latency() {
    ping -c 3 -q 1.1.1.1 2>/dev/null | awk -F'/' '/rtt/ {printf "%.0fms", $5}'
}

_net_dns() {
    local start end
    start=$(date +%s%3N)
    if nslookup google.com &>/dev/null 2>&1 || host google.com &>/dev/null 2>&1; then
        end=$(date +%s%3N)
        echo "ok ($((end - start))ms)"
    else
        echo "fail"
    fi
}

_net_download() {
    local bps
    bps=$(curl -o /dev/null -s -w "%{speed_download}" \
        "https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null)
    [[ -n "$bps" && "$bps" != "0.000" ]] \
        && awk "BEGIN {printf \"%.1f Mbps\", $bps * 8 / 1000000}" \
        || echo "n/a"
}

_net_upload() {
    local tmp bps
    tmp=$(mktemp)
    dd if=/dev/zero of="$tmp" bs=1M count=10 2>/dev/null
    bps=$(curl -s -o /dev/null -w "%{speed_upload}" \
        --data-binary @"$tmp" "https://speed.cloudflare.com/__up" 2>/dev/null)
    rm -f "$tmp"
    [[ -n "$bps" && "$bps" != "0.000" ]] \
        && awk "BEGIN {printf \"%.1f Mbps\", $bps * 8 / 1000000}" \
        || echo "n/a"
}

latency=$(_net_latency)

if [[ -z "$latency" ]]; then
    printf "NET down\n"
    exit 0
fi

printf "NET up (%s)\n" "$latency"
printf "DNS    %s\n" "$(_net_dns)"
printf "↓      %s\n" "$(_net_download)"
printf "↑      %s\n" "$(_net_upload)"
