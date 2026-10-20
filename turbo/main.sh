#!/usr/bin/env bash
# Toggle CPU turbo boost
# Usage: turbo on|off|status

TURBO_FILE="/sys/devices/system/cpu/intel_pstate/no_turbo"
GOVERNOR_SERVICE="auto-cpufreq"

turbo_on() {
  sudo systemctl stop "$GOVERNOR_SERVICE"
  if systemctl is-active --quiet "$GOVERNOR_SERVICE"; then
    echo "Error: failed to stop $GOVERNOR_SERVICE" >&2; return 1
  fi
  echo 0 | sudo tee "$TURBO_FILE" > /dev/null
  vibecheck
}

turbo_off() {
  echo 1 | sudo tee "$TURBO_FILE" > /dev/null
  sudo systemctl start "$GOVERNOR_SERVICE"
  if ! systemctl is-active --quiet "$GOVERNOR_SERVICE"; then
    echo "Error: failed to start $GOVERNOR_SERVICE" >&2; return 1
  fi
  vibecheck
}

turbo_status() {
  if [[ ! -r "$TURBO_FILE" ]]; then
    echo "Error: cannot read $TURBO_FILE" >&2; return 1
  fi
  local no_turbo
  no_turbo=$(<"$TURBO_FILE")
  case "$no_turbo" in
    0) echo "Turbo: on" ;;
    1) echo "Turbo: off" ;;
    *) echo "Error: unexpected value '$no_turbo' in $TURBO_FILE" >&2; return 1 ;;
  esac
  echo "$GOVERNOR_SERVICE: $(systemctl is-active "$GOVERNOR_SERVICE")"
}

case "${1:-}" in
  on)     turbo_on ;;
  off)    turbo_off ;;
  status) turbo_status ;;
  *)      echo "Usage: turbo on|off|status" ;;
esac
