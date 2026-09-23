#!/usr/bin/env bash
# Toggle CPU turbo boost
# Usage: turbo [on|off]  — explicit; no args = toggle

TURBO_FILE="/sys/devices/system/cpu/intel_pstate/no_turbo"

turbo_on() {
  sudo systemctl stop auto-cpufreq
  if systemctl is-active --quiet auto-cpufreq; then
    echo "Error: failed to stop auto-cpufreq" >&2; return 1
  fi
  echo 0 | sudo tee "$TURBO_FILE" > /dev/null
  vibecheck
}

turbo_off() {
  echo 1 | sudo tee "$TURBO_FILE" > /dev/null
  sudo systemctl start auto-cpufreq
  if ! systemctl is-active --quiet auto-cpufreq; then
    echo "Error: failed to start auto-cpufreq" >&2; return 1
  fi
  vibecheck
}

case "${1:-}" in
  on)  turbo_on ;;
  off) turbo_off ;;
  *)   echo "Usage: turbo on|off" ;;
esac
