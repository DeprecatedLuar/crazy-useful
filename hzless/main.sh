#!/usr/bin/env bash
# hzless: CPU frequency and power limit control. Each branch prints its usage with no args,
# shows state with `status`, and sets it with other subcommands.

readonly CPU_ROOT="${HZLESS_CPU_ROOT:-/sys/devices/system/cpu}"
readonly TURBO_INTEL_FILE="$CPU_ROOT/intel_pstate/no_turbo"
readonly TURBO_CPUFREQ_FILE="$CPU_ROOT/cpufreq/boost"

readonly EXIT_USAGE=1
readonly EXIT_HW=2

readonly POWERCAP_ROOT="${HZLESS_POWERCAP_ROOT:-/sys/class/powercap}"
# label:zone pairs; the zone path itself contains a colon.
readonly -a PL_ZONES=("MSR:$POWERCAP_ROOT/intel-rapl:0" "MMIO:$POWERCAP_ROOT/intel-rapl-mmio:0")
readonly PL1_CONSTRAINT="long_term"
readonly PL2_CONSTRAINT="short_term"
# Hardware stores tau as 2^y * (1 + z/4) and truncates, so a read-back may land
# up to one step (1/5) below the request.
readonly TAU_MIN_NUM=4
readonly TAU_MIN_DEN=5

readonly KHZ_PER_GHZ=1000000
readonly MICRO_PER_UNIT=1000000
readonly CENTI_PER_UNIT=100
readonly PCT_FULL=100

# Freq values: a bare integer is a %, GHz needs a g/ghz suffix.
readonly RE_PCT='^[0-9]+%?$'
readonly RE_GHZ='^([0-9]+(\.[0-9]+)?)(g|ghz)$'
readonly RE_DECIMAL='^[0-9]+(\.[0-9]+)?$'
readonly RE_UINT='^[0-9]+$'

readonly RE_HELP='^(help|-h|--help)$'
readonly RE_TURBO_FLAG='^(-t|--turbo)$'

readonly PP_BUS="org.freedesktop.UPower.PowerProfiles"
readonly PP_PATH="/org/freedesktop/UPower/PowerProfiles"
readonly PP_PROP="ActiveProfile"
readonly RE_PP_REPLY='^s "(.*)"$'

readonly PRESET_FILE_REL="hzless/presets.conf"
readonly RE_PRESET_NAME='^[A-Za-z0-9_.-]+$'
readonly RE_PRESET_RESERVED='^(save|add|a|list|ls|use|rm|remove|help|-h|--help)$'
readonly RE_PRESET_LINE='^([A-Za-z0-9.]+)=(.*)$'
readonly RE_FORCE_FLAG='^(-f|--force)$'
readonly RE_UINT_LIST='^[0-9]+( [0-9]+)*$'
readonly -a PL_FIELDS=(PL1 PL2 tau)

readonly USAGE="usage: hzless <command> [help]
  status       show freq, turbo, power limits
  freq         frequency caps
  turbo        turbo boost
  pl           power limits
  pl1 | pl2    set one power limit
  profile      system power profile (power-saver, balanced, performance)
  preset       save and apply state snapshots"

readonly FREQ_USAGE="usage: hzless freq <status | max <val> [-t] | min <val> | reset>
  status       show min, max, range
  max <val>    set max on every CPU; above base turns turbo on
  min <val>    set min on every CPU
  reset        min -> floor, max -> base
  <val>        % of base (70, 112, 70%) or GHz (2.8g, 2.8ghz)
  -t, --turbo  <val> is % of turbo headroom: 20 -t = base + 20%"

readonly TURBO_USAGE="usage: hzless turbo <status | on | off>
  status       show turbo state
  on | off     set turbo"

readonly PL_USAGE="usage: hzless pl <status | <W> [<W>] | tau <sec>>
       hzless pl1 | pl2 <W>
  status       show PL1, PL2, tau per interface
  <W>          PL1 = PL2 = W watts
  <W1> <W2>    PL1 = W1, PL2 = W2
  tau <sec>    set PL1 time window
  pl1 | pl2    set one limit; pl1 above PL2 raises PL2"

readonly PROFILE_USAGE="usage: hzless profile <status | <name>>
  status       show the active power profile
  <name>       switch, e.g. power-saver, balanced, performance"

readonly PRESET_USAGE="usage: hzless preset <save <name> [-f] | list | use <name> | rm <name> | <name>>
  save <name>  snapshot power profile, turbo, freq caps, power limits (alias: add, a)
  -f, --force  overwrite an existing preset
  list         saved presets (alias: ls)
  use <name>   apply a preset; 'preset <name>' does the same
  rm <name>    delete a preset (alias: remove)"

SELF=$(realpath "${BASH_SOURCE[0]}")
readonly SELF
readonly -a ARGS=("$@")

declare -a CPUS=()
declare -A TARGET=()
declare -A BEFORE=()
declare -A CLAMPED=()
declare -a PL_LABELS=()
declare -A PL_PATH=()
declare -A PL_IDX=()
declare -A PL_TARGET=()
declare PL_RAISED=0
declare TURBO_REVERT=0
declare -A PRESET=()

# --- helpers -----------------------------------------------------------------

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

# Re-runs the original command under sudo when not root.
require_root() {
  ((EUID == 0)) && return
  command -v sudo >/dev/null || die "$EXIT_HW" "root required and sudo not found"
  sudo -v || die "$EXIT_HW" "sudo failed"
  exec sudo -- "$SELF" "${ARGS[@]}"
}

# Fills CPUS with every cpufreq policy dir.
load_cpus() {
  local dir
  for dir in "$CPU_ROOT"/cpu[0-9]*/cpufreq; do
    [[ -d $dir ]] && CPUS+=("$dir")
  done
  ((${#CPUS[@]})) || die "$EXIT_HW" "no cpufreq dirs under $CPU_ROOT"
}

cpu_name() {
  basename "$(dirname "$1")"
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

floor_khz() {
  read_uint "$1/cpuinfo_min_freq"
}

# base_frequency, falling back to cpuinfo_max_freq.
ceiling_file() {
  if [[ -e $1/base_frequency ]]; then
    echo "$1/base_frequency"
  else
    echo "$1/cpuinfo_max_freq"
  fi
}

ceiling_khz() {
  read_uint "$(ceiling_file "$1")"
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

# --- freq --------------------------------------------------------------------

# Prints a spec: "pct N", "khz N" or, with turbo=1, "turbo N". "floor 0" is reserved for reset.
parse_spec() {
  local value=$1 turbo=$2
  if ((turbo)); then
    [[ $value =~ $RE_PCT ]] || return 1
    echo "turbo $((10#${value%\%}))"
  elif [[ $value =~ $RE_PCT ]]; then
    echo "pct $((10#${value%\%}))"
  elif [[ ${value,,} =~ $RE_GHZ ]]; then
    local khz
    khz=$(to_micro "${BASH_REMATCH[1]}") || return 1
    echo "khz $khz"
  else
    return 1
  fi
}

# Explains a rejected freq value.
parse_hint() {
  local value=$1 turbo=$2
  if ((turbo)); then
    echo " (-t takes a %)"
  elif [[ $value =~ $RE_DECIMAL ]]; then
    echo " (use ${value}g for GHz)"
  fi
}

# Resolves a spec against one CPU's floor, base and turbo max.
resolve_khz() {
  local kind=$1 n=$2 floor=$3 base=$4 tmax=$5
  case $kind in
    pct) echo $((base * n / PCT_FULL)) ;;
    turbo) echo $((base + (tmax - base) * n / PCT_FULL)) ;;
    khz) echo "$n" ;;
    floor) echo "$floor" ;;
  esac
}

# True when a max spec lands above base on any CPU.
spec_needs_turbo() {
  local kind=$1 n=$2 dir base
  case $kind in
    turbo) return 0 ;;
    pct) ((n > PCT_FULL)); return ;;
    khz)
      for dir in "${CPUS[@]}"; do
        base=$(ceiling_khz "$dir") || exit
        ((n > base)) && return 0
      done
      return 1
      ;;
    *) return 1 ;;
  esac
}

# Fills TARGET and CLAMPED for every CPU; fails before any write.
freq_plan() {
  local which=$1 kind=$2 n=$3 dir floor base tmax target other
  for dir in "${CPUS[@]}"; do
    floor=$(floor_khz "$dir") || exit
    base=$(ceiling_khz "$dir") || exit
    tmax=$(read_uint "$dir/cpuinfo_max_freq") || exit
    target=$(resolve_khz "$kind" "$n" "$floor" "$base" "$tmax")
    ((target > tmax)) && die "$EXIT_USAGE" "max is $(fmt_ghz "$tmax") ($(pct_of "$tmax" "$base")%)"
    if ((target < floor)); then
      target=$floor
      CLAMPED[$floor]=1
    fi
    if [[ $which == max ]]; then
      other=$(read_uint "$dir/scaling_min_freq") || exit
      ((target < other)) && die "$EXIT_USAGE" "max $(fmt_ghz "$target") is below min $(fmt_ghz "$other")"
    else
      other=$(read_uint "$dir/scaling_max_freq") || exit
      ((target > other)) && die "$EXIT_USAGE" "min $(fmt_ghz "$target") is above max $(fmt_ghz "$other")"
    fi
    TARGET[$dir]=$target
  done
}

freq_report_clamps() {
  local floor
  for floor in "${!CLAMPED[@]}"; do
    echo "clamped to $(fmt_ghz "$floor")"
  done
}

freq_apply() {
  local file="scaling_$1_freq" dir
  for dir in "${CPUS[@]}"; do
    BEFORE[$dir]=$(read_uint "$dir/$file") || exit
    write_value "$dir/$file" "${TARGET[$dir]}"
  done
}

# Reads back every CPU; prints grouped "before -> after" lines.
freq_verify() {
  local which=$1 file="scaling_$1_freq" dir after lines=()
  for dir in "${CPUS[@]}"; do
    after=$(read_uint "$dir/$file") || exit
    ((after == TARGET[$dir])) ||
      die "$EXIT_HW" "$(cpu_name "$dir") $which: wrote ${TARGET[$dir]}, read $after"
    lines+=("$which $(fmt_ghz "${BEFORE[$dir]}") -> $(fmt_ghz "$after")")
  done
  printf '%s\n' "${lines[@]}" | sort | uniq -c |
    awk '{ n = $1; $1 = ""; sub(/^ /, ""); print $0 " (" n " CPUs)" }'
}

# Exit trap: turns turbo back off when freq_set enabled it and then failed.
freq_revert_turbo() {
  if ((TURBO_REVERT)); then turbo_set off; fi
}

# The turbo max reads as base while turbo is off, so turbo goes on before planning.
freq_set() {
  local which=$1 kind=$2 n=$3
  TARGET=() BEFORE=() CLAMPED=()
  if [[ $which == max ]] && spec_needs_turbo "$kind" "$n"; then
    require_root
    if [[ $(turbo_current) == off ]]; then
      TURBO_REVERT=1
      trap freq_revert_turbo EXIT
      turbo_set on
    fi
  fi
  freq_plan "$which" "$kind" "$n"
  require_root
  freq_report_clamps
  freq_apply "$which"
  freq_verify "$which"
  TURBO_REVERT=0
}

freq_show_cpu() {
  local dir=$1 floor base tmax min max range note=""
  floor=$(floor_khz "$dir") || exit
  base=$(ceiling_khz "$dir") || exit
  tmax=$(read_uint "$dir/cpuinfo_max_freq") || exit
  min=$(read_uint "$dir/scaling_min_freq") || exit
  max=$(read_uint "$dir/scaling_max_freq") || exit
  range=$(fmt_ghz "$floor")
  [[ $(ceiling_file "$dir") == */base_frequency ]] ||
    note=" (no base_frequency, using cpuinfo_max_freq)"
  ((tmax > base)) && note+=" (turbo $(fmt_ghz "$tmax"))"
  printf '  %-8s %s  %s%%\n' "min" "$(fmt_ghz "$min")" "$(pct_of "$min" "$base")"
  printf '  %-8s %s  %s%%\n' "max" "$(fmt_ghz "$max")" "$(pct_of "$max" "$base")"
  printf '  %-8s %s - %s%s\n' "range" "${range% GHz}" "$(fmt_ghz "$base")" "$note"
}

# Average max cap across CPUs, with % averaged against each CPU's base.
freq_max_avg() {
  local dir max base sum=0 pct_sum=0 n=${#CPUS[@]}
  for dir in "${CPUS[@]}"; do
    max=$(read_uint "$dir/scaling_max_freq") || exit
    base=$(ceiling_khz "$dir") || exit
    sum=$((sum + max))
    pct_sum=$((pct_sum + $(pct_of "$max" "$base")))
  done
  echo "$(fmt_ghz $((sum / n)))  $(((pct_sum + n / 2) / n))%"
}

# Groups CPUs with identical caps/floor/base so hybrid parts stay readable.
freq_show() {
  local dir block
  local -A members=()
  local -a order=()
  for dir in "${CPUS[@]}"; do
    block=$(freq_show_cpu "$dir") || exit
    [[ -n ${members[$block]+x} ]] || order+=("$block")
    members[$block]+="$(cpu_name "$dir") "
  done
  for block in "${order[@]}"; do
    ((${#order[@]} > 1)) && echo "${members[$block]% }:"
    echo "$block"
  done
}

freq_reset() {
  freq_set min floor 0
  freq_set max pct "$PCT_FULL"
}

freq() {
  if (($# == 0)) || [[ $1 =~ $RE_HELP ]]; then
    echo "$FREQ_USAGE"
    return
  fi
  load_cpus
  local spec
  case $1 in
    status)
      (($# == 1)) || usage_error "$FREQ_USAGE" "freq status takes no value"
      freq_show
      ;;
    max|min)
      local which=$1 value="" turbo=0 arg
      shift
      for arg in "$@"; do
        if [[ $arg =~ $RE_TURBO_FLAG ]]; then
          turbo=1
        elif [[ -z $value ]]; then
          value=$arg
        else
          usage_error "$FREQ_USAGE" "freq $which needs one value"
        fi
      done
      [[ -n $value ]] || usage_error "$FREQ_USAGE" "freq $which needs one value"
      ((turbo)) && [[ $which == min ]] && usage_error "$FREQ_USAGE" "-t applies to max only"
      spec=$(parse_spec "$value" "$turbo") ||
        usage_error "$FREQ_USAGE" "cannot parse '$value'$(parse_hint "$value" "$turbo")"
      # shellcheck disable=SC2086
      freq_set "$which" $spec
      ;;
    reset)
      (($# == 1)) || usage_error "$FREQ_USAGE" "freq reset takes no value"
      freq_reset
      ;;
    *) usage_error "$FREQ_USAGE" "unknown freq command '$1'" ;;
  esac
}

# --- turbo -------------------------------------------------------------------

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
  require_root
  before=$(turbo_state "$file" "$on" "$off") || exit
  if [[ $want == on ]]; then value=$on; else value=$off; fi
  write_value "$file" "$value"
  after=$(turbo_state "$file" "$on" "$off") || exit
  [[ $after == "$want" ]] || die "$EXIT_HW" "turbo: wrote $want, read $after (locked by firmware?)"
  echo "turbo $before -> $after"
}

turbo() {
  if (($# == 0)) || [[ $1 =~ $RE_HELP ]]; then
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
      turbo_set "$1"
      ;;
    *) usage_error "$TURBO_USAGE" "unknown turbo command '$1'" ;;
  esac
}

# --- pl ----------------------------------------------------------------------

# Fills PL_LABELS, PL_PATH and PL_IDX for every present RAPL zone, matching
# constraints by name.
load_pl() {
  local entry label zone name_file name idx
  for entry in "${PL_ZONES[@]}"; do
    label=${entry%%:*}
    zone=${entry#*:}
    [[ -d $zone ]] || continue
    for name_file in "$zone"/constraint_*_name; do
      name=$(<"$name_file") || die "$EXIT_HW" "cannot read $name_file"
      idx=${name_file##*/constraint_}
      idx=${idx%_name}
      case $name in
        "$PL1_CONSTRAINT") PL_IDX[$label.PL1]=$idx ;;
        "$PL2_CONSTRAINT") PL_IDX[$label.PL2]=$idx ;;
      esac
    done
    [[ -n ${PL_IDX[$label.PL1]:-} && -n ${PL_IDX[$label.PL2]:-} ]] ||
      die "$EXIT_HW" "$zone lacks $PL1_CONSTRAINT/$PL2_CONSTRAINT constraints"
    PL_LABELS+=("$label")
    PL_PATH[$label]=$zone
  done
  ((${#PL_LABELS[@]})) || die "$EXIT_HW" "no RAPL zone under $POWERCAP_ROOT"
}

# Field file for a zone: PL1, PL2 or tau (the PL1 time window).
pl_file() {
  local label=$1 field=$2 zone=${PL_PATH[$1]}
  case $field in
    PL1|PL2) echo "$zone/constraint_${PL_IDX[$label.$field]}_power_limit_uw" ;;
    tau) echo "$zone/constraint_${PL_IDX[$label.PL1]}_time_window_us" ;;
  esac
}

pl_read() {
  read_uint "$(pl_file "$1" "$2")"
}

rtrim() {
  echo "${1%"${1##*[! ]}"}"
}

pl_fmt() {
  case $1 in
    tau) echo "$(fmt_micro "$2") s" ;;
    *) echo "$(fmt_micro "$2") W" ;;
  esac
}

pl_enabled() {
  read_uint "${PL_PATH[$1]}/enabled"
}

pl_warn_disabled() {
  local label enabled
  for label in "${PL_LABELS[@]}"; do
    enabled=$(pl_enabled "$label") || exit
    ((enabled)) || echo "warning: $label zone disabled; its limits are ignored" >&2
  done
}

# Watts or seconds -> millionths; usage error unless above zero.
pl_parse() {
  local value
  value=$(to_micro "$1") || usage_error "$PL_USAGE" "cannot parse '$1'"
  ((value > 0)) || usage_error "$PL_USAGE" "'$1' must be above 0"
  echo "$value"
}

# Fails if PL_TARGET for this field exceeds its max_power_uw (0 means none).
pl_check_max() {
  local label=$1 field=$2 target=${PL_TARGET[$1.$2]:-} file max
  [[ -n $target ]] || return 0
  file="${PL_PATH[$label]}/constraint_${PL_IDX[$label.$field]}_max_power_uw"
  [[ -e $file ]] || return 0
  max=$(read_uint "$file") || exit
  ((max == 0 || target <= max)) ||
    die "$EXIT_USAGE" "$label $field $(pl_fmt "$field" "$target") exceeds max $(pl_fmt "$field" "$max")"
}

# True if a read-back holds the requested value.
pl_stuck() {
  local field=$1 target=$2 after=$3
  if [[ $field == tau ]]; then
    ((after <= target && after * TAU_MIN_DEN >= target * TAU_MIN_NUM))
  else
    ((after == target))
  fi
}

# Fills PL_TARGET for every zone; fails before any write.
pl_plan() {
  local pl1=$1 pl2=$2 tau=$3 raise=$4 label cur1 cur2 t1 t2
  for label in "${PL_LABELS[@]}"; do
    cur1=$(pl_read "$label" PL1) || exit
    cur2=$(pl_read "$label" PL2) || exit
    t1=${pl1:-$cur1}
    t2=${pl2:-$cur2}
    if ((raise && t1 > t2)); then
      t2=$t1
      PL_TARGET[$label.PL2]=$t2
      PL_RAISED=1
    fi
    if [[ -n $pl1$pl2 ]] && ((t2 < t1)); then
      die "$EXIT_USAGE" "$label PL2 $(pl_fmt PL2 "$t2") is below PL1 $(pl_fmt PL1 "$t1")"
    fi
    [[ -n $pl1 ]] && PL_TARGET[$label.PL1]=$pl1
    [[ -n $pl2 ]] && PL_TARGET[$label.PL2]=$pl2
    [[ -n $tau ]] && PL_TARGET[$label.tau]=$tau
    pl_check_max "$label" PL1
    pl_check_max "$label" PL2
  done
}

# Writes every target, reads each back, prints "before -> after" per change.
pl_apply() {
  local label field file target before after failed=0 changed=0
  for label in "${PL_LABELS[@]}"; do
    for field in PL1 PL2 tau; do
      target=${PL_TARGET[$label.$field]:-}
      [[ -n $target ]] || continue
      file=$(pl_file "$label" "$field")
      before=$(read_uint "$file") || exit
      # A rejected write is caught by the read-back below.
      try_write "$file" "$target"
      after=$(read_uint "$file") || exit
      if ! pl_stuck "$field" "$target" "$after"; then
        echo "error: $label $field locked or overridden by firmware" \
          "(wrote $(pl_fmt "$field" "$target"), read $(pl_fmt "$field" "$after"))" >&2
        failed=1
      fi
      ((before == after)) && continue
      printf '%-5s %s %s -> %s\n' "$label" "$field" "$(pl_fmt "$field" "$before")" "$(pl_fmt "$field" "$after")"
      changed=1
    done
  done
  ((changed || failed)) || echo "no change"
  pl_warn_disabled
  ((failed)) && exit "$EXIT_HW"
  return 0
}

# Sets any of PL1, PL2, tau (millionths; empty keeps current). raise=1 lets
# PL1 lift PL2 instead of failing.
pl_set() {
  PL_TARGET=() PL_RAISED=0
  pl_plan "$@"
  require_root
  ((PL_RAISED)) && echo "PL2 raised to match"
  pl_apply
}

# Prints the field from every zone, marking a mismatch with "*".
pl_show_row() {
  local field=$1 label value first="" mark="" line
  line=$(printf '  %-8s' "$field")
  for label in "${PL_LABELS[@]}"; do
    value=$(pl_read "$label" "$field") || exit
    [[ -n $first && $value != "$first" ]] && mark="*"
    first=${first:-$value}
    line+=$(printf '%-10s' "$(pl_fmt "$field" "$value")")
  done
  rtrim "$line$mark"
}

pl_show() {
  local label field row line differ=0
  rtrim "$(printf '  %-8s' "")$(printf '%-10s' "${PL_LABELS[@]}")"
  for field in PL1 PL2 tau; do
    row=$(pl_show_row "$field") || exit
    [[ $row == *"*" ]] && differ=1
    echo "$row"
  done
  line=$(printf '  %-8s' "enabled")
  for label in "${PL_LABELS[@]}"; do
    if (($(pl_enabled "$label"))); then
      line+=$(printf '%-10s' on)
    else
      line+=$(printf '%-10s' off)
    fi
  done
  rtrim "$line"
  ((differ)) && echo "  * interfaces differ; the CPU obeys the lower"
  pl_warn_disabled
}

# Lowest PL1/PL2 across zones, the values the CPU obeys.
pl_summary() {
  local field label value low line="" differ=0
  for field in PL1 PL2; do
    low=""
    for label in "${PL_LABELS[@]}"; do
      value=$(pl_read "$label" "$field") || exit
      if [[ -z $low ]]; then
        low=$value
      elif ((value != low)); then
        differ=1
        ((value < low)) && low=$value
      fi
    done
    line+="$field $(pl_fmt "$field" "$low")  "
  done
  ((differ)) && line+="(interfaces differ, lower shown)"
  echo "${line%  }"
}

pl() {
  if (($# == 0)) || [[ $1 =~ $RE_HELP ]]; then
    echo "$PL_USAGE"
    return
  fi
  load_pl
  local pl1 pl2 tau
  case $1 in
    status)
      (($# == 1)) || usage_error "$PL_USAGE" "pl status takes no value"
      pl_show
      ;;
    tau)
      (($# == 2)) || usage_error "$PL_USAGE" "pl tau needs one value"
      tau=$(pl_parse "$2") || exit
      pl_set "" "" "$tau" 0
      ;;
    *)
      (($# <= 2)) || usage_error "$PL_USAGE" "pl takes one or two watt values"
      pl1=$(pl_parse "$1") || exit
      pl2=$pl1
      if (($# == 2)); then
        pl2=$(pl_parse "$2") || exit
      fi
      pl_set "$pl1" "$pl2" "" 0
      ;;
  esac
}

# pl1 <W> / pl2 <W>: set one limit through pl_set.
pl_one() {
  local which=$1 value
  shift
  if (($# == 0)) || [[ $1 =~ $RE_HELP ]]; then
    echo "$PL_USAGE"
    return
  fi
  (($# == 1)) || usage_error "$PL_USAGE" "$which takes one watt value"
  load_pl
  value=$(pl_parse "$1") || exit
  case $which in
    pl1) pl_set "$value" "" "" 1 ;;
    pl2) pl_set "" "$value" "" 0 ;;
  esac
}

# --- power -------------------------------------------------------------------

# True when a power profile daemon owns the D-Bus name.
power_available() {
  busctl --system status "$PP_BUS" >/dev/null 2>&1
}

power_get() {
  local reply
  reply=$(busctl --system get-property "$PP_BUS" "$PP_PATH" "$PP_BUS" "$PP_PROP") ||
    die "$EXIT_HW" "cannot read $PP_PROP from $PP_BUS"
  [[ $reply =~ $RE_PP_REPLY ]] || die "$EXIT_HW" "unexpected $PP_PROP reply '$reply'"
  echo "${BASH_REMATCH[1]}"
}

power_set() {
  local want=$1 before after
  before=$(power_get) || exit
  busctl --system set-property "$PP_BUS" "$PP_PATH" "$PP_BUS" "$PP_PROP" s "$want" ||
    die "$EXIT_HW" "cannot set $PP_PROP to '$want'"
  after=$(power_get) || exit
  [[ $after == "$want" ]] || die "$EXIT_HW" "profile: wrote $want, read $after"
  echo "profile $before -> $after"
}

power_show() {
  local active
  active=$(power_get) || exit
  echo "profile: $active"
}

profile() {
  if (($# == 0)) || [[ $1 =~ $RE_HELP ]]; then
    echo "$PROFILE_USAGE"
    return
  fi
  (($# == 1)) || usage_error "$PROFILE_USAGE" "profile takes one value"
  power_available || die "$EXIT_HW" "no power profile daemon on D-Bus ($PP_BUS)"
  case $1 in
    status) power_show ;;
    *) power_set "$1" ;;
  esac
}

# --- preset ------------------------------------------------------------------

# The invoking user's config, also under sudo.
preset_file() {
  local home
  if [[ -n ${SUDO_USER:-} ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [[ -n $home ]] || die "$EXIT_HW" "cannot find home of $SUDO_USER"
    echo "$home/.config/$PRESET_FILE_REL"
  else
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/$PRESET_FILE_REL"
  fi
}

preset_names() {
  local file
  file=$(preset_file) || exit
  [[ -e $file ]] || return 0
  sed -n 's/^\[\(.*\)\]$/\1/p' "$file"
}

preset_exists() {
  local names
  names=$(preset_names) || exit
  grep -qxF -- "$1" <<<"$names"
}

# Prints the key=value lines of one section; fails if absent.
preset_section() {
  local file
  file=$(preset_file) || exit
  [[ -e $file ]] || return 1
  awk -v want="[$1]" '
    /^\[/ { sec = ($0 == want); found = found || sec; next }
    sec && NF { print }
    END { exit !found }' "$file"
}

# Fills PRESET from a saved section.
preset_load() {
  local name=$1 section line
  section=$(preset_section "$name") || die "$EXIT_USAGE" "no preset '$name'"
  PRESET=()
  while IFS= read -r line; do
    [[ $line =~ $RE_PRESET_LINE ]] || die "$EXIT_HW" "preset '$name': bad line '$line'"
    PRESET[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  done <<<"$section"
}

# Rewrites the file without the named section, then appends the given body under it.
preset_write() {
  local name=$1 body=$2 file tmp
  file=$(preset_file) || exit
  mkdir -p "$(dirname "$file")" || die "$EXIT_HW" "cannot create $(dirname "$file")"
  tmp=$(mktemp "$file.XXXXXX") || die "$EXIT_HW" "cannot create temp file next to $file"
  if [[ -e $file ]]; then
    awk -v drop="[$name]" '/^\[/ { skip = ($0 == drop) } !skip' "$file" >"$tmp" ||
      die "$EXIT_HW" "cannot rewrite $file"
  fi
  if [[ -n $body ]]; then
    printf '[%s]\n%s\n\n' "$name" "$body" >>"$tmp" || die "$EXIT_HW" "cannot write $tmp"
  fi
  mv "$tmp" "$file" || die "$EXIT_HW" "cannot replace $file"
}

# One value when every CPU matches, else one per CPU in CPUS order.
preset_freq_values() {
  local file=$1 dir value values=()
  for dir in "${CPUS[@]}"; do
    value=$(read_uint "$dir/$file") || exit
    values+=("$value")
  done
  if (($(printf '%s\n' "${values[@]}" | sort -u | wc -l) == 1)); then
    echo "${values[0]}"
  else
    echo "${values[*]}"
  fi
}

# Prints the current state as key=value lines.
preset_snapshot() {
  local label field value
  load_cpus
  load_pl
  if power_available; then
    value=$(power_get) || exit
    echo "profile=$value"
  else
    echo "warning: no power profile daemon on D-Bus; power profile not saved" >&2
  fi
  value=$(turbo_current) || exit
  echo "turbo=$value"
  value=$(preset_freq_values scaling_min_freq) || exit
  echo "min=$value"
  value=$(preset_freq_values scaling_max_freq) || exit
  echo "max=$value"
  for label in "${PL_LABELS[@]}"; do
    for field in "${PL_FIELDS[@]}"; do
      value=$(pl_read "$label" "$field") || exit
      echo "$label.$field=$value"
    done
  done
}

# One line from PRESET: power profile, turbo, max cap, lowest PL1/PL2 across zones.
preset_summary() {
  local line="" max=${PRESET[max]:-} field key low
  [[ -n ${PRESET[profile]:-} ]] && line+="profile ${PRESET[profile]}  "
  line+="turbo ${PRESET[turbo]:-?}  "
  if [[ $max =~ $RE_UINT ]]; then
    line+="max $(fmt_ghz "$max")  "
  else
    line+="max per-CPU  "
  fi
  for field in PL1 PL2; do
    low=""
    for key in "${!PRESET[@]}"; do
      [[ $key == *".$field" ]] || continue
      if [[ -z $low ]] || ((PRESET[$key] < low)); then
        low=${PRESET[$key]}
      fi
    done
    [[ -n $low ]] && line+="$field $(pl_fmt "$field" "$low")  "
  done
  echo "${line%  }"
}

preset_list() {
  local names name
  names=$(preset_names) || exit
  if [[ -z $names ]]; then
    echo "no presets in $(preset_file)"
    return
  fi
  while IFS= read -r name; do
    preset_load "$name"
    printf '%-12s %s\n' "$name" "$(preset_summary)"
  done <<<"$names"
}

preset_save() {
  local name="" force=0 arg body
  for arg in "$@"; do
    if [[ $arg =~ $RE_FORCE_FLAG ]]; then
      force=1
    elif [[ -z $name ]]; then
      name=$arg
    else
      usage_error "$PRESET_USAGE" "save needs one name"
    fi
  done
  [[ -n $name ]] || usage_error "$PRESET_USAGE" "save needs one name"
  [[ $name =~ $RE_PRESET_NAME ]] || usage_error "$PRESET_USAGE" "name may use letters, digits, '_', '.', '-'"
  [[ $name =~ $RE_PRESET_RESERVED ]] && usage_error "$PRESET_USAGE" "'$name' is a preset command"
  if ((!force)) && preset_exists "$name"; then
    die "$EXIT_USAGE" "preset '$name' exists (-f to overwrite)"
  fi
  body=$(preset_snapshot) || exit
  preset_write "$name" "$body"
  preset_load "$name"
  echo "saved $name: $(preset_summary)"
}

preset_rm() {
  preset_exists "$1" || die "$EXIT_USAGE" "no preset '$1'"
  preset_write "$1" ""
  echo "removed $1"
}

# Fills TARGET from a saved min/max value: one for every CPU, or one per CPU.
preset_freq_targets() {
  local key=$1 values i
  [[ ${PRESET[$key]:-} =~ $RE_UINT_LIST ]] || die "$EXIT_HW" "preset: bad or missing $key"
  read -ra values <<<"${PRESET[$key]}"
  ((${#values[@]} == 1 || ${#values[@]} == ${#CPUS[@]})) ||
    die "$EXIT_USAGE" "preset has ${#values[@]} $key values for ${#CPUS[@]} CPUs"
  TARGET=() BEFORE=()
  for i in "${!CPUS[@]}"; do
    TARGET[${CPUS[i]}]=${values[i]:-${values[0]}}
  done
}

# Writes one freq bound from PRESET and verifies it.
preset_freq_apply() {
  preset_freq_targets "$1"
  freq_apply "$1"
  freq_verify "$1"
}

# Min goes first unless it would land above a CPU's current max.
preset_freq_order() {
  local dir max
  preset_freq_targets min
  for dir in "${CPUS[@]}"; do
    max=$(read_uint "$dir/scaling_max_freq") || exit
    if ((TARGET[$dir] > max)); then
      echo "max min"
      return
    fi
  done
  echo "min max"
}

preset_pl_targets() {
  local label field key
  PL_TARGET=()
  for label in "${PL_LABELS[@]}"; do
    for field in "${PL_FIELDS[@]}"; do
      key=$label.$field
      [[ ${PRESET[$key]:-} =~ $RE_UINT ]] || die "$EXIT_HW" "preset: bad or missing $key"
      PL_TARGET[$key]=${PRESET[$key]}
    done
  done
}

# Power profile first: switching it rewrites turbo, freq caps and power limits.
preset_use() {
  local name=$1 which order
  require_root
  preset_load "$name"
  [[ ${PRESET[turbo]:-} =~ ^(on|off)$ ]] || die "$EXIT_HW" "preset: bad or missing turbo"
  if [[ -n ${PRESET[profile]:-} ]]; then
    power_available || die "$EXIT_HW" "preset sets a power profile but no daemon is on D-Bus"
    power_set "${PRESET[profile]}"
  fi
  turbo_set "${PRESET[turbo]}"
  load_cpus
  order=$(preset_freq_order) || exit
  for which in $order; do
    preset_freq_apply "$which"
  done
  load_pl
  preset_pl_targets
  pl_apply
}

preset() {
  if (($# == 0)) || [[ $1 =~ $RE_HELP ]]; then
    echo "$PRESET_USAGE"
    return
  fi
  case $1 in
    save|add|a)
      shift
      preset_save "$@"
      ;;
    list|ls)
      (($# == 1)) || usage_error "$PRESET_USAGE" "list takes no value"
      preset_list
      ;;
    use)
      (($# == 2)) || usage_error "$PRESET_USAGE" "use needs one name"
      preset_use "$2"
      ;;
    rm|remove)
      (($# == 2)) || usage_error "$PRESET_USAGE" "$1 needs one name"
      preset_rm "$2"
      ;;
    *)
      (($# == 1)) || usage_error "$PRESET_USAGE" "unknown preset command '$1'"
      preset_use "$1"
      ;;
  esac
}

# --- status ------------------------------------------------------------------

status() {
  (($# == 0)) || usage_error "$USAGE" "status takes no arguments"
  local max limits
  load_cpus
  load_pl
  max=$(freq_max_avg) || exit
  limits=$(pl_summary) || exit
  echo "freq:  max $max"
  turbo_show
  echo "pl:    $limits"
  if power_available; then power_show; fi
}

# --- main --------------------------------------------------------------------

main() {
  if (($# == 0)) || [[ $1 =~ $RE_HELP ]]; then
    echo "$USAGE"
    return
  fi
  local branch=$1
  shift
  case $branch in
    status) status "$@" ;;
    freq) freq "$@" ;;
    turbo) turbo "$@" ;;
    pl) pl "$@" ;;
    pl1|pl2) pl_one "$branch" "$@" ;;
    profile) profile "$@" ;;
    preset) preset "$@" ;;
    *) usage_error "$USAGE" "unknown command '$branch'" ;;
  esac
}

main "$@"
