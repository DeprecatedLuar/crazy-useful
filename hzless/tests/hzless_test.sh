#!/usr/bin/env bash
# Runs hzless against a temporary sysfs tree with stubbed sudo and busctl.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HZLESS="$TEST_DIR/../main.sh"
TMP_PREFIX="${TMPDIR:-/tmp}/hzless-test."

KHZ_MIN=400000
KHZ_BASE=3300000
KHZ_TURBO=4400000
UW_PL1=45000000
UW_PL2=64000000
US_TAU=28000000
PROFILES=(power-saver balanced performance)
DEFAULT_PROFILE=balanced
UW_PER_W=1000000
PCT_FULL=100

TEST_ROOT=""
OUT=""
ERR=""
CODE=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "$3: expected '$1', got '$2'"
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "$3: '$2' not in '$1'"
}

assert_absent() {
  [[ ! -e $1 ]] || fail "$2: $1 exists: $(cat "$1")"
}

file_val() {
  cat "$TEST_ROOT/sys/$1"
}

set_val() {
  echo "$2" >"$TEST_ROOT/sys/$1"
}

make_cpus() {
  local cpu dir
  for cpu in 0 1; do
    dir="$TEST_ROOT/sys/cpu/cpu$cpu/cpufreq"
    mkdir -p "$dir"
    echo "$KHZ_MIN" >"$dir/cpuinfo_min_freq"
    echo "$KHZ_TURBO" >"$dir/cpuinfo_max_freq"
    echo "$KHZ_BASE" >"$dir/base_frequency"
    echo "$KHZ_MIN" >"$dir/scaling_min_freq"
    echo "$KHZ_BASE" >"$dir/scaling_max_freq"
  done
  mkdir -p "$TEST_ROOT/sys/cpu/intel_pstate"
  echo 1 >"$TEST_ROOT/sys/cpu/intel_pstate/no_turbo"
}

make_zones() {
  local zone dir
  for zone in intel-rapl:0 intel-rapl-mmio:0; do
    dir="$TEST_ROOT/sys/powercap/$zone"
    mkdir -p "$dir"
    echo 1 >"$dir/enabled"
    echo long_term >"$dir/constraint_0_name"
    echo short_term >"$dir/constraint_1_name"
    echo "$UW_PL1" >"$dir/constraint_0_power_limit_uw"
    echo "$UW_PL2" >"$dir/constraint_1_power_limit_uw"
    echo "$US_TAU" >"$dir/constraint_0_time_window_us"
  done
}

# sudo: logs the call, then runs the command as uid 0 in a user namespace.
make_sudo_stub() {
  cat >"$TEST_ROOT/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$TEST_ROOT/sudo.log"
[[ $1 == -v ]] && exit 0
[[ $1 == -- ]] && shift
exec unshare -r "$@"
EOF
  chmod +x "$TEST_ROOT/bin/sudo"
}

# busctl: power-profiles API backed by files in $TEST_ROOT/pp. A set lands
# after PP_LAG reads of ActiveProfile, never while pp/stuck exists.
make_busctl_stub() {
  cat >"$TEST_ROOT/bin/busctl" <<'EOF'
#!/usr/bin/env bash
pp=$TEST_ROOT/pp
shift
case $1 in
  status) [[ ! -e $pp/absent ]] ;;
  get-property)
    case $5 in
      ActiveProfile)
        if [[ -e $pp/pending && ! -e $pp/stuck ]]; then
          lag=$(<"$pp/lag")
          if ((lag <= 0)); then
            mv "$pp/pending" "$pp/active"
          else
            echo $((lag - 1)) >"$pp/lag"
          fi
        fi
        echo "s \"$(<"$pp/active")\""
        ;;
      Profiles)
        line="aa{sv} $(wc -w <"$pp/profiles")"
        for name in $(<"$pp/profiles"); do
          line+=" 3 \"Profile\" s \"$name\" \"CpuDriver\" s \"x\" \"PlatformDriver\" s \"x\""
        done
        echo "$line"
        ;;
      *) exit 1 ;;
    esac
    ;;
  set-property)
    echo "$7" >>"$pp/set.log"
    if ! grep -qw -- "$7" "$pp/profiles"; then
      echo "Failed to set property ActiveProfile" >&2
      exit 1
    fi
    echo "$7" >"$pp/pending"
    echo "${PP_LAG:-0}" >"$pp/lag"
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEST_ROOT/bin/busctl"
}

setup() {
  TEST_ROOT=$(mktemp -d "${TMP_PREFIX}XXXXXX")
  export TEST_ROOT
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config" "$TEST_ROOT/pp"
  make_cpus
  make_zones
  make_sudo_stub
  make_busctl_stub
  echo "${PROFILES[*]}" >"$TEST_ROOT/pp/profiles"
  echo "$DEFAULT_PROFILE" >"$TEST_ROOT/pp/active"
  export HZLESS_CPU_ROOT="$TEST_ROOT/sys/cpu"
  export HZLESS_POWERCAP_ROOT="$TEST_ROOT/sys/powercap"
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export PATH="$TEST_ROOT/bin:$PATH"
  unset SUDO_USER
}

cleanup() {
  [[ $TEST_ROOT == "$TMP_PREFIX"* ]] || return 1
  rm -rf -- "$TEST_ROOT"
}

hz() {
  local out_file="$TEST_ROOT/out" err_file="$TEST_ROOT/err"
  "$HZLESS" "$@" >"$out_file" 2>"$err_file"
  CODE=$?
  OUT=$(<"$out_file")
  ERR=$(<"$err_file")
}

# --- tests -------------------------------------------------------------------

test_status() {
  hz status
  assert_eq 0 "$CODE" "exit"
  assert_contains "$OUT" "freq:  max 3.30 GHz  100%" "freq line"
  assert_contains "$OUT" "turbo: off" "turbo line"
  assert_contains "$OUT" "PL1 45 W  PL2 64 W" "pl line"
  assert_contains "$OUT" "profile: balanced" "profile line"
  assert_absent "$TEST_ROOT/sudo.log" "no sudo"
}

test_freq_max_pct() {
  local pct=80 want
  want=$((KHZ_BASE * pct / PCT_FULL))
  hz freq max "$pct"
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_eq "$want" "$(file_val cpu/cpu0/cpufreq/scaling_max_freq)" "cpu0 max"
  assert_eq "$want" "$(file_val cpu/cpu1/cpufreq/scaling_max_freq)" "cpu1 max"
  assert_contains "$OUT" "(2 CPUs)" "grouped report"
}

test_freq_max_turbo_flag() {
  local pct=20
  hz freq max "$pct" -t
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_eq 0 "$(file_val cpu/intel_pstate/no_turbo)" "turbo on"
  assert_eq $((KHZ_BASE + (KHZ_TURBO - KHZ_BASE) * pct / PCT_FULL)) "$(file_val cpu/cpu0/cpufreq/scaling_max_freq)" "cpu0 max"
}

test_freq_bad_value() {
  hz freq max 3.0
  assert_eq 1 "$CODE" "exit"
  assert_contains "$ERR" "use 3.0g for GHz" "hint"
}

test_turbo_on() {
  hz turbo on
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_eq 0 "$(file_val cpu/intel_pstate/no_turbo)" "turbo on"
  assert_contains "$OUT" "turbo off -> on" "report"
}

test_pl_both() {
  local zone pl1=35 pl2=50
  hz pl "$pl1" "$pl2"
  assert_eq 0 "$CODE" "exit: $ERR"
  for zone in intel-rapl:0 intel-rapl-mmio:0; do
    assert_eq $((pl1 * UW_PER_W)) "$(file_val "powercap/$zone/constraint_0_power_limit_uw")" "$zone PL1"
    assert_eq $((pl2 * UW_PER_W)) "$(file_val "powercap/$zone/constraint_1_power_limit_uw")" "$zone PL2"
  done
}

test_pl1_raises() {
  local zone watts=70
  hz pl1 "$watts"
  assert_eq 0 "$CODE" "exit: $ERR"
  for zone in intel-rapl:0 intel-rapl-mmio:0; do
    assert_eq $((watts * UW_PER_W)) "$(file_val "powercap/$zone/constraint_0_power_limit_uw")" "$zone PL1"
    assert_eq $((watts * UW_PER_W)) "$(file_val "powercap/$zone/constraint_1_power_limit_uw")" "$zone PL2"
  done
  assert_contains "$OUT" "PL2 raised to match" "report"
}

test_profile_set() {
  hz profile performance
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_contains "$OUT" "profile balanced -> performance" "report"
}

test_preset_roundtrip() {
  hz preset save p1
  assert_eq 0 "$CODE" "save: $ERR"
  hz pl 20
  hz freq max 50
  hz preset use p1
  assert_eq 0 "$CODE" "use: $ERR"
  assert_eq "$UW_PL1" "$(file_val powercap/intel-rapl:0/constraint_0_power_limit_uw)" "PL1 restored"
  assert_eq "$KHZ_BASE" "$(file_val cpu/cpu0/cpufreq/scaling_max_freq)" "max restored"
}

test_bad_input_no_sudo() {
  local -a cmd
  for cmd in "freq max abc" "pl -5" "turbo maybe" "preset use missing"; do
    read -ra cmd <<<"$cmd"
    hz "${cmd[@]}"
    assert_eq 1 "$CODE" "${cmd[*]} exit"
  done
  assert_absent "$TEST_ROOT/sudo.log" "no sudo"
}

test_status_no_sudo() {
  local -a cmd
  for cmd in "status" "freq status" "pl status" "preset list"; do
    read -ra cmd <<<"$cmd"
    hz "${cmd[@]}"
    assert_eq 0 "$CODE" "${cmd[*]} exit: $ERR"
  done
  assert_absent "$TEST_ROOT/sudo.log" "no sudo"
}

test_sudo_once() {
  hz freq max 80
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_eq 1 "$(grep -c -- '^-- ' "$TEST_ROOT/sudo.log")" "one re-exec"
}

preset_conf() {
  echo "$TEST_ROOT/config/hzless/presets.conf"
}

test_preset_save_single() {
  hz preset save p
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_contains "$(<"$(preset_conf)")" "min=$KHZ_MIN"$'\n'"max=$KHZ_BASE"$'\n' "single values"
}

test_preset_save_mixed_caps() {
  set_val cpu/cpu1/cpufreq/scaling_max_freq 2000000
  hz preset save p
  assert_eq 1 "$CODE" "exit"
  assert_contains "$ERR" "CPUs have different max caps; set one with hzless freq first" "error"
  assert_absent "$(preset_conf)" "nothing saved"
}

test_preset_rejects_list() {
  hz preset save p
  local conf
  conf=$(<"$(preset_conf)")
  echo "${conf/max=$KHZ_BASE/max=$KHZ_BASE 2000000}" >"$(preset_conf)"
  hz preset list
  assert_eq 2 "$CODE" "list exit"
  assert_contains "$ERR" "bad or missing max" "list error"
  hz preset use p
  assert_eq 2 "$CODE" "use exit"
  assert_contains "$ERR" "bad or missing max" "use error"
  assert_absent "$TEST_ROOT/sudo.log" "fails before sudo"
}

pl_val() {
  file_val "powercap/intel-rapl:0/constraint_$1"
}

test_pl_long_only() {
  local watts=30
  hz pl --long "$watts"
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_eq $((watts * UW_PER_W)) "$(pl_val 0_power_limit_uw)" "PL1"
  assert_eq "$UW_PL2" "$(pl_val 1_power_limit_uw)" "PL2 kept"
}

test_pl_short_only() {
  local watts=80
  hz pl --short "$watts"
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_eq "$UW_PL1" "$(pl_val 0_power_limit_uw)" "PL1 kept"
  assert_eq $((watts * UW_PER_W)) "$(pl_val 1_power_limit_uw)" "PL2"
}

test_pl_tau_flag() {
  local sec=10
  hz pl --tau "$sec"
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_eq $((sec * UW_PER_W)) "$(pl_val 0_time_window_us)" "tau"
}

test_pl_long_above_short_errors() {
  hz pl --long 70 --short 50
  assert_eq 1 "$CODE" "exit"
  assert_contains "$ERR" "PL2 50 W is below PL1 70 W" "error"
  assert_eq "$UW_PL1" "$(pl_val 0_power_limit_uw)" "PL1 kept"
}

test_pl_mixed_forms() {
  hz pl 35 --short 50
  assert_eq 1 "$CODE" "exit"
}

test_pl_tau_word_gone() {
  hz pl tau 10
  assert_eq 1 "$CODE" "exit"
}

test_pl_flag_repeated() {
  hz pl --long 30 --long 40
  assert_eq 1 "$CODE" "exit"
}

test_pl_flag_missing_value() {
  hz pl --long
  assert_eq 1 "$CODE" "exit"
}

test_profile_unknown() {
  hz profile power_saver
  assert_eq 1 "$CODE" "exit"
  assert_eq "error: unknown profile 'power_saver' (valid: ${PROFILES[*]})" "$ERR" "error"
  assert_absent "$TEST_ROOT/pp/set.log" "no write"
}

test_profile_same_skips() {
  hz profile "$DEFAULT_PROFILE"
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_eq "profile $DEFAULT_PROFILE (unchanged)" "$OUT" "report"
  assert_absent "$TEST_ROOT/pp/set.log" "no write"
}

test_profile_waits() {
  PP_LAG=5 hz profile performance
  assert_eq 0 "$CODE" "exit: $ERR"
  assert_contains "$OUT" "profile $DEFAULT_PROFILE -> performance" "report"
}

test_profile_timeout() {
  touch "$TEST_ROOT/pp/stuck"
  hz profile performance
  assert_eq 2 "$CODE" "exit"
  assert_contains "$ERR" "profile: wrote performance, still $DEFAULT_PROFILE after 10s" "error"
}

test_preset_same_profile_no_write() {
  local khz=3645000 dir
  echo performance >"$TEST_ROOT/pp/active"
  hz turbo on
  hz freq max 3.645g
  hz preset save g
  assert_eq 0 "$CODE" "save: $ERR"
  hz turbo off
  for dir in cpu0 cpu1; do
    set_val "cpu/$dir/cpufreq/scaling_max_freq" "$KHZ_BASE"
  done
  hz preset use g
  assert_eq 0 "$CODE" "use: $ERR"
  assert_absent "$TEST_ROOT/pp/set.log" "no profile write"
  assert_eq 0 "$(file_val cpu/intel_pstate/no_turbo)" "turbo on"
  assert_eq "$khz" "$(file_val cpu/cpu0/cpufreq/scaling_max_freq)" "max"
}

test_preset_bad_profile_no_sudo() {
  hz preset save p
  local conf
  conf=$(<"$(preset_conf)")
  echo "${conf/profile=$DEFAULT_PROFILE/profile=quiet}" >"$(preset_conf)"
  rm -f "$TEST_ROOT/sudo.log"
  hz preset use p
  assert_eq 1 "$CODE" "exit"
  assert_contains "$ERR" "unknown profile 'quiet'" "error"
  assert_absent "$TEST_ROOT/sudo.log" "fails before sudo"
}

test_preset_freq_read_error_fails() {
  hz preset save p
  hz pl 20
  set_val cpu/cpu1/cpufreq/scaling_max_freq garbage
  hz preset use p
  assert_eq 2 "$CODE" "exit"
  assert_contains "$ERR" "unexpected value 'garbage'" "error"
  assert_eq $((20 * UW_PER_W)) "$(file_val powercap/intel-rapl:0/constraint_0_power_limit_uw)" "PL untouched"
}

test_preset_bad_pl_key_no_sudo() {
  hz preset save p
  local conf
  conf=$(<"$(preset_conf)")
  echo "${conf/MMIO.tau=$US_TAU/}" >"$(preset_conf)"
  rm -f "$TEST_ROOT/sudo.log"
  hz preset use p
  assert_eq 2 "$CODE" "exit"
  assert_contains "$ERR" "bad or missing MMIO.tau" "error"
  assert_absent "$TEST_ROOT/sudo.log" "fails before sudo"
}

# --- runner ------------------------------------------------------------------

main() {
  local name passed=0 failed=0
  for name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    if (setup && trap cleanup EXIT && "$name"); then
      echo "PASS $name"
      passed=$((passed + 1))
    else
      echo "FAIL $name"
      failed=$((failed + 1))
    fi
  done
  echo "$passed passed, $failed failed"
  ((failed == 0))
}

main "$@"
