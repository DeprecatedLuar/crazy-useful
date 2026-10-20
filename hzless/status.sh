# One-screen overview of freq, turbo, power limits and profile.

cmd_status() {
  (($# == 0)) || usage_error "$USAGE" "status takes no arguments"
  local max limits
  load_cpus
  load_pl
  max=$(freq_max_avg) || exit
  limits=$(pl_summary) || exit
  echo "freq:  max $max"
  turbo_show
  echo "pl:    $limits"
  if profile_available; then profile_show; fi
}
