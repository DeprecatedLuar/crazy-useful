# RAPL power limits (PL1, PL2, tau) on every powercap zone.

readonly POWERCAP_ROOT="${HZLESS_POWERCAP_ROOT:-/sys/class/powercap}"
# label:zone pairs; the zone path itself contains a colon.
readonly -a PL_ZONES=("MSR:$POWERCAP_ROOT/intel-rapl:0" "MMIO:$POWERCAP_ROOT/intel-rapl-mmio:0")
readonly PL1_CONSTRAINT="long_term"
readonly PL2_CONSTRAINT="short_term"
readonly -a PL_FIELDS=(PL1 PL2 tau)
# Hardware stores tau as 2^y * (1 + z/4) and truncates, so a read-back may land
# up to one step (1/5) below the request.
readonly TAU_MIN_NUM=4
readonly TAU_MIN_DEN=5

readonly PL_USAGE="usage: hzless pl <status | <W> [<W>] | [--long <W>] [--short <W>] [--tau <sec>]>
       hzless pl1 | pl2 <W>
  status         show PL1, PL2, tau per interface
  <W>            PL1 = PL2 = W watts
  <W1> <W2>      PL1 = W1, PL2 = W2
  --long <W>     PL1 (sustained); above PL2 raises PL2
  --short <W>    PL2 (burst)
  --tau <sec>    PL1 time window
  pl1 | pl2 <W>  same as --long | --short"

declare -a PL_LABELS=()
declare -A PL_PATH=()
declare -A PL_IDX=()
declare -A PL_TARGET=()
declare PL_RAISED=0

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

# Fills PL_TARGET for every zone from PL1, PL2, tau (millionths; empty keeps
# current); fails before any write. raise=1 lets PL1 lift PL2 instead of failing.
pl_plan() {
  local pl1=$1 pl2=$2 tau=$3 raise=$4 label cur1 cur2 t1 t2
  PL_TARGET=() PL_RAISED=0
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
    for field in "${PL_FIELDS[@]}"; do
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

# Writes the planned PL_TARGET.
pl_commit() {
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
  for field in "${PL_FIELDS[@]}"; do
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

cmd_pl() {
  if is_help "$@"; then
    echo "$PL_USAGE"
    return
  fi
  load_pl
  if [[ $1 == status ]]; then
    (($# == 1)) || usage_error "$PL_USAGE" "pl status takes no value"
    pl_show
    return
  fi
  local pl1="" pl2="" tau="" raise=0 flag
  if [[ $1 == --* ]]; then
    local -A seen=()
    while (($#)); do
      flag=$1
      [[ -z ${seen[$flag]:-} ]] || usage_error "$PL_USAGE" "$flag given twice"
      seen[$flag]=1
      (($# >= 2)) || usage_error "$PL_USAGE" "$flag needs a value"
      case $flag in
        --long) pl1=$(pl_parse "$2") || exit ;;
        --short) pl2=$(pl_parse "$2") || exit ;;
        --tau) tau=$(pl_parse "$2") || exit ;;
        *) usage_error "$PL_USAGE" "unknown option '$flag'" ;;
      esac
      shift 2
    done
    [[ -n $pl1 && -z $pl2 ]] && raise=1
  else
    (($# <= 2)) || usage_error "$PL_USAGE" "pl takes one or two watt values"
    pl1=$(pl_parse "$1") || exit
    pl2=$pl1
    if (($# == 2)); then
      pl2=$(pl_parse "$2") || exit
    fi
  fi
  pl_plan "$pl1" "$pl2" "$tau" "$raise"
  require_root
  pl_commit
}
