#!/usr/bin/env bash
# Sourced by the process samplers. Resolves a display name for one /proc/<pid> directory.
#
# argv[0]'s basename is preferred: it keeps names comm would truncate (15 chars) or mangle
# (Nix's .foo-wrapped). Chromium-based processes rewrite argv into a single space-joined
# title, so a spaced argv[0] is resolved against comm — the kernel sets it at exec and a
# title rewrite never touches it — by picking the word whose basename starts with comm.
# The "name: status" title convention (sshd, postgres) drops its trailing colon.

# read_process_name OUT_VAR PID_DIR FALLBACK
read_process_name() {
    local -n resolved_name="$1"
    local pid_dir="$2"
    local fallback_name="$3"
    local argv0="" comm="" word candidate name=""
    local -a words=()

    [[ -r "$pid_dir/cmdline" ]] && { IFS= read -r -d '' argv0 < "$pid_dir/cmdline" || true; }
    [[ -r "$pid_dir/comm" ]] && { IFS= read -r comm < "$pid_dir/comm" || true; }

    if [[ "$argv0" != *[[:space:]]* ]]; then
        name="${argv0##*/}"
    elif [[ -n "$comm" ]]; then
        read -r -a words <<< "$argv0"
        for word in "${words[@]}"; do
            candidate="${word##*/}"
            candidate="${candidate%:}"
            if [[ "$candidate" == "$comm"* ]]; then
                name="$candidate"
                break
            fi
        done
    fi

    [[ -n "$name" ]] || name="$comm"
    [[ -n "$name" ]] || name="$fallback_name"
    name="${name//$'\t'/ }"
    resolved_name="${name//$'\e'/?}"
}
