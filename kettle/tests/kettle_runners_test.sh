#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
KETTLE="$REPO_ROOT/bin/kettle"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kettle-runners-test.XXXXXX")"

cleanup() {
    [[ "$TEST_ROOT" == "${TMPDIR:-/tmp}/kettle-runners-test."* ]] || return 1
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

# Test environment isolation
export HOME="$TEST_ROOT/home"
export STEAM_ROOT="$HOME/.local/share/Steam"
export RUNNERS_DIR="$HOME/Games/runners"
export PATH="$TEST_ROOT/bin:$PATH"

mkdir -p "$HOME" "$TEST_ROOT/bin" "$STEAM_ROOT/steamapps"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equals() {
    local expected="$1" actual="$2"
    [[ "$expected" == "$actual" ]] || fail "expected '$expected', got '$actual'"
}

assert_symlink_points_to() {
    local link="$1" expected_target="$2"
    [[ -L "$link" ]] || fail "$link is not a symlink"
    local actual_target
    actual_target="$(readlink "$link")"
    [[ "$actual_target" == "$expected_target" ]] || fail "$link points to '$actual_target', expected '$expected_target'"
}

echo "=== Test 1: Proton-style runner detection ==="
# Proton style via root proton executable
STEAM_TOOL_DIR="$STEAM_ROOT/compatibilitytools.d/Proton-Test-1"
mkdir -p "$STEAM_TOOL_DIR"
cat << 'EOF' > "$STEAM_TOOL_DIR/proton"
#!/usr/bin/env bash
echo "mock proton"
EOF
chmod +x "$STEAM_TOOL_DIR/proton"

# Proton style via compatibilitytool.vdf
HEROIC_TOOL_DIR="$HOME/.config/heroic/tools/proton/Proton-Test-2"
mkdir -p "$HEROIC_TOOL_DIR"
touch "$HEROIC_TOOL_DIR/compatibilitytool.vdf"

# Proton style via files/bin/wine
LUTRIS_TOOL_DIR="$HOME/.local/share/lutris/runners/wine/Proton-Test-3"
mkdir -p "$LUTRIS_TOOL_DIR/files/bin"
touch "$LUTRIS_TOOL_DIR/files/bin/wine"
chmod +x "$LUTRIS_TOOL_DIR/files/bin/wine"

"$KETTLE" runners refresh

assert_symlink_points_to "$RUNNERS_DIR/steam/Proton-Test-1" "$STEAM_TOOL_DIR"
assert_symlink_points_to "$RUNNERS_DIR/heroic/Proton-Test-2" "$HEROIC_TOOL_DIR"
assert_symlink_points_to "$RUNNERS_DIR/lutris/Proton-Test-3" "$LUTRIS_TOOL_DIR"

echo "=== Test 2: Wine-style runner detection ==="
BOTTLES_WINE_DIR="$HOME/.local/share/bottles/runners/wine-ge-8-26"
mkdir -p "$BOTTLES_WINE_DIR/bin"
touch "$BOTTLES_WINE_DIR/bin/wine"
chmod +x "$BOTTLES_WINE_DIR/bin/wine"

# Invalid / empty directory should not be detected
INVALID_DIR="$HOME/.local/share/bottles/runners/not-a-runner"
mkdir -p "$INVALID_DIR"

"$KETTLE" runners refresh

assert_symlink_points_to "$RUNNERS_DIR/bottles/wine-ge-8-26" "$BOTTLES_WINE_DIR"
[[ ! -e "$RUNNERS_DIR/bottles/not-a-runner" && ! -L "$RUNNERS_DIR/bottles/not-a-runner" ]] || fail "invalid runner was indexed"

# Test system wine detection
SYSTEM_WINE_BIN="$TEST_ROOT/bin/wine"
cat << 'EOF' > "$SYSTEM_WINE_BIN"
#!/usr/bin/env bash
echo "mock wine"
EOF
chmod +x "$SYSTEM_WINE_BIN"

"$KETTLE" runners refresh
assert_symlink_points_to "$RUNNERS_DIR/system/wine" "$SYSTEM_WINE_BIN"

echo "=== Test 3: Missing provider directories (lazy creation) ==="
# Nix, Bottles, Lutris, Custom, and flatpak locations without runners should NOT be created
[[ ! -d "$RUNNERS_DIR/nix" ]] || fail "nix directory was created despite no runners"
[[ ! -d "$RUNNERS_DIR/custom" ]] || fail "custom directory was created despite being empty"

echo "=== Test 4: Creating a new symlink ==="
HEROIC_WINE_DIR="$HOME/.config/heroic/tools/wine/wine-staging-9.0"
mkdir -p "$HEROIC_WINE_DIR/bin"
touch "$HEROIC_WINE_DIR/bin/wine"
chmod +x "$HEROIC_WINE_DIR/bin/wine"

"$KETTLE" runners refresh
assert_symlink_points_to "$RUNNERS_DIR/heroic/wine-staging-9.0" "$HEROIC_WINE_DIR"

echo "=== Test 5: Already-correct symlink ==="
# Running refresh again should not fail or change valid links
stat_before="$(stat -c %Y "$RUNNERS_DIR/heroic/wine-staging-9.0")"
"$KETTLE" runners refresh
stat_after="$(stat -c %Y "$RUNNERS_DIR/heroic/wine-staging-9.0")"
assert_symlink_points_to "$RUNNERS_DIR/heroic/wine-staging-9.0" "$HEROIC_WINE_DIR"

echo "=== Test 6: Incorrect / stale symlink ==="
# When source is removed, stale link is removed
rm -rf "$HEROIC_WINE_DIR"
"$KETTLE" runners refresh
[[ ! -e "$RUNNERS_DIR/heroic/wine-staging-9.0" && ! -L "$RUNNERS_DIR/heroic/wine-staging-9.0" ]] || fail "stale link was not removed"

# When a symlink points to the wrong target, it gets corrected
HEROIC_NEW_DIR="$HOME/.config/heroic/tools/wine/wine-staging-9.0"
mkdir -p "$HEROIC_NEW_DIR/bin"
touch "$HEROIC_NEW_DIR/bin/wine"
chmod +x "$HEROIC_NEW_DIR/bin/wine"
# Create intentionally wrong symlink
ln -sfn "/nonexistent/path" "$RUNNERS_DIR/heroic/wine-staging-9.0"
"$KETTLE" runners refresh
assert_symlink_points_to "$RUNNERS_DIR/heroic/wine-staging-9.0" "$HEROIC_NEW_DIR"

echo "=== Test 7: Duplicate runner names across different providers ==="
# Same runner name under Steam and Lutris
STEAM_SHARED_RUNNER="$STEAM_ROOT/compatibilitytools.d/Proton-Shared"
mkdir -p "$STEAM_SHARED_RUNNER"
touch "$STEAM_SHARED_RUNNER/compatibilitytool.vdf"

LUTRIS_SHARED_RUNNER="$HOME/.local/share/lutris/runners/wine/Proton-Shared"
mkdir -p "$LUTRIS_SHARED_RUNNER"
touch "$LUTRIS_SHARED_RUNNER/compatibilitytool.vdf"

"$KETTLE" runners refresh
assert_symlink_points_to "$RUNNERS_DIR/steam/Proton-Shared" "$STEAM_SHARED_RUNNER"
assert_symlink_points_to "$RUNNERS_DIR/lutris/Proton-Shared" "$LUTRIS_SHARED_RUNNER"

echo "=== Test 8: Same-name collision within one provider ==="
# Two different sources under Steam with the same name: one in compatibilitytools.d and one in Steam library
STEAM_LIB_RUNNER="$STEAM_ROOT/steamapps/common/Proton-Shared"
mkdir -p "$STEAM_LIB_RUNNER"
touch "$STEAM_LIB_RUNNER/compatibilitytool.vdf"

"$KETTLE" runners refresh
assert_symlink_points_to "$RUNNERS_DIR/steam/Proton-Shared" "$STEAM_SHARED_RUNNER"
assert_symlink_points_to "$RUNNERS_DIR/steam/Proton-Shared (1)" "$STEAM_LIB_RUNNER"

echo "=== Test 9: Re-running refresh produces the same result ==="
output_1="$("$KETTLE" runners list)"
output_2="$("$KETTLE" runners list)"
assert_equals "$output_1" "$output_2"

echo "=== Test 10: External source files are never modified or removed ==="
[[ -f "$STEAM_TOOL_DIR/proton" ]] || fail "external file modified/removed"
[[ -f "$HEROIC_TOOL_DIR/compatibilitytool.vdf" ]] || fail "external file modified/removed"
[[ -f "$LUTRIS_TOOL_DIR/files/bin/wine" ]] || fail "external file modified/removed"
[[ -f "$BOTTLES_WINE_DIR/bin/wine" ]] || fail "external file modified/removed"
[[ -f "$SYSTEM_WINE_BIN" ]] || fail "external file modified/removed"
[[ -f "$STEAM_SHARED_RUNNER/compatibilitytool.vdf" ]] || fail "external file modified/removed"
[[ -f "$LUTRIS_SHARED_RUNNER/compatibilitytool.vdf" ]] || fail "external file modified/removed"
[[ -f "$STEAM_LIB_RUNNER/compatibilitytool.vdf" ]] || fail "external file modified/removed"

echo "ALL TESTS PASSED!"
