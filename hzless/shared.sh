# Errors, root escalation, sysfs I/O and number formatting shared by every domain.

readonly CPU_ROOT="${HZLESS_CPU_ROOT:-/sys/devices/system/cpu}"

readonly EXIT_USAGE=1
readonly EXIT_HW=2

readonly KHZ_PER_GHZ=1000000
readonly MICRO_PER_UNIT=1000000
readonly CENTI_PER_UNIT=100
readonly PCT_FULL=100

readonly RE_DECIMAL='^[0-9]+(\.[0-9]+)?$'
readonly RE_UINT='^[0-9]+$'
readonly RE_HELP='^(help|-h|--help)$'

die() {
  local code=$1; shift
  echo "error: $*" >&2
  exit "$code"
}

# Prints an error plus the given usage text.
usage_error() {
  local usage=$1; shift
  echo "error: $*" >&2
  echo "$usage" >&2
  exit "$EXIT_USAGE"
}

# True with no args or a help word.
is_help() {
  (($# == 0)) || [[ $1 =~ $RE_HELP ]]
}

# Re-runs the original command under sudo when not root, keeping the
# caller's config dir since sudo resets the environment.
require_root() {
  ((EUID == 0)) && return
  command -v sudo >/dev/null || die "$EXIT_HW" "root required and sudo not found"
  exec sudo -- env "XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}" "$SELF" "${ARGS[@]}"
}

read_uint() {
  local value
  value=$(<"$1") || die "$EXIT_HW" "cannot read $1"
  [[ $value =~ $RE_UINT ]] || die "$EXIT_HW" "unexpected value '$value' in $1"
  echo "$value"
}

try_write() {
  { echo "$2" > "$1"; } 2>/dev/null
}

write_value() {
  try_write "$1" "$2" || die "$EXIT_HW" "cannot write $2 to $1"
}

# Decimal string -> integer millionths ("2.8" -> 2800000).
to_micro() {
  [[ $1 =~ $RE_DECIMAL ]] || return 1
  awk -v v="$1" -v k="$MICRO_PER_UNIT" 'BEGIN { printf "%d", v * k + 0.5 }'
}

# Integer value / per -> "x.yy".
fmt_fixed() {
  local centi=$((($1 * CENTI_PER_UNIT + $2 / 2) / $2))
  printf '%d.%02d' $((centi / CENTI_PER_UNIT)) $((centi % CENTI_PER_UNIT))
}

fmt_ghz() {
  echo "$(fmt_fixed "$1" "$KHZ_PER_GHZ") GHz"
}

# Millionths -> "35" or "55.97".
fmt_micro() {
  local value
  value=$(fmt_fixed "$1" "$MICRO_PER_UNIT")
  echo "${value%.00}"
}

pct_of() {
  echo $((($1 * PCT_FULL + $2 / 2) / $2))
}

rtrim() {
  echo "${1%"${1##*[! ]}"}"
}
