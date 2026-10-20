# System power profile through the power-profiles D-Bus API.

readonly PP_BUS="org.freedesktop.UPower.PowerProfiles"
readonly PP_PATH="/org/freedesktop/UPower/PowerProfiles"
readonly PP_PROP="ActiveProfile"
readonly RE_PP_REPLY='^s "(.*)"$'

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

profile_set() {
  local want=$1 before after
  before=$(profile_get) || exit
  busctl --system set-property "$PP_BUS" "$PP_PATH" "$PP_BUS" "$PP_PROP" s "$want" ||
    die "$EXIT_HW" "cannot set $PP_PROP to '$want'"
  after=$(profile_get) || exit
  [[ $after == "$want" ]] || die "$EXIT_HW" "profile: wrote $want, read $after"
  echo "profile $before -> $after"
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
    *) profile_set "$1" ;;
  esac
}
