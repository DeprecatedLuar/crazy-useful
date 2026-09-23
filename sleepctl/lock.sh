# lock.sh - lock the session.
#
# Delegates entirely to logind: `loginctl lock-session` emits the Lock signal,
# and whatever lock handler the session runs (hypridle, swayidle, a shell)
# answers it. sleepctl holds no lock command and no state of its own.

lock_session() {
    require_cmd loginctl
    loginctl lock-session || die 'loginctl lock-session failed'
}
