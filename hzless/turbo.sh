# Turbo boost via intel_pstate/no_turbo or cpufreq/boost.

readonly TURBO_INTEL_FILE="$CPU_ROOT/intel_pstate/no_turbo"
readonly TURBO_CPUFREQ_FILE="$CPU_ROOT/cpufreq/boost"

readonly TURBO_USAGE="usage: hzless turbo <status | on | off>
  status       show turbo state
  on | off     set turbo"

# Prints the control file and the values meaning on and off.
turbo_control() {
  if [[ -e $TURBO_INTEL_FILE ]]; then
    echo "$TURBO_INTEL_FILE 0 1"
  elif [[ -e $TURBO_CPUFREQ_FILE ]]; then
    echo "$TURBO_CPUFREQ_FILE 1 0"
  else
    die "$EXIT_HW" "no turbo control found ($TURBO_INTEL_FILE or $TURBO_CPUFREQ_FILE)"
  fi
}

# Maps a raw control value to on/off.
turbo_state() {
  local file=$1 on=$2 off=$3 value
  value=$(<"$file") || die "$EXIT_HW" "cannot read $file"
  case $value in
    "$on") echo on ;;
    "$off") echo off ;;
    *) die "$EXIT_HW" "unexpected value '$value' in $file" ;;
  esac
}

turbo_current() {
  local control file on off
  control=$(turbo_control) || exit
  read -r file on off <<<"$control"
  turbo_state "$file" "$on" "$off"
}

# Average share of turbo headroom the max cap allows, floored at 0.
turbo_headroom_pct() {
  local dir base tmax max sum=0 n=0
  for dir in "${CPUS[@]}"; do
    base=$(ceiling_khz "$dir") || exit
    tmax=$(read_uint "$dir/cpuinfo_max_freq") || exit
    max=$(read_uint "$dir/scaling_max_freq") || exit
    ((tmax > base)) || continue
    ((max > base)) && sum=$((sum + $(pct_of $((max - base)) $((tmax - base)))))
    n=$((n + 1))
  done
  ((n)) || die "$EXIT_HW" "turbo on but no CPU reports a turbo max above base"
  echo $(((sum + n / 2) / n))
}

turbo_show() {
  local state pct
  state=$(turbo_current) || exit
  if [[ $state == on ]]; then
    pct=$(turbo_headroom_pct) || exit
    echo "turbo: on $pct%"
  else
    echo "turbo: off"
  fi
}

turbo_set() {
  local want=$1 control file on off before after value
  control=$(turbo_control) || exit
  read -r file on off <<<"$control"
  before=$(turbo_state "$file" "$on" "$off") || exit
  if [[ $want == on ]]; then value=$on; else value=$off; fi
  write_value "$file" "$value"
  after=$(turbo_state "$file" "$on" "$off") || exit
  [[ $after == "$want" ]] || die "$EXIT_HW" "turbo: wrote $want, read $after (locked by firmware?)"
  echo "turbo $before -> $after"
}

turbo_enable() {
  local state
  state=$(turbo_current) || exit
  [[ $state == on ]] || turbo_set on
}

cmd_turbo() {
  if is_help "$@"; then
    echo "$TURBO_USAGE"
    return
  fi
  case $1 in
    status)
      (($# == 1)) || usage_error "$TURBO_USAGE" "turbo status takes no value"
      load_cpus
      turbo_show
      ;;
    on|off)
      (($# == 1)) || usage_error "$TURBO_USAGE" "turbo $1 takes no value"
      require_root
      turbo_set "$1"
      ;;
    *) usage_error "$TURBO_USAGE" "unknown turbo command '$1'" ;;
  esac
}
