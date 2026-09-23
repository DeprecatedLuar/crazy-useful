#!/usr/bin/env bash
# serve — quick LAN file sharing
#
# usage:
#   serve                     serve all files in current directory
#   serve file1 file2 ...     serve specific files
#   serve ./folder            serve a folder as a zip

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
PORT=8080
TUNNEL=false
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB_DIR="$SCRIPT_DIR"
TEMPLATE="$LIB_DIR/share.html"
source "$SCRIPT_DIR/../lib/net.sh"
SERVE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/serve.XXXXXX")

# ── cleanup on exit ───────────────────────────────────────────────────────────
cleanup() {
  rm -rf "$SERVE_DIR"
  if [[ "$TUNNEL" == true ]]; then
    source "$LIB_DIR/tunnel.sh"
    stop_tunnel
  fi
}
trap cleanup EXIT

# ── helpers ───────────────────────────────────────────────────────────────────

human_size() {
  local file="$1"
  local bytes
  bytes=$(wc -c < "$file")
  if   (( bytes < 1024 ));       then echo "${bytes} B"
  elif (( bytes < 1048576 ));    then printf "%d KB" $(( bytes / 1024 ))
  elif (( bytes < 1073741824 )); then printf "%d MB" $(( bytes / 1048576 ))
  else                                printf "%d GB" $(( bytes / 1073741824 ))
  fi
}

file_icon() {
  local ext="${1##*.}"
  case "${ext,,}" in
    mp3|wav|flac|ogg|aac|m4a) echo "♪" ;;
    mp4|mkv|avi|mov|webm)     echo "▶" ;;
    png|jpg|jpeg|gif|webp|svg) echo "◫" ;;
    pdf)                       echo "▣" ;;
    zip|tar|gz|bz2|xz|7z)    echo "⊞" ;;
    md|txt|log|csv)            echo "≡" ;;
    sh|bash|zsh|py|js|ts|go)  echo "λ" ;;
    *)                         echo "·" ;;
  esac
}

usage() {
  cat <<EOF
serve — quick LAN file sharing

usage:
  serve                      serve all files in current directory
  serve <file> [file...]     serve specific files
  serve <folder>             serve folder as zip

options:
  -p <port>                  port (default: 8080)
  -t, --tunnel               expose via cloudflare tunnel (internet access)
  -h                         show this help
EOF
  exit 0
}

# ── args ──────────────────────────────────────────────────────────────────────
FILES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      PORT="$2"
      shift 2
      ;;
    -t|--tunnel)
      TUNNEL=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

# Restore positional parameters from FILES array
set -- "${FILES[@]}"

# ── no-args: expand to all files in cwd ───────────────────────────────────────
if [[ $# -eq 0 ]]; then
  set -- *
fi

# ── get local IP ──────────────────────────────────────────────────────────────
LOCAL_IP=$(local_ip)
[[ -z "$LOCAL_IP" ]] && LOCAL_IP="localhost"

# ── build file list ───────────────────────────────────────────────────────────
FILE_LIST_HTML=""
FILE_COUNT=0

for f in "$@"; do
  if [[ ! -e "$f" ]]; then
    echo "warning: '$f' not found, skipping" >&2
    continue
  fi

  REALPATH="$(realpath "$f")"
  FILENAME="$(basename "$REALPATH")"

  # zip directories on the fly
  if [[ -d "$REALPATH" ]]; then
    FILENAME="${FILENAME}.zip"
    echo -n "  · zipping $(basename "$REALPATH")..." >&2
    (cd "$(dirname "$REALPATH")" && zip -rq "$SERVE_DIR/$FILENAME" "$(basename "$REALPATH")")
    echo " done" >&2
  else
    cp "$REALPATH" "$SERVE_DIR/$FILENAME"
  fi

  SIZE=$(human_size "$SERVE_DIR/$FILENAME")
  ICON=$(file_icon "$FILENAME")

  FILE_LIST_HTML+="    <li class=\"file-item\">
      <span class=\"file-icon\">${ICON}</span>
      <span class=\"file-name\">${FILENAME}</span>
      <span class=\"file-size\">${SIZE}</span>
      <a class=\"file-dl\" href=\"/${FILENAME}\" download>↓</a>
    </li>
"
  (( FILE_COUNT++ )) || true
done

if [[ $FILE_COUNT -eq 0 ]]; then
  echo "error: no valid files to serve" >&2
  exit 1
fi

FILE_COUNT_LABEL="${FILE_COUNT} file$( [[ $FILE_COUNT -ne 1 ]] && echo 's' || true )"

# ── inject into template ──────────────────────────────────────────────────────
HTML=$(< "$TEMPLATE")
HTML="${HTML//\{\{FILE_COUNT\}\}/$FILE_COUNT_LABEL}"
HTML="${HTML//\{\{IP_PORT\}\}/${LOCAL_IP}:${PORT}}"
HTML="${HTML//\{\{FILE_LIST\}\}/$FILE_LIST_HTML}"

echo "$HTML" > "$SERVE_DIR/index.html"

# ── start tunnel if requested ─────────────────────────────────────────────────
PUBLIC_URL=""
if [[ "$TUNNEL" == true ]]; then
  source "$LIB_DIR/tunnel.sh"
  echo ""
  echo "  · starting cloudflare tunnel..." >&2
  PUBLIC_URL=$(start_tunnel "$PORT") || {
    echo "error: tunnel failed to start" >&2
    exit 1
  }
fi

# ── print info ────────────────────────────────────────────────────────────────
echo ""
for served in "$SERVE_DIR"/*; do
  [[ "$(basename "$served")" == "index.html" ]] && continue
  printf "  %-40s %s\n" "$(basename "$served")" "$(human_size "$served")"
done
echo ""
echo "  ↗  http://${LOCAL_IP}:${PORT}"
if [[ -n "$PUBLIC_URL" ]]; then
  echo "  ⇢  $PUBLIC_URL"
fi
echo ""

# ── start server ─────────────────────────────────────────────────────────────
command -v python3 &>/dev/null || { echo "python3 not found" >&2; exit 1; }
cd "$SERVE_DIR"
python3 -m http.server "$PORT" --bind 0.0.0.0 2>/dev/null
