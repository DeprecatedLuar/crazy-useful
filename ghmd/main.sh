#!/usr/bin/env bash
# ghmd — render a markdown file with GitHub's API, open it in the browser,
# and keep it up to date while the file changes. Ctrl-C to stop.

set -euo pipefail

OUT_DIR="/tmp/ghmd"
MAX_AGE_MIN=1440
API_URL="https://api.github.com/markdown"
API_VERSION="2026-03-10"
API_MODE="gfm"
UNAUTH_LIMIT=60
CSS_URL="https://cdn.jsdelivr.net/npm/github-markdown-css@latest/github-markdown.css"
SIDE_BG_LIGHT="#dfe3e8"
SIDE_BG_DARK="#010409"
DEBOUNCE_SEC=2
POLL_MS=1000
WATCH_EVENTS="close_write,moved_to"
TOOL_DEPS=(curl jq inotifywait)
NIX_PKGS=(curl jq inotify-tools)

OUT=""

die() {
    echo "ghmd: $*" >&2
    exit 1
}

content_path() {
    echo "${1%.html}.js"
}

cleanup() {
    [[ -z "$OUT" ]] || rm -f "$OUT" "$OUT.new" "$(content_path "$OUT")"
}

check_args() {
    [[ $# -eq 1 ]] || die "usage: ghmd <markdown-file>"
    [[ -f "$1" ]] || die "file not found: $1"
}

missing_tools() {
    local dep
    for dep in "${TOOL_DEPS[@]}"; do
        command -v "$dep" >/dev/null || echo "$dep"
    done
}

# Missing tools are provided through nix-shell when available; the guard
# variable stops the re-run from looping if the tools are still missing.
check_deps() {
    local missing
    missing="$(missing_tools)"
    if [[ -n "$missing" ]]; then
        [[ -z "${NIX_GUARD:-}" ]] && command -v nix-shell >/dev/null \
            || die "missing dependencies: $(echo $missing)"
        echo "ghmd: missing $(echo $missing), re-running under nix-shell" >&2
        exec env NIX_GUARD=1 nix-shell -p "${NIX_PKGS[@]}" --run "$(printf '%q ' "$0" "$@")"
    fi
    [[ -n "${BROWSER:-}" ]] || die "BROWSER is not set"
    command -v "$BROWSER" >/dev/null || die "browser not found: $BROWSER"
}

sweep_stale() {
    mkdir -p "$OUT_DIR"
    find "$OUT_DIR" -type f \( -name '*.html' -o -name '*.js' \) -mmin +"$MAX_AGE_MIN" -delete
}

new_output_path() {
    local name
    name="$(basename "${1%.*}")"
    mktemp "$OUT_DIR/$name.XXXXXX.html"
}

file_url() {
    jq -rn --arg p "$1" '"file://" + ($p | split("/") | map(@uri) | join("/"))'
}

source_base_url() {
    echo "$(file_url "$(dirname "$(realpath "$1")")")/"
}

page_head() {
    cat <<EOF
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<base href="$1">
<link rel="stylesheet" href="$CSS_URL">
<style>
    body { box-sizing: border-box; min-width: 200px; margin: 0; background: $SIDE_BG_LIGHT; }
    @media (prefers-color-scheme: dark) { body { background: $SIDE_BG_DARK; } }
    .markdown-body {
        box-sizing: border-box;
        min-width: 200px;
        max-width: 980px;
        margin: 0 auto;
        padding: 45px;
    }
    @media (max-width: 767px) { .markdown-body { padding: 15px; } }
</style>
</head>
<body>
<article class="markdown-body">
EOF
}

# The content script is re-loaded every POLL_MS and only swaps the article
# when its HTML differs from what is already shown.
page_foot() {
    cat <<EOF
</article>
<script>
    var shown = null;
    window.ghmdUpdate = function (html) {
        if (html === shown) return;
        shown = html;
        document.querySelector(".markdown-body").innerHTML = html;
    };
    function poll() {
        var s = document.createElement("script");
        s.src = "$1?t=" + Date.now();
        s.onload = s.onerror = function () { s.remove(); };
        document.head.appendChild(s);
    }
    setInterval(poll, $POLL_MS);

    // <base> makes "#x" links resolve against the source dir; keep them in-page.
    document.addEventListener("click", function (e) {
        var a = e.target.closest('a[href^="#"]');
        if (!a) return;
        e.preventDefault();
        location.hash = a.getAttribute("href");
    });
</script>
</body>
</html>
EOF
}

find_token() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "$GITHUB_TOKEN"
    elif command -v gh >/dev/null; then
        gh auth token 2>/dev/null || true
    fi
}

render_markdown() {
    local token auth=()
    token="$(find_token)"
    if [[ -n "$token" ]]; then
        auth=(-H "Authorization: Bearer $token")
    else
        echo "ghmd: no token found, using unauthenticated API ($UNAUTH_LIMIT req/h)" >&2
    fi

    curl -fsS \
        -X POST \
        "${auth[@]}" \
        -H 'Accept: text/html' \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        "$API_URL" \
        -d "$(jq -Rs --arg mode "$API_MODE" '{text: ., mode: $mode}' "$1")"
}

write_page() {
    { page_head "$2"; printf '%s\n' "$1"; page_foot "$3"; } > "$4.new"
    mv "$4.new" "$4"
}

write_content() {
    printf '%s' "$1" | jq -Rs '"window.ghmdUpdate(" + tojson + ");"' -r > "$2.new"
    mv "$2.new" "$2"
}

# Files are written via a side file and renamed, so the browser never reads a
# half-written one. Explicit returns: errexit is off in functions run after ||.
build_page() {
    local file="$1" out="$2" html content
    content="$(content_path "$out")"
    html="$(render_markdown "$file")" || return 1
    write_page "$html" "$(source_base_url "$file")" "$(file_url "$content")" "$out" || return 1
    write_content "$html" "$content" || return 1
}

open_page() {
    "$BROWSER" "$1" >/dev/null 2>&1 &
}

# Emits the file name each time the target file is written.
file_events() {
    local dir base
    dir="$(dirname "$1")"
    base="$(basename "$1")"
    inotifywait -m -q -e "$WATCH_EVENTS" --format '%f' "$dir" \
        | grep --line-buffered -Fx "$base"
}

# Trailing-edge debounce: render only after DEBOUNCE_SEC without further events.
watch_loop() {
    local file="$1" out="$2"
    while read -r _; do
        while read -r -t "$DEBOUNCE_SEC" _; do :; done
        build_page "$file" "$out" || echo "ghmd: render failed, keeping last page" >&2
    done < <(file_events "$file")
}

main() {
    check_args "$@"
    check_deps "$@"
    sweep_stale

    OUT="$(new_output_path "$1")"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    build_page "$1" "$OUT" || die "render failed for $1"
    open_page "$OUT"
    watch_loop "$1" "$OUT"
}

main "$@"
