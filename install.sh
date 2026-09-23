#!/usr/bin/env bash
# install.sh — symlink every tool into BIN_DIR
#
# Each <tool>/main.sh becomes BIN_DIR/<tool>. Directories without a main.sh
# (lib/) are not tools and are skipped.

set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/bin}"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Twin binaries: one tool directory, a second entrypoint beside main.sh.
TWINS=(
    "serve/evres.sh:evres"
    "pack/unpack.sh:unpack"
)

# Short names, kept because they are how these are actually typed.
ALIASES=(
    "vibecheck:vch"
    "pilcboard:cb"
)

link() {
    local target="$1" name="$2"
    [[ -e "$target" ]] || { printf 'install: missing %s\n' "$target" >&2; return 1; }
    chmod +x "$target"
    ln -sfn "$target" "$BIN_DIR/$name"
    printf '+ %s\n' "$name"
}

mkdir -p "$BIN_DIR"

for entrypoint in "$REPO_DIR"/*/main.sh; do
    tool="$(basename "$(dirname "$entrypoint")")"
    link "$entrypoint" "$tool"
done

for twin in "${TWINS[@]}"; do
    link "$REPO_DIR/${twin%%:*}" "${twin##*:}"
done

for alias_spec in "${ALIASES[@]}"; do
    tool="${alias_spec%%:*}"
    link "$REPO_DIR/$tool/main.sh" "${alias_spec##*:}"
done

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) printf 'install: %s is not on PATH\n' "$BIN_DIR" >&2 ;;
esac
