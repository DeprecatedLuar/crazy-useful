# CPU frequency caps (scaling_min_freq / scaling_max_freq) on every cpufreq policy.

# Freq values: a bare integer is a %, GHz needs a g/ghz suffix.
readonly RE_PCT='^[0-9]+%?$'
readonly RE_GHZ='^([0-9]+(\.[0-9]+)?)(g|ghz)$'
readonly RE_TURBO_FLAG='^(-t|--turbo)$'

readonly FREQ_USAGE="usage: hzless freq <status | max <val> [-t] | min <val> | reset>
  status       show min, max, range
  max <val>    set max on every CPU; above base turns turbo on
  min <val>    set min on every CPU
  reset        min -> floor, max -> base
  <val>        % of base (70, 112, 70%) or GHz (2.8g, 2.8ghz)
  -t, --turbo  <val> is % of turbo headroom: 20 -t = base + 20%"

declare -a CPUS=()
declare -A TARGET=()
declare -A BEFORE=()
declare -A CLAMPED=()

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
  TARGET=() BEFORE=() CLAMPED=()
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

# Writes the planned TARGET for one bound and verifies it.
freq_commit() {
  freq_report_clamps
  freq_apply "$1"
  freq_verify "$1"
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

cmd_freq() {
  if is_help "$@"; then
    echo "$FREQ_USAGE"
    return
  fi
  load_cpus
  local spec kind n
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
      read -r kind n <<<"$spec"
      # The turbo max reads as base while turbo is off, so turbo goes on before planning.
      if [[ $which == max ]] && spec_needs_turbo "$kind" "$n"; then
        require_root
        [[ $(turbo_current) == on ]] || turbo_set on
      fi
      freq_plan "$which" "$kind" "$n"
      require_root
      freq_commit "$which"
      ;;
    reset)
      (($# == 1)) || usage_error "$FREQ_USAGE" "freq reset takes no value"
      require_root
      freq_plan min floor 0
      freq_commit min
      freq_plan max pct "$PCT_FULL"
      freq_commit max
      ;;
    *) usage_error "$FREQ_USAGE" "unknown freq command '$1'" ;;
  esac
}
