#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIBECHECK_DIR="$(cd "$TEST_DIR/.." && pwd)"
COLUMN_FORMATTER="$VIBECHECK_DIR/format/columns.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibecheck-process-name-test.XXXXXX")"
FALLBACK_NAME="PID 1"

cleanup() {
    [[ "$TEST_ROOT" == "${TMPDIR:-/tmp}/vibecheck-process-name-test."* ]] || return 1
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

source "$VIBECHECK_DIR/sample/process-name.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equals() {
    local expected="$1" actual="$2"
    [[ "$expected" == "$actual" ]] || fail "expected '$expected', got '$actual'"
}

# fake_process DIR CMDLINE COMM — CMDLINE is written with printf %b, so \0 marks argv boundaries
fake_process() {
    local pid_dir="$TEST_ROOT/$1"
    mkdir -p "$pid_dir"
    printf '%b' "$2" > "$pid_dir/cmdline"
    printf '%s\n' "$3" > "$pid_dir/comm"
    printf '%s' "$pid_dir"
}

assert_name() {
    local expected="$1" pid_dir="$2" actual=""
    read_process_name actual "$pid_dir" "$FALLBACK_NAME"
    assert_equals "$expected" "$actual"
}

echo "=== Test 1: Plain executable keeps argv[0] basename ==="
assert_name "foo" "$(fake_process plain '/usr/bin/foo\0--flag\0/some/path\0' 'foo')"

echo "=== Test 2: Nix wrapper keeps argv[0] name over truncated comm ==="
assert_name "firefox" "$(fake_process wrapped '/nix/store/abc-firefox/bin/firefox\0' '.firefox-wrappe')"

echo "=== Test 3: Rewritten Chromium title resolves to the executable ==="
assert_name "QtWebEngineProcess" "$(fake_process chromium \
    '/app/lib/libexec/QtWebEngineProcess --type=renderer --locales=/app/translations/qtwebengine_dictionaries --lang=en' \
    'QtWebEngineProc')"

echo "=== Test 4: Executable path containing spaces ==="
assert_name "app" "$(fake_process spaced '/opt/My App/bin/app\0--flag\0' 'app')"

echo "=== Test 5: Rewritten title with no word matching comm falls back to comm ==="
assert_name "worker" "$(fake_process retitled 'pool thread idle' 'worker')"

echo "=== Test 5b: 'name: status' title drops the colon ==="
assert_name "sshd-session" "$(fake_process colon_title 'sshd-session: luar@notty' 'sshd-session')"

echo "=== Test 6: Kernel thread with empty cmdline uses comm ==="
assert_name "kworker/0:1" "$(fake_process kthread '' 'kworker/0:1')"

echo "=== Test 7: Unreadable process uses the fallback ==="
mkdir -p "$TEST_ROOT/vanished"
assert_name "$FALLBACK_NAME" "$TEST_ROOT/vanished"

echo "=== Test 8: Tabs and escapes cannot break line records ==="
assert_name "a b?c" "$(fake_process hostile '' $'a\tb\ec')"

echo "=== Test 9: Column formatter truncates an over-wide capped column ==="
actual="$(printf '1.0%%\tabcdefghij\t(42)\n' \
    | "$COLUMN_FORMATTER" --delimiter tab --columns 3 --max-width 2:6)"
assert_equals "1.0% abcde… (42)" "$actual"

echo "=== Test 10: Column formatter leaves short cells untouched ==="
actual="$(printf '1.0%%\tabc\t(42)\n' \
    | "$COLUMN_FORMATTER" --delimiter tab --columns 3 --max-width 2:6)"
assert_equals "1.0% abc (42)" "$actual"

echo "ALL TESTS PASSED!"
