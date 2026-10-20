#!/usr/bin/env bash
# hzless: CPU frequency and power limit control. Each command prints its usage with no args,
# shows state with `status`, and sets it with other subcommands.

SELF=$(realpath "${BASH_SOURCE[0]}")
readonly SELF
readonly HZLESS_DIR="${SELF%/*}"
readonly -a ARGS=("$@")

readonly USAGE="usage: hzless <command> [help]
  status       show freq, turbo, power limits
  freq         frequency caps
  turbo        turbo boost
  pl           power limits
  pl1 | pl2    set one power limit
  profile      system power profile (power-saver, balanced, performance)
  preset       save and apply state snapshots"

# shellcheck source=shared.sh
source "$HZLESS_DIR/shared.sh"
# shellcheck source=freq.sh
source "$HZLESS_DIR/freq.sh"
# shellcheck source=turbo.sh
source "$HZLESS_DIR/turbo.sh"
# shellcheck source=pl.sh
source "$HZLESS_DIR/pl.sh"
# shellcheck source=profile.sh
source "$HZLESS_DIR/profile.sh"
# shellcheck source=preset.sh
source "$HZLESS_DIR/preset.sh"
# shellcheck source=status.sh
source "$HZLESS_DIR/status.sh"

main() {
  if is_help "$@"; then
    echo "$USAGE"
    return
  fi
  local command=$1
  shift
  case $command in
    status) cmd_status "$@" ;;
    freq) cmd_freq "$@" ;;
    turbo) cmd_turbo "$@" ;;
    pl) cmd_pl "$@" ;;
    pl1|pl2) cmd_pl_one "$command" "$@" ;;
    profile) cmd_profile "$@" ;;
    preset) cmd_preset "$@" ;;
    *) usage_error "$USAGE" "unknown command '$command'" ;;
  esac
}

main "$@"
