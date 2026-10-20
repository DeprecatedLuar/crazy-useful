# System power profile through the power-profiles D-Bus API.

readonly PP_BUS="org.freedesktop.UPower.PowerProfiles"
readonly PP_PATH="/org/freedesktop/UPower/PowerProfiles"
readonly PP_PROP="ActiveProfile"
readonly PP_PROFILES_PROP="Profiles"
readonly RE_PP_REPLY='^s "(.*)"$'
readonly RE_PP_PROFILE='"Profile" s "([^"]+)"'
# The daemon may apply a profile before publishing it, so a switch is done
# once ActiveProfile reads back the new name.
readonly PROFILE_POLL_SEC=0.1
readonly PROFILE_TIMEOUT_SEC=10

readonly PROFILE_USAGE="usage: hzless profile <status | <name>>
  status       show the active power profile
  <name>       switch, e.g. power-saver, balanced, performance"

# True when a power profile daemon owns the D-Bus name.
profile_available() {
  busctl --system status "$PP_BUS" >/dev/null 2>&1
}

profile_get() {
  local reply
  reply=$(busctl --system get-property "$PP_BUS" "$PP_PATH" "$PP_BUS" "$PP_PROP") ||
    die "$EXIT_HW" "cannot read $PP_PROP from $PP_BUS"
  [[ $reply =~ $RE_PP_REPLY ]] || die "$EXIT_HW" "unexpected $PP_PROP reply '$reply'"
  echo "${BASH_REMATCH[1]}"
}

# Profile names the daemon offers, one per line.
profile_list() {
  local reply
  reply=$(busctl --system get-property "$PP_BUS" "$PP_PATH" "$PP_BUS" "$PP_PROFILES_PROP") ||
    die "$EXIT_HW" "cannot read $PP_PROFILES_PROP from $PP_BUS"
  while [[ $reply =~ $RE_PP_PROFILE ]]; do
    echo "${BASH_REMATCH[1]}"
    reply=${reply#*"${BASH_REMATCH[0]}"}
  done
}

profile_check_name() {
  local names
  names=$(profile_list) || exit
  grep -qxF -- "$1" <<<"$names" ||
    die "$EXIT_USAGE" "unknown profile '$1' (valid: $(paste -sd ' ' <<<"$names"))"
}

# Polls ActiveProfile until it reads want; fails after PROFILE_TIMEOUT_SEC.
profile_wait() {
  local want=$1 current deadline=$((SECONDS + PROFILE_TIMEOUT_SEC))
  while true; do
    current=$(profile_get) || exit
    [[ $current == "$want" ]] && return
    ((SECONDS < deadline)) ||
      die "$EXIT_HW" "profile: wrote $want, still $current after ${PROFILE_TIMEOUT_SEC}s"
    sleep "$PROFILE_POLL_SEC"
  done
}

# Switches only when the target differs: a daemon may reapply its own settings
# on any write, even of the active profile.
profile_set() {
  local want=$1 before
  before=$(profile_get) || exit
  if [[ $before == "$want" ]]; then
    echo "profile $want (unchanged)"
    return
  fi
  busctl --system set-property "$PP_BUS" "$PP_PATH" "$PP_BUS" "$PP_PROP" s "$want" ||
    die "$EXIT_HW" "cannot set $PP_PROP to '$want'"
  profile_wait "$want"
  echo "profile $before -> $want"
}

profile_show() {
  local active
  active=$(profile_get) || exit
  echo "profile: $active"
}

cmd_profile() {
  if is_help "$@"; then
    echo "$PROFILE_USAGE"
    return
  fi
  (($# == 1)) || usage_error "$PROFILE_USAGE" "profile takes one value"
  profile_available || die "$EXIT_HW" "no power profile daemon on D-Bus ($PP_BUS)"
  case $1 in
    status) profile_show ;;
    *)
      profile_check_name "$1"
      profile_set "$1"
      ;;
  esac
}
