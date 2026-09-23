#!/usr/bin/env bash
# evres — consume files from a serve instance (serve, backwards)
#
# usage:
#   evres .13              connect to 192.168.1.13:8080
#   evres .13:9000         custom port
#   evres 192.168.1.13     full IP, default port
#   evres <ip> --all       download everything non-interactively

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/../lib/net.sh"

PORT=8080
ALL=false

# ── helpers ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
evres — consume files from a serve instance

usage:
  evres .13              192.168.1.13:8080
  evres .13:9000         192.168.1.13:9000
  evres 192.168.1.13     full IP, default port 8080
  evres <ip> -a          download everything

options:
  -p <port>    port (default: 8080)
  -a / --all   download all files without prompting
  -h           show this help
EOF
  exit 0
}

# .13 or .13:9000 → full IP, sets PORT as side effect
normalize_host() {
  local input="$1"

  if [[ "$input" =~ :([0-9]+)$ ]]; then
    PORT="${BASH_REMATCH[1]}"
    input="${input%:*}"
  fi

  expand_local_ip "$input"
}

# ── args ──────────────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

HOST_RAW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PORT="$2"; shift 2 ;;
    -a|--all) ALL=true; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) HOST_RAW="$1"; shift ;;
  esac
done

[[ -z "$HOST_RAW" ]] && { echo "error: no host specified" >&2; usage; }

HOST=$(normalize_host "$HOST_RAW")
BASE="http://${HOST}:${PORT}"

echo ""
echo "  → $BASE"

# ── fetch listing ─────────────────────────────────────────────────────────────
HTML=$(curl -sf --connect-timeout 5 "$BASE/" 2>/dev/null) || {
  echo "  error: could not reach $BASE" >&2
  exit 1
}

mapfile -t NAMES < <(echo "$HTML" | grep -oP '(?<=class="file-name">)[^<]+')
mapfile -t SIZES < <(echo "$HTML" | grep -oP '(?<=class="file-size">)[^<]+')

declare -A FILE_SIZE
for i in "${!NAMES[@]}"; do
  FILE_SIZE["${NAMES[$i]}"]="${SIZES[$i]:-}"
done

if [[ ${#NAMES[@]} -eq 0 ]]; then
  echo "  error: no files found (is this a serve instance?)" >&2
  exit 1
fi

# ── display ───────────────────────────────────────────────────────────────────
echo ""
for i in "${!NAMES[@]}"; do
  printf "  [%d] %-40s %s\n" "$((i+1))" "${NAMES[$i]}" "${SIZES[$i]:-}"
done
echo ""

# ── select ────────────────────────────────────────────────────────────────────
declare -a SELECTED

if $ALL; then
  SELECTED=("${NAMES[@]}")
else
  printf "  pick: "
  read -r PICK

  [[ -z "$PICK" ]] && { echo "  cancelled"; exit 0; }

  for token in $PICK; do
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      idx=$(( token - 1 ))
      [[ -n "${NAMES[$idx]:-}" ]] && SELECTED+=("${NAMES[$idx]}")
    fi
  done
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  echo "  nothing selected, exiting"
  exit 0
fi

# ── download ──────────────────────────────────────────────────────────────────
echo ""
total=${#SELECTED[@]}
for i in "${!SELECTED[@]}"; do
  name="${SELECTED[$i]}"
  printf "  ↓ [%d/%d] %s (%s)\n" "$((i+1))" "$total" "$name" "${FILE_SIZE[$name]:-}"
  curl -f --progress-bar -O "$BASE/$name"
done

echo ""
echo "  ${#SELECTED[@]} file(s) → $(pwd)"
echo ""
