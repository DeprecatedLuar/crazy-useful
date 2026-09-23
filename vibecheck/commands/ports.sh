#!/usr/bin/env bash

PROGRAM_NAME="vch"
USAGE="Usage: $PROGRAM_NAME ports [--all] [--ip]"
LIB_DIR="$(dirname "$0")/.."
PORT_COLUMN=1
PORT_COLUMN_WIDTH=5
PORTS_COLUMN_COUNT=3

show_addr=false
want_all=false
for arg in "$@"; do
    case "$arg" in
        --all|-a) want_all=true ;;
        --ip|-i) show_addr=true ;;
        help|-h|--help)
            printf '%s\n' "$USAGE"
            exit 0
            ;;
        *)
            printf "%s ports: unknown option '%s'\n" "$PROGRAM_NAME" "$arg" >&2
            printf '%s\n' "$USAGE" >&2
            exit 2
            ;;
    esac
done

# --all/-a shows root-owned (system) services, which requires sudo
if $want_all && [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# docker-proxy listens on behalf of containers, so lsof/ps only ever show the
# truncated "docker-pr" command name — resolve it back to the container.
docker_ports=""
if command -v docker >/dev/null 2>&1; then
    docker_ports=$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null)
fi

resolve_docker_name() {
    local port="$1"
    [[ -z "$docker_ports" ]] && return
    awk -F'\t' -v p=":${port}->" '$2 ~ p { print $1; exit }' <<< "$docker_ports"
}

rows=$(lsof -i -P -n | awk 'NR>1 && /LISTEN/ {
    n = split($9, a, ":")
    port = a[n]
    addr = substr($9, 1, length($9) - length(port) - 1)
    gsub(/^\[|\]$/, "", addr)
    if (addr == "*" || addr == "") addr = "0.0.0.0"

    key = port SUBSEP $1
    if (!(key in seen)) {
        seen[key] = 1
        order[++n_order] = key
        portof[key] = port
        procof[key] = $1
    }
    if (!((key SUBSEP addr) in addr_seen)) {
        addr_seen[key SUBSEP addr] = 1
        addrs[key] = (addrs[key] == "" ? addr : addrs[key] "," addr)
    }
}
END {
    for (i = 1; i <= n_order; i++) {
        k = order[i]
        print portof[k], procof[k], addrs[k]
    }
}' | sort -n -k1,1)

# Resolve Docker proxy names, then hand the rows to the shared formatter.
while read -r port proc addr; do
    [[ -n "$port" && -n "$proc" ]] || continue
    if [[ "$proc" == "docker-pr" ]]; then
        name=$(resolve_docker_name "$port")
        [[ -n "$name" ]] && proc="$name"
    fi
    if $show_addr; then
        printf '%s %s %s\n' "$port" "($proc)" "$addr"
    else
        printf '%s %s\n' "$port" "($proc)"
    fi
done <<< "$rows" | "$LIB_DIR/format/columns.sh" \
    --columns "$PORTS_COLUMN_COUNT" \
    --right "$PORT_COLUMN" \
    --min-width "$PORT_COLUMN:$PORT_COLUMN_WIDTH"
