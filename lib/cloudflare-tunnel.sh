#!/usr/bin/env bash
# cloudflare-tunnel.sh — shared Cloudflare Quick Tunnel plumbing

# Ensure cloudflared is installed
ensure_cloudflared() {
  if command -v cloudflared &>/dev/null; then
    return 0
  fi

  echo "  · cloudflared not found, installing..." >&2

  # Redirect the installer's stdout to stderr: this function is called from
  # inside start_quick_tunnel, which itself runs under a $(...) capture in
  # hack.sh — any stdout the installer emits would otherwise be swallowed
  # into the captured tunnel URL and corrupt the printed connect line.
  curl -sSL "https://raw.githubusercontent.com/DeprecatedLuar/the-satellite/main/satellite.sh" | \
    bash -s -- install cloudflare/cloudflared >&2 || {
    echo "error: failed to install cloudflared" >&2
    return 1
  }

  if ! command -v cloudflared &>/dev/null; then
    echo "error: cloudflared installed but not found in PATH" >&2
    return 1
  fi
}

# Start a Cloudflare Quick Tunnel and print the public URL.
# Usage: start_quick_tunnel <local-url> <pidfile>
#   local-url — e.g. http://localhost:8080 or ssh://localhost:22
#   pidfile   — where to record the cloudflared PID for stop_quick_tunnel
start_quick_tunnel() {
  local local_url="$1" pid_file="$2"
  local url_file tunnel_pid

  ensure_cloudflared || return 1

  url_file=$(mktemp "${TMPDIR:-/tmp}/cloudflare-tunnel-url.XXXXXX")

  # Keep the tunnel out of the caller's terminal process group. Otherwise a
  # Ctrl-C intended for an interactive wrapper also kills cloudflared before
  # the wrapper can handle it.
  setsid cloudflared tunnel --url "$local_url" > "$url_file" 2>&1 &
  tunnel_pid=$!
  echo "$tunnel_pid" > "$pid_file"

  local waited=0
  local public_url=""

  while [[ $waited -lt 40 ]]; do
    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
      echo "error: cloudflared process died" >&2
      cat "$url_file" >&2
      rm -f "$url_file"
      return 1
    fi

    if grep -qE "https://[a-z0-9-]+\.trycloudflare\.com" "$url_file"; then
      public_url=$(grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" "$url_file" | head -1)
      break
    fi

    sleep 0.5
    waited=$((waited + 1))
  done

  if [[ -z "$public_url" ]]; then
    echo "error: failed to get tunnel URL after ${waited} attempts" >&2
    echo "cloudflared output:" >&2
    cat "$url_file" >&2
    rm -f "$url_file"
    kill "$tunnel_pid" 2>/dev/null || true
    return 1
  fi

  rm -f "$url_file"
  echo "$public_url"
}

# Stop a tunnel started with start_quick_tunnel.
# Usage: stop_quick_tunnel <pidfile>
stop_quick_tunnel() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file")
    kill "$pid" 2>/dev/null || true
    rm -f "$pid_file"
  fi
}
