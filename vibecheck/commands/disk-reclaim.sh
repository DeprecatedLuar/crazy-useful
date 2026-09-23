#!/usr/bin/env bash
# disk-reclaim.sh - advertise reclaimable space, confirm, then run the vendors'
# own garbage collectors. This command never issues a delete of its own: every
# line it runs comes from a provider in ../reclaim/ and is a command shipped by
# the tool that owns the data.
#
# Usage: vch disk reclaim [ID ...] [--dry-run] [-y]
# shared: format/bytes.sh

PROGRAM_NAME="vch"
USAGE="Usage: $PROGRAM_NAME disk reclaim [ID ...] [--dry-run] [-y]"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/.."
RECLAIM_SAMPLER="$LIB_DIR/sample/reclaim.sh"
COLUMN_FORMATTER="$LIB_DIR/format/columns.sh"

PLAN_COLUMN_COUNT=3
PLAN_SIZE_COLUMN=1
PLAN_CONSEQUENCE_COLUMN=3
SUDO_MARKER='(sudo)'
UNTOUCHED_NOTE='Not touched: ~/.cache, trash, your files.'
MARK_DONE='+'
MARK_FAILED='-'
DIM_ON=$'\033[2m'
DIM_OFF=$'\033[0m'

source "$LIB_DIR/format/bytes.sh"

dry_run=false
assume_yes=false
wanted=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        -y|--yes) assume_yes=true ;;
        help|-h|--help)
            printf '%s\n' "$USAGE"
            exit 0
            ;;
        -*)
            printf "%s disk reclaim: unknown option '%s'\n" "$PROGRAM_NAME" "$arg" >&2
            printf '%s\n' "$USAGE" >&2
            exit 2
            ;;
        *) wanted+=("$arg") ;;
    esac
done

disk_status_line() {
    local mark="$1" name="$2" detail="$3"

    if [[ "$mark" == "$MARK_FAILED" && -t 1 && -z "${NO_COLOR:-}" ]]; then
        printf '%s%s %s  %s%s\n' "$DIM_ON" "$mark" "$name" "$detail" "$DIM_OFF"
    else
        printf '%s %s  %s\n' "$mark" "$name" "$detail"
    fi
}

plan=$("$RECLAIM_SAMPLER" "${wanted[@]}" 2>/dev/null)
[[ -n "$plan" ]] || {
    printf 'Nothing to reclaim.\n'
    exit 0
}

total=$(awk -F'\t' '{ sum += $2 } END { printf "%d\n", sum }' <<< "$plan")

printf 'Will run:\n'
while IFS=$'\t' read -r id bytes command consequence needs_sudo; do
    [[ "$needs_sudo" == "1" ]] && consequence+=" $SUDO_MARKER"
    printf '%s\t%s\t%s\n' "~$(format_bytes "$bytes")" "$command" "$consequence"
done <<< "$plan" \
    | "$COLUMN_FORMATTER" \
        --columns "$PLAN_COLUMN_COUNT" \
        --delimiter tab \
        --right "$PLAN_SIZE_COLUMN" \
        --dim "$PLAN_CONSEQUENCE_COLUMN"

printf '\n%s\n' "$UNTOUCHED_NOTE"
printf 'Frees about %s.\n' "$(format_bytes "$total")"

$dry_run && exit 0

if ! $assume_yes; then
    printf '\nProceed? [y/N] '
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]] || {
        printf 'Nothing done.\n'
        exit 0
    }
fi

# Priming sudo once up front keeps the password prompt out of the middle of
# the +/- status output below, where it would otherwise land mid-provider.
if awk -F'\t' '$5 == 1 { found=1 } END { exit !found }' <<< "$plan"; then
    sudo -v || exit 1
fi

printf '\n'
failures=0
while IFS=$'\t' read -r id bytes command consequence needs_sudo; do
    if [[ "$needs_sudo" == "1" ]]; then
        command="sudo $command"
    fi

    if output=$(eval "$command" 2>&1); then
        disk_status_line "$MARK_DONE" "$id" "~$(format_bytes "$bytes") freed"
    else
        failures=$((failures + 1))
        disk_status_line "$MARK_FAILED" "$id" "${output##*$'\n'}"
    fi
done <<< "$plan"

exit $((failures > 0))
