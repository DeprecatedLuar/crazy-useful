# Named snapshots of profile, turbo, freq caps and power limits in an INI-style file.

readonly PRESET_FILE_REL="hzless/presets.conf"
readonly RE_PRESET_NAME='^[A-Za-z0-9_.-]+$'
readonly RE_PRESET_RESERVED='^(save|add|a|list|ls|use|rm|remove|help|-h|--help)$'
readonly RE_PRESET_LINE='^([A-Za-z0-9.]+)=(.*)$'
readonly RE_FORCE_FLAG='^(-f|--force)$'
readonly RE_UINT_LIST='^[0-9]+( [0-9]+)*$'

readonly PRESET_USAGE="usage: hzless preset <save <name> [-f] | list | use <name> | rm <name> | <name>>
  save <name>  snapshot power profile, turbo, freq caps, power limits (alias: add, a)
  -f, --force  overwrite an existing preset
  list         saved presets (alias: ls)
  use <name>   apply a preset; 'preset <name>' does the same
  rm <name>    delete a preset (alias: remove)"

declare -A PRESET=()

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
  if profile_available; then
    value=$(profile_get) || exit
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

# Fails unless PRESET holds a usable turbo state and, if it names a profile, a daemon is up.
preset_check() {
  [[ ${PRESET[turbo]:-} =~ ^(on|off)$ ]] || die "$EXIT_HW" "preset: bad or missing turbo"
  [[ -z ${PRESET[profile]:-} ]] || profile_available ||
    die "$EXIT_HW" "preset sets a power profile but no daemon is on D-Bus"
}

cmd_preset() {
  if is_help "$@"; then
    echo "$PRESET_USAGE"
    return
  fi
  local name which
  case $1 in
    save|add|a)
      shift
      preset_save "$@"
      return
      ;;
    list|ls)
      (($# == 1)) || usage_error "$PRESET_USAGE" "list takes no value"
      preset_list
      return
      ;;
    rm|remove)
      (($# == 2)) || usage_error "$PRESET_USAGE" "$1 needs one name"
      preset_rm "$2"
      return
      ;;
    use)
      (($# == 2)) || usage_error "$PRESET_USAGE" "use needs one name"
      name=$2
      ;;
    *)
      (($# == 1)) || usage_error "$PRESET_USAGE" "unknown preset command '$1'"
      name=$1
      ;;
  esac
  preset_load "$name"
  preset_check
  require_root
  # Power profile first: switching it rewrites turbo, freq caps and power limits.
  [[ -z ${PRESET[profile]:-} ]] || profile_set "${PRESET[profile]}"
  turbo_set "${PRESET[turbo]}"
  load_cpus
  for which in $(preset_freq_order); do
    preset_freq_apply "$which"
  done
  load_pl
  preset_pl_targets
  pl_apply
}
