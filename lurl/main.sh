#!/usr/bin/env bash
# bin/curl - intelligent curl wrapper with auto-pretty-printing

# Find real curl (skip ourselves)
_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CURL_BIN=$(type -a curl 2>/dev/null | awk '{print $NF}' | grep -vF "$_SELF_DIR/" | head -1)
[[ -z "$CURL_BIN" ]] && { echo "curl: could not find system curl" >&2; exit 1; }

# Check for jq dependency
if ! command -v jq &>/dev/null; then
    echo "Warning: jq not found, pretty-printing disabled" >&2
    exec "$CURL_BIN" "$@"
fi

# Parse args and detect bypass conditions
raw_mode=false
skip_jq=false
curl_args=()

for arg in "$@"; do
    case "$arg" in
        --raw)
            raw_mode=true
            ;;
        -o|--output|-O)      # File output
            skip_jq=true
            curl_args+=("$arg")
            ;;
        -N|--no-buffer)      # Streaming mode
            skip_jq=true
            curl_args+=("$arg")
            ;;
        *)
            curl_args+=("$arg")
            ;;
    esac
done

# Passthrough mode (no buffering/formatting)
if [[ "$raw_mode" == true ]] || [[ "$skip_jq" == true ]]; then
    exec "$CURL_BIN" "${curl_args[@]}"
fi

# Capture output and try to format as JSON
output=$("$CURL_BIN" "${curl_args[@]}")
exit_code=$?

if [[ $exit_code -eq 0 ]] && echo "$output" | jq -e . >/dev/null 2>&1; then
    # Pastel colors: null:false:true:numbers:strings:arrays:objects:keys
    echo "$output" | JQ_COLORS="2;37:0;91:0;92:0;94:0;95:0;36:0;36:1;96" jq -C
else
    echo "$output"
    exit $exit_code
fi
