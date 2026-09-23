#!/usr/bin/env bash
# kettle - Steam game launcher with auto-generated wrapper scripts

#--[Configuration]-----------------------------------------------------------

WRAPPER_DIR="$HOME/.local/share/kettle/wrappers"
SYMLINK_DIR="$HOME/.local/bin"

# Manifest names to skip when listing games (glob patterns)
EXCLUDED_NAME_PATTERNS=(
    "Steam Linux Runtime*"
    "Proton*"
    "Steamworks Common Redistributables"
)

# Custom (sideloaded, non-Steam) games — launched via umu-run + Proton
CUSTOM_REGISTRY="$HOME/.local/share/kettle/custom_games.json"
CUSTOM_PREFIX_DIR="$HOME/.local/share/kettle/prefixes"
CUSTOM_WRAPPER_DIR="$HOME/.local/share/kettle/custom_wrappers"
CUSTOM_GAME_DEPS=(jq umu-run)

# Shared prefix for `kettle run` — one-off launches never touch custom_games.json,
# but still get a persistent WINEPREFIX so dependencies aren't reinstalled every run
RUN_PREFIX="$CUSTOM_PREFIX_DIR/kettle-run"
RUN_DEPS=(umu-run)

# Per-slug overrides (mangohud, offload) for custom games only — Steam-library
# games run inside Steam's own pressure-vessel container and can't be reached
# from a kettle wrapper; see kettle help
SETTINGS_REGISTRY="$HOME/.local/share/kettle/settings.json"

# Prefix gallery — one browsable place for every wine prefix on the machine.
# Symlinks point OUT at the real prefixes; nothing is ever moved and no launcher
# writes through the gallery. Sources whose own directories are already keyed by
# human-readable names get one static pointer; Steam and Hydra are enumerated
# because both are keyed by numeric ID (appid / hydra objectId).
GAMES_SAVES_DIR="$HOME/Games/saves"
GAMES_LIBRARY_DIR="$HOME/Games/library"
PREFIX_GALLERY="$HOME/Games/prefixes"
PREFIX_STEAM_DIR="$PREFIX_GALLERY/steam"
PREFIX_HYDRA_DIR="$PREFIX_GALLERY/hydra"
RUNNERS_DIR="${RUNNERS_DIR:-$HOME/Games/runners}"
PREFIX_SOURCES=(
    "heroic:$HOME/Games/Heroic/Prefixes/default"
    "umu:$HOME/Games/umu"
    "kettle:$CUSTOM_PREFIX_DIR"
)

# Hydra keys prefixes by numeric objectId (Steam appid for shop:"steam" entries,
# but these are Hydra-managed sideloads, never Steam-installed — no relation to
# STEAM_ROOT/compatdata). Names live in a real LevelDB (hydra-db), unreadable
# without pulling in node + classic-level, so entries are labeled via
# inspect_prefix's save/config discovery instead, falling back to the raw
# objectId when nothing is found — see sync_hydra_prefixes.
HYDRA_PREFIX_DIR="$HOME/.config/hydralauncher/wine-prefixes"

#--[Dependencies]--------------------------------------------------------------

# Verify required binaries are on PATH; exit with one clear error if not
check_deps() {
    local dep missing=()
    for dep in "$@"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: missing required dependencies: ${missing[*]}" >&2
        echo "Install them (e.g. add to NixOS systemPackages) and try again." >&2
        exit 1
    fi
}

#--[Steam Detection]---------------------------------------------------------

# Auto-detect Steam installation
detect_steam_root() {
    for path in \
        "$HOME/.local/share/Steam" \
        "$HOME/.steam/steam" \
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        if [[ -d "$path/steamapps" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

STEAM_ROOT="${STEAM_ROOT:-$(detect_steam_root)}"

if [[ -z "$STEAM_ROOT" ]] || [[ ! -d "$STEAM_ROOT/steamapps" ]]; then
    echo "Error: Steam installation not found. Set STEAM_ROOT env variable if using custom location."
    exit 1
fi

# Proton build for custom (non-Steam) games — reuses whatever Proton Steam
# already manages, so custom games don't depend on a separate launcher
detect_proton_path() {
    local dir candidate
    for candidate in UMU-Proton GE-Proton; do
        dir=$(find "$STEAM_ROOT/compatibilitytools.d" -mindepth 1 -maxdepth 1 \
            -type d -name "$candidate-*" -printf '%f\n' 2>/dev/null | sort -V | tail -n 1)
        [[ -n "$dir" ]] && { echo "$STEAM_ROOT/compatibilitytools.d/$dir"; return 0; }
    done

    dir="$STEAM_ROOT/steamapps/common/Proton - Experimental"
    [[ -d "$dir" ]] && { echo "$dir"; return 0; }
    dir=$(find "$STEAM_ROOT/steamapps/common" -mindepth 1 -maxdepth 1 \
        -type d -name 'Proton *' -printf '%f\n' 2>/dev/null | sort -V | tail -n 1)
    [[ -n "$dir" ]] && { echo "$STEAM_ROOT/steamapps/common/$dir"; return 0; }
    return 1
}

PROTON_PATH="${PROTON_PATH:-$(detect_proton_path)}"

#--[Game Listing]-------------------------------------------------------------

# Skip runtime/tool manifests per EXCLUDED_NAME_PATTERNS
is_excluded_name() {
    local name="$1" pattern
    for pattern in "${EXCLUDED_NAME_PATTERNS[@]}"; do
        [[ "$name" == $pattern ]] && return 0
    done
    return 1
}

# Parse game info from manifest files
list_games() {
    local appid name
    for manifest in "$STEAM_ROOT/steamapps"/appmanifest_*.acf; do
        [[ ! -f "$manifest" ]] && continue

        appid=$(grep -m1 '"appid"' "$manifest" | sed 's/.*"appid"[[:space:]]*"\([0-9]*\)"/\1/')
        name=$(grep -m1 '"name"' "$manifest" | sed 's/.*"name"[[:space:]]*"\(.*\)"/\1/')

        if [[ -z "$appid" ]] || [[ -z "$name" ]]; then
            echo "Warning: skipping malformed manifest: $manifest" >&2
            continue
        fi

        is_excluded_name "$name" && continue

        echo "$appid|$name"
    done | sort -t'|' -k2
}

#--[Name Transforms]----------------------------------------------------------

# Generate initials from name (returns empty if single-char)
get_initials() {
    local name="$1"
    # Remove apostrophes and special chars, split on spaces, take first letter of each word
    local initials=$(echo "$name" | tr -d "'" | sed 's/[^a-zA-Z0-9 ]//g' | awk '{for(i=1;i<=NF;i++) printf tolower(substr($i,1,1))}')
    # Only return if 2+ chars (single-word games don't need aliases)
    [[ ${#initials} -ge 2 ]] && echo "$initials"
}

# Generate slug from name
get_slug() {
    local name="$1"
    # Remove apostrophes first, then convert to slug
    echo "$name" | tr -d "'" | tr '[:upper:]' '[:lower:]' | sed "s/[^a-z0-9]/-/g" | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
}

# Normalize a raw title for storage: lowercase, whitespace collapsed to '-'.
# Used by `add` and `edit` before deriving a slug via get_slug.
normalize_title() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:blank:]' '-'
}

#--[Wrapper Generation]-------------------------------------------------------

# Install generated content only when it changed. Rendering through a temporary
# file keeps an interrupted generation from leaving a partial wrapper behind.
write_generated_wrapper() {
    local wrapper_path="$1" temp_path
    temp_path=$(mktemp "${wrapper_path}.tmp.XXXXXX") || return 1
    if ! cat > "$temp_path"; then
        rm -f "$temp_path"
        return 1
    fi
    if [[ -f "$wrapper_path" ]] && cmp -s "$temp_path" "$wrapper_path"; then
        rm -f "$temp_path"
    elif ! mv -f -- "$temp_path" "$wrapper_path"; then
        rm -f "$temp_path"
        return 1
    fi
    chmod +x "$wrapper_path"
}

# Ensure a wrapper symlink points at the requested target without touching an
# already-correct link.
ensure_wrapper_symlink() {
    local target="$1" link="$2"
    [[ -L "$link" && "$(readlink "$link")" == "$target" ]] && return 0
    ln -sfn -- "$target" "$link"
}

# Create a single wrapper script and symlink
create_wrapper() {
    local name="$1"
    local appid="$2"
    local wrapper_path="$WRAPPER_DIR/$name"
    local symlink_path="$SYMLINK_DIR/$name"

    # Create wrapper script
    if ! write_generated_wrapper "$wrapper_path" <<EOF
#!/usr/bin/env bash
# kettle-generated
exec steam -applaunch $appid "\$@"
EOF
    then
        echo "Warning: failed to write wrapper $wrapper_path" >&2
        return 1
    fi

    if ! chmod +x "$wrapper_path"; then
        echo "Warning: failed to chmod $wrapper_path" >&2
        return 1
    fi

    # Create symlink
    if ! ensure_wrapper_symlink "$wrapper_path" "$symlink_path"; then
        echo "Warning: failed to symlink $symlink_path" >&2
        return 1
    fi
}

# Create wrapper scripts and symlinks
init_wrappers() {
    # Ensure directories exist
    if ! mkdir -p "$WRAPPER_DIR"; then
        echo "Warning: failed to create $WRAPPER_DIR, skipping wrapper refresh" >&2
        return 1
    fi
    if ! mkdir -p "$SYMLINK_DIR"; then
        echo "Warning: failed to create $SYMLINK_DIR, skipping wrapper refresh" >&2
        return 1
    fi

    # Get list of current games
    local current_wrappers=()
    while IFS='|' read -r appid name; do
        local initials=$(get_initials "$name")
        local slug=$(get_slug "$name")

        [[ -n "$initials" ]] && current_wrappers+=("$initials")
        current_wrappers+=("$slug")
    done < <(list_games)

    # Clean up old wrappers that don't exist in current games
    if [[ -d "$WRAPPER_DIR" ]]; then
        for wrapper in "$WRAPPER_DIR"/*; do
            [[ ! -f "$wrapper" ]] && continue
            local basename=$(basename "$wrapper")
            local found=0
            for current in "${current_wrappers[@]}"; do
                if [[ "$basename" == "$current" ]]; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                rm -f "$wrapper"
                rm -f "$SYMLINK_DIR/$basename"
            fi
        done
    fi

    # Remove broken symlinks in SYMLINK_DIR
    for link in "$SYMLINK_DIR"/*; do
        [[ -L "$link" ]] && [[ ! -e "$link" ]] && rm -f "$link"
    done

    # Create wrappers and symlinks for current games
    while IFS='|' read -r appid name; do
        local initials=$(get_initials "$name")
        local slug=$(get_slug "$name")

        [[ -n "$initials" ]] && create_wrapper "$initials" "$appid"
        create_wrapper "$slug" "$appid"
    done < <(list_games)

    # Self-heal custom (sideloaded) games the same way: their wrapper/symlink
    # only gets (re)written at `add`/`edit` time otherwise, so a wiped
    # CUSTOM_WRAPPER_DIR or a manually-deleted symlink would silently break
    # the launcher until the user re-ran `edit`.
    local custom_slug custom_title custom_exe custom_entry custom_prefix
    while IFS='|' read -r custom_slug custom_title custom_exe; do
        custom_entry=$(get_custom_game "$custom_slug") || continue
        custom_prefix="${custom_entry#*|}"
        create_custom_wrapper "$custom_slug" "$custom_exe" "$custom_prefix"
    done < <(list_custom_games)
}

#--[Resolution]----------------------------------------------------------------

# Resolve slug/initials to appid
get_appid() {
    local target="$1"
    while IFS='|' read -r appid name; do
        local slug=$(get_slug "$name")
        local initials=$(get_initials "$name")
        if [[ "$slug" == "$target" ]] || [[ "$initials" == "$target" ]]; then
            echo "$appid"
            return 0
        fi
    done < <(list_games)
    return 1
}

# Get installdir from appid. Returns 1 if not found so callers never
# act on an empty value (e.g. an unqualified pkill pattern).
get_installdir() {
    local appid="$1" installdir
    installdir=$(grep -m1 '"installdir"' "$STEAM_ROOT/steamapps/appmanifest_$appid.acf" 2>/dev/null | \
        sed 's/.*"installdir"[[:space:]]*"\(.*\)"/\1/')
    [[ -z "$installdir" ]] && return 1
    echo "$installdir"
}

#--[Custom Games]---------------------------------------------------------------

# Ensure the custom games registry file exists
init_custom_registry() {
    mkdir -p "$(dirname "$CUSTOM_REGISTRY")"
    [[ -f "$CUSTOM_REGISTRY" ]] || echo '{}' > "$CUSTOM_REGISTRY"
}

# Normalize directory names under Games/library (e.g. "Hollow Knight" -> "hollow-knight")
# and update any matching executable paths in custom_games.json before pruning
clean_game_library() {
    [[ -d "$GAMES_LIBRARY_DIR" ]] || return 0
    local dir name slug old_path new_path
    for dir in "$GAMES_LIBRARY_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "${dir%/}")
        slug=$(get_slug "$name")
        [[ -z "$slug" || "$name" == "$slug" ]] && continue

        old_path="$GAMES_LIBRARY_DIR/$name"
        new_path="$GAMES_LIBRARY_DIR/$slug"

        if [[ -e "$new_path" ]]; then
            echo "Warning: cannot rename $old_path to $new_path (target already exists)" >&2
            continue
        fi

        if mv -- "$old_path" "$new_path"; then
            if [[ -f "$CUSTOM_REGISTRY" ]]; then
                if jq --arg old "$old_path" --arg new "$new_path" \
                    'map_values(if .executable and ((.executable == $old) or (.executable | startswith($old + "/"))) then .executable = ($new + (.executable | ltrimstr($old))) else . end)' \
                    "$CUSTOM_REGISTRY" > "$CUSTOM_REGISTRY.tmp" 2>/dev/null; then
                    mv "$CUSTOM_REGISTRY.tmp" "$CUSTOM_REGISTRY"
                else
                    rm -f "$CUSTOM_REGISTRY.tmp"
                fi
            fi
        fi
    done
}

# Remove custom game entries whose executable no longer exists on disk
# (self-healing: nothing else notices when a sideloaded game is deleted)
prune_custom_games() {
    clean_game_library
    init_custom_registry
    local slug _title exe stale=()
    while IFS='|' read -r slug _title exe; do
        [[ -f "$exe" ]] && continue
        stale+=("$slug")
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.title)|\(.value.executable)"' "$CUSTOM_REGISTRY")

    for slug in "${stale[@]}"; do
        rm -f "$CUSTOM_WRAPPER_DIR/$slug" "$SYMLINK_DIR/$slug"
        if jq --arg k "$slug" 'del(.[$k])' "$CUSTOM_REGISTRY" > "$CUSTOM_REGISTRY.tmp"; then
            mv "$CUSTOM_REGISTRY.tmp" "$CUSTOM_REGISTRY"
        else
            rm -f "$CUSTOM_REGISTRY.tmp"
        fi
    done
}

# List custom games as slug|title|executable
list_custom_games() {
    init_custom_registry
    prune_custom_games
    jq -r 'to_entries[] | "\(.key)|\(.value.title)|\(.value.executable)"' "$CUSTOM_REGISTRY" 2>/dev/null
}

# Look up a custom game's executable + prefix by slug
get_custom_game() {
    local slug="$1"
    init_custom_registry
    jq -r --arg k "$slug" '.[$k] | select(. != null) | "\(.executable)|\(.prefix)"' "$CUSTOM_REGISTRY"
}

# Look up a custom game's title + executable + prefix by slug (kettle edit)
get_custom_game_full() {
    local slug="$1"
    init_custom_registry
    jq -r --arg k "$slug" \
        '.[$k] | select(. != null) | "\(.title)|\(.executable)|\(.prefix)"' \
        "$CUSTOM_REGISTRY"
}

#--[Settings Registry]-----------------------------------------------------------

# Ensure the per-slug settings registry file exists
init_settings_registry() {
    mkdir -p "$(dirname "$SETTINGS_REGISTRY")"
    [[ -f "$SETTINGS_REGISTRY" ]] || echo '{}' > "$SETTINGS_REGISTRY"
}

# Read a per-slug setting; echoes $default when unset
get_setting() {
    local slug="$1" key="$2" default="$3" value
    init_settings_registry
    value=$(jq -r --arg k "$slug" --arg key "$key" '.[$k][$key] // empty' "$SETTINGS_REGISTRY" 2>/dev/null)
    [[ -n "$value" ]] && echo "$value" || echo "$default"
}

# Write a per-slug setting (atomic tmp-then-mv, mirrors add_custom_game)
set_setting() {
    local slug="$1" key="$2" value="$3"
    init_settings_registry
    if ! jq --arg k "$slug" --arg key "$key" --argjson v "$value" \
        '.[$k] = ((.[$k] // {}) + {($key): $v})' \
        "$SETTINGS_REGISTRY" > "$SETTINGS_REGISTRY.tmp"; then
        echo "Error: failed to update registry $SETTINGS_REGISTRY" >&2
        rm -f "$SETTINGS_REGISTRY.tmp"
        exit 1
    fi
    mv "$SETTINGS_REGISTRY.tmp" "$SETTINGS_REGISTRY"
}

#--[Env Injection]---------------------------------------------------------------

# Compose the launch-command prefix (nvidia-offload, mangohud) for a custom
# game slug, based on per-slug settings.json overrides. A prefix is silently
# omitted if its binary isn't on PATH, so wrappers regenerate portably on a
# machine without a dGPU or without mangohud installed.
kettle_exec_prefix() {
    local slug="$1" prefix=""
    if [[ "$(get_setting "$slug" offload 1)" == 1 ]] && command -v nvidia-offload >/dev/null 2>&1; then
        prefix+="nvidia-offload "
    fi
    if [[ "$(get_setting "$slug" mangohud 0)" == 1 ]] && command -v mangohud >/dev/null 2>&1; then
        prefix+="mangohud "
    fi
    echo "$prefix"
}

# Create a wrapper that launches an exe via umu-run under Proton, and symlink it
create_custom_wrapper() {
    local slug="$1" exe="$2" prefix="$3"
    local wrapper_path="$CUSTOM_WRAPPER_DIR/$slug"
    local symlink_path="$SYMLINK_DIR/$slug"
    local exec_prefix
    exec_prefix=$(kettle_exec_prefix "$slug")

    # exe/prefix are user-supplied paths (kettle add/edit) — %q-escape before
    # interpolating into the generated script so a quote/$/backtick in either
    # can't break out of the string or inject commands into the wrapper.
    local exe_q prefix_q
    printf -v exe_q '%q' "$exe"
    printf -v prefix_q '%q' "$prefix"

    mkdir -p "$CUSTOM_WRAPPER_DIR" "$SYMLINK_DIR" "$prefix"

    if ! write_generated_wrapper "$wrapper_path" <<EOF
#!/usr/bin/env bash
# kettle-generated (custom/sideload)
if ! command -v umu-run >/dev/null 2>&1; then
    echo "Error: missing required dependency: umu-run" >&2
    exit 1
fi
export WINEPREFIX=$prefix_q
export GAMEID="\${GAMEID:-umu-default}"
if [[ -z "\${PROTONPATH:-}" ]]; then
    for _family in UMU-Proton GE-Proton; do
        _d=\$(find "$STEAM_ROOT/compatibilitytools.d" -mindepth 1 -maxdepth 1 \\
            -type d -name "\${_family}-*" -printf '%f\\n' 2>/dev/null | sort -V | tail -n 1)
        if [[ -n "\$_d" ]]; then
            export PROTONPATH="$STEAM_ROOT/compatibilitytools.d/\$_d"
            break
        fi
    done
fi
if [[ -z "\${PROTONPATH:-}" && -d "$STEAM_ROOT/steamapps/common/Proton - Experimental" ]]; then
    export PROTONPATH="$STEAM_ROOT/steamapps/common/Proton - Experimental"
fi
if [[ -z "\${PROTONPATH:-}" ]]; then
    _d=\$(find "$STEAM_ROOT/steamapps/common" -mindepth 1 -maxdepth 1 \\
        -type d -name 'Proton *' -printf '%f\\n' 2>/dev/null | sort -V | tail -n 1)
    [[ -n "\$_d" ]] && export PROTONPATH="$STEAM_ROOT/steamapps/common/\$_d"
fi
if [[ -z "\${PROTONPATH:-}" ]]; then
    echo "Error: no Proton build found under $STEAM_ROOT" >&2
    exit 1
fi
_exe=$exe_q
_working_dir=\$(dirname -- "\$_exe")
_exe_name=\$(basename -- "\$_exe")
if ! cd -- "\$_working_dir"; then
    echo "Error: could not set working directory: \$_working_dir" >&2
    exit 1
fi
exec ${exec_prefix}umu-run "./\$_exe_name" "\$@"
EOF
    then
        echo "Warning: failed to write wrapper $wrapper_path" >&2
        return 1
    fi

    ensure_wrapper_symlink "$wrapper_path" "$symlink_path" || {
        echo "Warning: failed to symlink $symlink_path" >&2
        return 1
    }
}

# Register a new custom (sideloaded) game and generate its wrapper. If
# prefix_override is set (from `add --prefix`), reuse that existing prefix
# path instead of minting a fresh one under CUSTOM_PREFIX_DIR.
add_custom_game() {
    local title="$1" exe="$2" prefix_override="${3:-}"
    check_deps "${CUSTOM_GAME_DEPS[@]}"

    if [[ -z "$PROTON_PATH" ]]; then
        echo "Error: no Proton build found under $STEAM_ROOT (checked compatibilitytools.d and steamapps/common)" >&2
        exit 1
    fi

    if [[ ! -f "$exe" ]]; then
        echo "Error: executable not found: $exe" >&2
        exit 1
    fi

    local slug prefix
    slug=$(get_slug "$title")
    if [[ -z "$slug" ]]; then
        echo "Error: could not derive a slug from name: $title" >&2
        exit 1
    fi
    prefix="${prefix_override:-$CUSTOM_PREFIX_DIR/$slug}"

    init_custom_registry
    if ! jq --arg k "$slug" --arg title "$title" --arg exe "$exe" --arg prefix "$prefix" \
        '.[$k] = {title: $title, executable: $exe, prefix: $prefix}' \
        "$CUSTOM_REGISTRY" > "$CUSTOM_REGISTRY.tmp"; then
        echo "Error: failed to update registry $CUSTOM_REGISTRY" >&2
        rm -f "$CUSTOM_REGISTRY.tmp"
        exit 1
    fi
    mv "$CUSTOM_REGISTRY.tmp" "$CUSTOM_REGISTRY"

    create_custom_wrapper "$slug" "$exe" "$prefix"
    kettle_status_line + "$slug"
}

#--[Prefix Gallery]--------------------------------------------------------------

# Point PREFIX_GALLERY at each source in PREFIX_SOURCES. Uses `ln -sfn`, not
# `-sf` — with `-sf`, re-running against an existing symlink-to-directory drops
# the new link INSIDE that directory instead of replacing it. Sources that don't
# exist on this machine (e.g. no Heroic installed) are skipped, not errored.
sync_prefix_pointers() {
    mkdir -p "$GAMES_SAVES_DIR" "$GAMES_LIBRARY_DIR" "$PREFIX_GALLERY"
    local entry name target
    for entry in "${PREFIX_SOURCES[@]}"; do
        name="${entry%%:*}"
        target="${entry#*:}"
        [[ -d "$target" ]] || continue
        ln -sfn "$target" "$PREFIX_GALLERY/$name"
    done
}

# Enumerate Steam-library prefixes by name into PREFIX_STEAM_DIR. Driven off
# list_games() (manifests), not compatdata/ directly, so Proton-internal builds
# are excluded via EXCLUDED_NAME_PATTERNS and orphaned/synthetic compatdata
# entries with no manifest never appear. Prunes stale links via set difference
# (not broken-link check) since an uninstalled game's compatdata often survives
# its manifest.
sync_steam_prefixes() {
    mkdir -p "$PREFIX_STEAM_DIR"
    local appid name pfx link_name wanted=() claimed=()
    while IFS='|' read -r appid name; do
        claimed+=("$appid")
        pfx="$STEAM_ROOT/steamapps/compatdata/$appid/pfx"
        [[ -d "$pfx" ]] || continue
        link_name="$name"
        if [[ -e "$PREFIX_STEAM_DIR/$link_name" ]] && [[ " ${wanted[*]} " == *" $link_name "* ]]; then
            link_name="$name ($appid)"
        fi
        ln -sfn "$pfx" "$PREFIX_STEAM_DIR/$link_name"
        wanted+=("$link_name")
    done < <(list_games)

    # Claim every appid with a manifest at all — including ones list_games()
    # itself hides via EXCLUDED_NAME_PATTERNS (Proton*, runtimes) — so the
    # fallback pass below never re-surfaces those as an unidentified "game".
    local manifest mid
    for manifest in "$STEAM_ROOT/steamapps"/appmanifest_*.acf; do
        [[ -f "$manifest" ]] || continue
        mid=$(grep -m1 -oP '"appid"\s*"\K[0-9]+' "$manifest")
        [[ -n "$mid" ]] && claimed+=("$mid")
    done

    # Non-Steam shortcuts get a compatdata dir too but no manifest — their
    # metadata lives in binary shortcuts.vdf, not worth parsing. Resolve a
    # label via inspect_prefix's save/config discovery instead; fall back to
    # the raw appid if nothing is found. Numeric suffix on collision per user
    # request, since a raw-appid fallback has no natural disambiguator like the
    # named branch's "(appid)" above.
    local dir id ipfx label n
    for dir in "$STEAM_ROOT/steamapps/compatdata"/*/; do
        [[ -d "$dir" ]] || continue
        id=$(basename "${dir%/}")
        [[ " ${claimed[*]} " == *" $id "* ]] && continue
        ipfx="${dir%/}/pfx"
        [[ -d "$ipfx/drive_c" ]] || continue
        label=$(inspect_prefix "$ipfx" 2>/dev/null | head -1)
        [[ -z "$label" || "$label" == "(nothing found)" ]] && label="$id"
        link_name="$label"
        n=1
        while [[ " ${wanted[*]} " == *" $link_name "* ]]; do
            link_name="$label ($n)"
            ((n++))
        done
        ln -sfn "$ipfx" "$PREFIX_STEAM_DIR/$link_name"
        wanted+=("$link_name")
    done

    local link base
    for link in "$PREFIX_STEAM_DIR"/*; do
        [[ -e "$link" || -L "$link" ]] || continue
        base=$(basename "$link")
        [[ " ${wanted[*]} " == *" $base "* ]] || rm -f "$link"
    done
}

# Enumerate Hydra-managed prefixes into PREFIX_HYDRA_DIR. No manifest exists to
# name these (see HYDRA_PREFIX_DIR comment on why hydra-db isn't readable), so
# each is resolved the same way as unclaimed Steam compatdata entries: run
# inspect_prefix's save/config discovery and fall back to the raw objectId if
# nothing is found. Numeric suffix on collision. Skipped entirely if Hydra
# isn't installed on this machine.
sync_hydra_prefixes() {
    [[ -d "$HYDRA_PREFIX_DIR" ]] || return 0
    mkdir -p "$PREFIX_HYDRA_DIR"
    local dir id label link_name n wanted=()
    for dir in "$HYDRA_PREFIX_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        id=$(basename "${dir%/}")
        if [[ -d "${dir%/}/drive_c" ]]; then
            label=$(inspect_prefix "${dir%/}" 2>/dev/null | head -1)
        else
            label=""
        fi
        [[ -z "$label" || "$label" == "(nothing found)" ]] && label="$id"
        link_name="$label"
        n=1
        while [[ " ${wanted[*]} " == *" $link_name "* ]]; do
            link_name="$label ($n)"
            ((n++))
        done
        ln -sfn "${dir%/}" "$PREFIX_HYDRA_DIR/$link_name"
        wanted+=("$link_name")
    done

    local link base
    for link in "$PREFIX_HYDRA_DIR"/*; do
        [[ -e "$link" || -L "$link" ]] || continue
        base=$(basename "$link")
        [[ " ${wanted[*]} " == *" $base "* ]] || rm -f "$link"
    done
}

# Enumerate every prefix in the gallery, flat, one line each:
# source<TAB>name<TAB>real_path (real_path empty if the entry is dangling).
# Single source of truth consumed by both list_prefix_gallery and `kettle rm`.
walk_prefix_gallery() {
    local entry source path child cname real
    for entry in "${PREFIX_SOURCES[@]}"; do
        source="${entry%%:*}"
        path="$PREFIX_GALLERY/$source"
        [[ -e "$path" ]] || continue
        for child in "$path"/*/; do
            [[ -e "$child" ]] || continue
            cname=$(basename "$child")
            real=$(readlink -f "$child")
            printf '%s\t%s\t%s\n' "$source" "$cname" "$real"
        done
    done
    local link base
    for link in "$PREFIX_STEAM_DIR"/*; do
        [[ -e "$link" || -L "$link" ]] || continue
        base=$(basename "$link")
        if [[ -e "$link" ]]; then
            printf '%s\t%s\t%s\n' "steam" "$base" "$(readlink -f "$link")"
        else
            printf '%s\t%s\t%s\n' "steam" "$base" ""
        fi
    done
    for link in "$PREFIX_HYDRA_DIR"/*; do
        [[ -e "$link" || -L "$link" ]] || continue
        base=$(basename "$link")
        if [[ -e "$link" ]]; then
            printf '%s\t%s\t%s\n' "hydra" "$base" "$(readlink -f "$link")"
        else
            printf '%s\t%s\t%s\n' "hydra" "$base" ""
        fi
    done
}

# Build the flat, space-free label for a gallery entry: source_name, with any
# whitespace in the name collapsed to '-'. Single source of truth so display
# (list_prefix_gallery) and resolution (prefix rm) never drift apart.
gallery_label() {
    local source="$1" name="$2"
    echo "${source}_${name// /-}"
}

# Resolve a gallery label (e.g. "steam_Half-Life-2") to its real prefix path.
# Exact match first, case-insensitive fallback second — same two-pass lookup
# `prefix rm` used before this was extracted. Echoes the resolved path and
# returns 0 on a single match. On no match: prints an error unless "$2" is
# "quiet" (callers that want to fall back to treating $1 as a literal path
# instead), and returns 1. On an ambiguous match: always prints an error
# (actionable regardless of quiet mode) and returns 2, so callers can tell
# "not found" apart from "found too many" and only fall through on the former.
resolve_gallery_prefix() {
    local target="$1" quiet="${2:-}" source_ target_name real label_
    local -a matches=()
    while IFS=$'\t' read -r source_ target_name real; do
        [[ -n "$real" ]] || continue
        label_=$(gallery_label "$source_" "$target_name")
        [[ "$label_" == "$target" ]] && matches+=("$label_|$real")
    done < <(walk_prefix_gallery)
    if [[ ${#matches[@]} -eq 0 ]]; then
        while IFS=$'\t' read -r source_ target_name real; do
            [[ -n "$real" ]] || continue
            label_=$(gallery_label "$source_" "$target_name")
            [[ "${label_,,}" == "${target,,}" ]] && matches+=("$label_|$real")
        done < <(walk_prefix_gallery)
    fi
    if [[ ${#matches[@]} -eq 0 ]]; then
        [[ "$quiet" == quiet ]] || echo "Unknown prefix: $target (see 'kettle prefixes')" >&2
        return 1
    fi
    if [[ ${#matches[@]} -gt 1 ]]; then
        echo "Ambiguous prefix: $target — matches:" >&2
        printf '  %s\n' "${matches[@]%%|*}" >&2
        return 2
    fi
    echo "${matches[0]#*|}"
}

# Resolve a prefix field/flag value to a real path: gallery label first
# (quiet — a miss isn't an error here), literal path fallback second. An
# ambiguous gallery match is still a hard error either way — only a lookup
# miss falls through to path resolution.
resolve_prefix_input() {
    local target="$1" resolved rc
    resolved=$(resolve_gallery_prefix "$target" quiet)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "$resolved"
        return 0
    fi
    if [[ $rc -eq 2 ]]; then
        return 1
    fi
    target="${target/#\~/$HOME}"
    realpath -m -- "$target"
}

# Reverse of resolve_prefix_input: given a real prefix path, echo its gallery
# label if the gallery has an entry pointing at it, else echo the path
# unchanged. Used so `kettle edit` shows the friendly label a prefix was
# picked from instead of the raw path, whenever one exists.
gallery_label_for_path() {
    local path="$1" source_ target_name real
    while IFS=$'\t' read -r source_ target_name real; do
        if [[ -n "$real" && "$real" == "$path" ]]; then
            gallery_label "$source_" "$target_name"
            return 0
        fi
    done < <(walk_prefix_gallery)
    echo "$path"
}

# Print the prefix gallery flat: <source>_<name> with size. + = resolves,
# dim - = dangling (matches kettle_status_line).
list_prefix_gallery() {
    local entry name path
    for entry in "${PREFIX_SOURCES[@]}"; do
        name="${entry%%:*}"
        path="$PREFIX_GALLERY/$name"
        [[ -e "$path" ]] || kettle_status_line - "$name (not present)"
    done
    local source cname real label bytes
    local sized=() broken=()
    while IFS=$'\t' read -r source cname real; do
        label=$(gallery_label "$source" "$cname")
        if [[ -n "$real" && -d "$real" ]]; then
            bytes=$(du -sb "$real" 2>/dev/null | cut -f1)
            sized+=("${bytes:-0}"$'\t'"$label")
        else
            broken+=("$label")
        fi
    done < <(walk_prefix_gallery)
    if [[ ${#sized[@]} -gt 0 ]]; then
        local sources=() games=()
        local l
        for l in "${sized[@]}"; do
            l="${l#*$'\t'}"
            sources+=("${l%%_*}")
            games+=("${l#*_}")
        done
        local src_width game_width width
        src_width=$(kettle_max_len sources)
        game_width=$(kettle_max_len games)
        width=$(( src_width + 1 + game_width ))
        local dim="" reset=""
        if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
            dim=$'\033[2m'
            reset=$'\033[0m'
        fi
        local src game size srcpad
        while IFS=$'\t' read -r bytes label; do
            src="${label%%_*}"
            game="${label#*_}"
            size=$(numfmt --to=iec --suffix=B "$bytes")
            srcpad=$(( src_width - ${#src} ))
            kettle_status_line_aligned + "${dim}$(printf '%*s' "$srcpad" "")${src}_${reset}${game}" "$(( src_width + 1 + ${#game} ))" "$width" "$size"
        done < <(printf '%s\n' "${sized[@]}" | sort -rn)
    fi
    local b
    for b in "${broken[@]}"; do
        kettle_status_line - "$b (broken)"
    done
}

# Discover what a wine prefix is for by listing (not guessing) the contents of
# the conventional save/config parent folders, glob across every users/* since
# accounts aren't standardized across sources (a Hydra prefix had both "luar"
# and "steamuser" populated). Pure `ls`/find — no wine invocation, so no risk
# of the mutation `wine uninstaller --list` caused when tested against a live
# Steam prefix (rewrote system.reg/userdef.reg, left a winedevice.exe running).
inspect_prefix() {
    local prefix="$1"
    if [[ ! -d "$prefix/drive_c" ]]; then
        echo "Error: not a wine prefix (no drive_c): $prefix" >&2
        exit 1
    fi
    local candidates=(
        "Documents/My Games"
        "AppData/Roaming"
        "AppData/Local"
        "AppData/LocalLow"
    )
    # Wine/Proton skeleton dirs present in every prefix regardless of game —
    # confirmed by checking an empty prefix (Microsoft, Temp) and a
    # dxvk-shader-cache prefix; excluded as noise, not game identity.
    local noise=(Microsoft Temp dxvk)
    local userdir sub name found=()
    for userdir in "$prefix/drive_c/users"/*/; do
        [[ -d "$userdir" ]] || continue
        for sub in "${candidates[@]}"; do
            [[ -d "$userdir$sub" ]] || continue
            while IFS= read -r name; do
                [[ " ${noise[*]} " == *" $name "* ]] && continue
                [[ " ${found[*]} " == *" $name "* ]] || found+=("$name")
            done < <(find "$userdir$sub" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
        done
    done

    if [[ ${#found[@]} -gt 0 ]]; then
        printf '%s\n' "${found[@]}"
        return
    fi

    # Tier 2: no save/config data yet (fresh or crashed-before-first-save
    # prefix) — fall back to the exe path Hydra actually launched this
    # WINEPREFIX with, per its own umu.log. Steam prefixes never appear in
    # this log (Steam doesn't launch through Hydra's umu-run), so this is a
    # no-op for them and they fall through to the raw-appid label same as
    # before.
    local umu_log="$HOME/.config/hydralauncher/logs/umu.log" exe_line exe_path
    if [[ -f "$umu_log" ]]; then
        exe_line=$(grep -F "WINEPREFIX='$prefix'" "$umu_log" 2>/dev/null | tail -1)
        if [[ -n "$exe_line" ]]; then
            exe_path=$(grep -o "'[^']*'" <<<"$exe_line" | tail -1 | tr -d "'")
            [[ -n "$exe_path" ]] && basename "$(dirname "$exe_path")" && return
        fi
    fi

    echo "(nothing found)"
}

#--[Runners Registry]-----------------------------------------------------------

# Check if a value exists in an array
kettle_in_array() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Check if a directory or binary qualifies as a valid Proton/Wine compatibility runner
is_valid_runner() {
    local path="$1"
    [[ -e "$path" ]] || return 1

    # Single binary executable (e.g. system wine)
    if [[ -f "$path" && -x "$path" ]]; then
        local base
        base=$(basename "$path")
        [[ "$base" == "wine" || "$base" == "wine64" ]] && return 0
        return 1
    fi

    [[ -d "$path" ]] || return 1

    # Proton-style runner markers
    [[ -x "$path/proton" ]] && return 0
    [[ -f "$path/compatibilitytool.vdf" ]] && return 0
    [[ -x "$path/files/bin/wine" || -x "$path/files/bin/wine64" ]] && return 0

    # Wine-style runner markers
    [[ -x "$path/bin/wine" || -x "$path/bin/wine64" ]] && return 0

    return 1
}

# Discover compatibility tools and Proton installations from Steam
discover_steam_runners() {
    local roots=() dirs=() r d lib vdf path pfx
    roots+=(
        "${STEAM_ROOT:-}"
        "$HOME/.local/share/Steam"
        "$HOME/.steam/root"
        "$HOME/.steam/steam"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    )
    dirs+=(
        "/usr/share/steam/compatibilitytools.d"
        "/usr/local/share/steam/compatibilitytools.d"
    )
    if [[ -n "${STEAM_EXTRA_COMPAT_TOOLS_PATHS:-}" ]]; then
        local extra_paths=()
        IFS=':' read -ra extra_paths <<< "$STEAM_EXTRA_COMPAT_TOOLS_PATHS"
        for pfx in "${extra_paths[@]}"; do
            [[ -n "$pfx" ]] && dirs+=("$pfx")
        done
    fi
    for r in "${roots[@]}"; do
        [[ -n "$r" && -d "$r/compatibilitytools.d" ]] && dirs+=("$r/compatibilitytools.d")
    done

    # Compatibility tools (compatibilitytools.d)
    local tool
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for tool in "$d"/*; do
            [[ -e "$tool" ]] || continue
            is_valid_runner "$tool" && echo "$tool"
        done
    done

    # Discover Steam library folders for Valve Proton
    local libraries=()
    [[ -n "${STEAM_ROOT:-}" && -d "${STEAM_ROOT:-}" ]] && libraries+=("$STEAM_ROOT")
    for r in "${roots[@]}"; do
        [[ -n "$r" && -d "$r" ]] || continue
        for vdf in "$r/steamapps/libraryfolders.vdf" "$r/config/config.vdf"; do
            [[ -f "$vdf" ]] || continue
            while IFS= read -r path; do
                [[ -d "$path" ]] && libraries+=("$path")
            done < <(grep -oP '"path"\s*"\K[^"]+' "$vdf" 2>/dev/null || sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf" 2>/dev/null)
        done
    done

    local lib_seen=() pdir
    for lib in "${libraries[@]}"; do
        local real_lib
        real_lib=$(realpath -m -- "$lib" 2>/dev/null) || real_lib="$lib"
        [[ " ${lib_seen[*]} " == *" $real_lib "* ]] && continue
        lib_seen+=("$real_lib")

        for pdir in "$lib/steamapps/common"/Proton* "$lib/steamapps/common"/proton*; do
            [[ -e "$pdir" ]] || continue
            is_valid_runner "$pdir" && echo "$pdir"
        done
    done
}

# Discover Heroic Wine/Proton runners
discover_heroic_runners() {
    local search_dirs=(
        "$HOME/.config/heroic/tools/proton"
        "$HOME/.config/heroic/tools/wine"
        "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/proton"
        "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/wine"
    )
    local d r
    for d in "${search_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for r in "$d"/*; do
            [[ -e "$r" ]] || continue
            is_valid_runner "$r" && echo "$r"
        done
    done
}

# Discover Lutris runners
discover_lutris_runners() {
    local search_dirs=(
        "$HOME/.local/share/lutris/runners/wine"
        "$HOME/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
    )
    local d r
    for d in "${search_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for r in "$d"/*; do
            [[ -e "$r" ]] || continue
            is_valid_runner "$r" && echo "$r"
        done
    done
}

# Discover Bottles runners
discover_bottles_runners() {
    local search_dirs=(
        "$HOME/.local/share/bottles/runners"
        "$HOME/.var/app/com.usebottles.bottles/data/bottles/runners"
    )
    local d r
    for d in "${search_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for r in "$d"/*; do
            [[ -e "$r" ]] || continue
            is_valid_runner "$r" && echo "$r"
        done
    done
}

# Discover system Wine binary
discover_system_runners() {
    local wine_bin
    wine_bin=$(command -v wine 2>/dev/null) || return 0
    if [[ -n "$wine_bin" && -x "$wine_bin" ]]; then
        is_valid_runner "$wine_bin" && echo "$wine_bin"
    fi
}

# Discover Nix-managed runners (without scanning /nix/store)
discover_nix_runners() {
    local profiles=() p
    if [[ -n "${NIX_PROFILES:-}" ]]; then
        read -ra profiles <<< "$NIX_PROFILES"
    fi
    profiles+=(
        "$HOME/.nix-profile"
        "/run/current-system/sw"
        "/etc/profiles/per-user/$USER"
        "/nix/var/nix/profiles/default"
    )
    local seen_p=() d r
    for p in "${profiles[@]}"; do
        [[ -d "$p" ]] || continue
        local rp
        rp=$(realpath -m -- "$p" 2>/dev/null) || rp="$p"
        [[ " ${seen_p[*]} " == *" $rp "* ]] && continue
        seen_p+=("$rp")

        for d in "$p/share/steam/compatibilitytools.d" "$p/share/compatibilitytools.d"; do
            [[ -d "$d" ]] || continue
            for r in "$d"/*; do
                [[ -e "$r" ]] || continue
                is_valid_runner "$r" && echo "$r"
            done
        done
    done
}

# Synchronize symlinks for a single runner provider
sync_provider_runners() {
    local provider="$1"
    local provider_dir="$RUNNERS_DIR/$provider"

    # custom directory is reserved for manual/external integration
    if [[ "$provider" == "custom" ]]; then
        if [[ -d "$provider_dir" ]]; then
            rmdir "$provider_dir" 2>/dev/null || true
        fi
        return 0
    fi

    local discover_fn="discover_${provider}_runners"
    declare -F "$discover_fn" >/dev/null || return 0

    local raw_targets=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && raw_targets+=("$line")
    done < <("$discover_fn")

    local real_seen=() unique_targets=() t real_t
    for t in "${raw_targets[@]}"; do
        real_t=$(realpath -m -- "$t" 2>/dev/null) || real_t="$t"
        [[ " ${real_seen[*]} " == *" $real_t "* ]] && continue
        real_seen+=("$real_t")
        unique_targets+=("$t")
    done

    # If no runners discovered, prune stale links if dir exists and remove if empty
    if [[ ${#unique_targets[@]} -eq 0 ]]; then
        if [[ -d "$provider_dir" ]]; then
            local link
            for link in "$provider_dir"/*; do
                [[ -L "$link" ]] && rm -f "$link"
            done
            rmdir "$provider_dir" 2>/dev/null || true
        fi
        return 0
    fi

    mkdir -p "$provider_dir"

    local wanted_links=() base link_name n
    for t in "${unique_targets[@]}"; do
        real_t=$(realpath -m -- "$t" 2>/dev/null) || real_t="$t"
        base=$(basename "$t")
        link_name="$base"
        n=1
        while kettle_in_array "$link_name" "${wanted_links[@]}"; do
            link_name="$base ($n)"
            ((n++))
        done
        wanted_links+=("$link_name")
        ensure_wrapper_symlink "$real_t" "$provider_dir/$link_name"
    done

    # Remove stale Kettle-created symlinks
    local link base_link
    for link in "$provider_dir"/*; do
        [[ -L "$link" ]] || continue
        base_link=$(basename "$link")
        if ! kettle_in_array "$base_link" "${wanted_links[@]}"; then
            rm -f "$link"
        fi
    done

    # Remove provider directory if left empty
    rmdir "$provider_dir" 2>/dev/null || true
}

# Synchronize all runner providers
sync_all_runners() {
    mkdir -p "$RUNNERS_DIR"
    local p
    for p in steam heroic lutris bottles nix system custom; do
        sync_provider_runners "$p"
    done
}

# List all discovered compatibility runners grouped by provider
list_runners() {
    sync_all_runners
    local p dir link items first=1 has_any=0
    for p in steam heroic lutris bottles nix system custom; do
        dir="$RUNNERS_DIR/$p"
        [[ -d "$dir" ]] || continue
        items=()
        for link in "$dir"/*; do
            [[ -e "$link" || -L "$link" ]] || continue
            items+=("$(basename "$link")")
        done
        if [[ ${#items[@]} -gt 0 ]]; then
            has_any=1
            [[ $first -eq 0 ]] && echo ""
            first=0
            echo "$p:"
            for item in "${items[@]}"; do
                echo "  $item"
            done
        fi
    done
    if [[ $has_any -eq 0 ]]; then
        echo "No compatibility runners discovered."
    fi
}

#--[Status Line]-----------------------------------------------------------------

# +=enabled, dim -=disabled. TTY-only styling; the mark itself always prints
# so piped/logged output stays greppable (grep '^+').
kettle_status_line() {
    local mark="$1" name="$2" style="" reset=""
    if [[ "$mark" == + ]]; then
        printf '%s %s\n' "$mark" "$name"
        return
    fi
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        reset=$'\033[0m'
        style=$'\033[2m'
    fi
    printf '%s%s %s%s\n' "$style" "$mark" "$name" "$reset"
}

# Longest string in an array (by nameref) — column width for aligned listings.
kettle_max_len() {
    local -n _kml_arr="$1"
    local s max=0
    for s in "${_kml_arr[@]}"; do
        (( ${#s} > max )) && max=${#s}
    done
    printf '%s' "$max"
}

# One aligned listing row: mark, primary text (already colored if needed),
# primary's *visible* length (so ANSI codes don't skew padding), column
# width from kettle_max_len, and an optional dim suffix (e.g. size, alias).
kettle_status_line_aligned() {
    local mark="$1" primary="$2" plen="$3" width="$4" suffix="${5:-}"
    if [[ -z "$suffix" ]]; then
        kettle_status_line "$mark" "$primary"
        return
    fi
    local dim="" reset="" pad=$(( width - plen ))
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        dim=$'\033[2m'
        reset=$'\033[0m'
    fi
    kettle_status_line "$mark" "$(printf '%s%*s %s%s%s' "$primary" "$pad" "" "$dim" "$suffix" "$reset")"
}

# Print effective offload/mangohud state for one custom game slug
print_settings() {
    local slug="$1" offload mangohud
    offload=$(get_setting "$slug" offload 1)
    mangohud=$(get_setting "$slug" mangohud 0)
    kettle_status_line "$([[ "$offload" == 1 ]] && echo + || echo -)" "offload:$slug"
    kettle_status_line "$([[ "$mangohud" == 1 ]] && echo + || echo -)" "mangohud:$slug"
}

#--[Subcommands]---------------------------------------------------------------

# Self-healing: every invocation re-syncs the prefix gallery before doing
# anything else, same pattern as list_custom_games() -> prune_custom_games().
# Skipped for help so --help stays instant with no filesystem side effects.
case "${1:-}" in
    help|-h|--help) ;;
    *)
        sync_prefix_pointers
        sync_steam_prefixes
        sync_hydra_prefixes
        clean_game_library
        sync_all_runners
        ;;
esac

case "${1:-}" in
    help|-h|--help)
        cat <<'EOF'
kettle - Steam game launcher with auto-generated wrapper scripts

Usage: kettle [command] [args]

Commands:
  (none)                      List available games and refresh wrappers
  steam                       Launch Steam
  big, bigpicture              Launch Steam in Big Picture mode
  ls, list                     List available games and refresh wrappers
  prefixes                     Sync and list every wine prefix (source-qualified, with size)
  prefix rm <source>_<name>    Trash a prefix's real directory (gio trash, confirms first)
  runners [list|refresh]       Sync and list compatibility runners index (~/Games/runners)
  inspect <path>                Discover what a wine prefix is for (saves/config)
  kill, stop <game>            Kill a running game by slug/initials
  run <exe> [args...]          Launch an exe via umu-run/Proton without
                                registering it (no wrapper, no registry entry)
  add <exe> [-n name] [-p prefix]  Register a sideloaded (non-Steam) game;
                                    -n/--name sets the title (prompts if
                                    omitted), -p/--prefix reuses an existing
                                    prefix (gallery label or literal path)
                                    instead of creating a new one
  edit <slug>                   Edit name/executable/prefix for a custom game
                                 in $EDITOR (prefix accepts a gallery label or
                                 a literal path, see 'kettle prefixes')
  rm, remove <slug>             Unregister a custom game (registry entry +
                                 generated wrapper only — never touches the
                                 prefix directory or executable)
  set <slug> <key> <on|off>    Set mangohud/offload for a custom game (custom
                                games only — Steam-library games are launched
                                inside Steam's own container and can't be
                                reached this way; use Steam's per-game Launch
                                Options instead, e.g. 'mangohud %command%')
  status [slug]                Show mangohud/offload state for custom games
  help, -h, --help             Show this help
EOF
        ;;
    ""|ls|list)
        init_wrappers
        ls_slugs=() ls_aliases=()
        while IFS='|' read -r appid name; do
            initials=$(get_initials "$name")
            slug=$(get_slug "$name")
            ls_slugs+=("$slug")
            ls_aliases+=("${initials:+($initials)}")
        done < <(list_games)
        while IFS='|' read -r slug _title _exe; do
            ls_slugs+=("$slug")
            ls_aliases+=("")
        done < <(list_custom_games)
        ls_width=$(kettle_max_len ls_slugs)
        for i in "${!ls_slugs[@]}"; do
            kettle_status_line_aligned + "${ls_slugs[$i]}" "${#ls_slugs[$i]}" "$ls_width" "${ls_aliases[$i]}"
        done
        ;;
    prefixes|prefix)
        case "${2:-}" in
            rm|remove)
                if [[ $# -lt 3 ]]; then
                    echo "Usage: kettle prefix rm <source>_<name> [<source>_<name> ...]" >&2
                    exit 1
                fi
                had_error=0
                rm_labels=() rm_paths=()
                for target in "${@:3}"; do
                    resolved=$(resolve_gallery_prefix "$target") || { had_error=1; continue; }
                    if [[ ! -d "$resolved/drive_c" ]]; then
                        echo "Error: not a wine prefix (no drive_c): $resolved" >&2
                        had_error=1
                        continue
                    fi
                    if [[ "$resolved" != "$CUSTOM_PREFIX_DIR"/* && \
                          "$resolved" != "$HOME/Games/Heroic/Prefixes"/* && \
                          "$resolved" != "$HOME/Games/umu"/* && \
                          "$resolved" != "$HYDRA_PREFIX_DIR"/* && \
                          "$resolved" != "$STEAM_ROOT/steamapps/compatdata"/* ]]; then
                        echo "Error: refusing to delete outside known prefix roots: $resolved" >&2
                        had_error=1
                        continue
                    fi
                    rm_labels+=("$target")
                    rm_paths+=("$resolved")
                done
                if [[ ${#rm_paths[@]} -gt 0 ]]; then
                    echo "About to trash:"
                    for i in "${!rm_paths[@]}"; do
                        size=$(du -sh "${rm_paths[$i]}" 2>/dev/null | cut -f1)
                        echo "  ${rm_labels[$i]}: ${rm_paths[$i]} ($size)"
                    done
                    prompt="Delete? [y/N] "
                    [[ ${#rm_paths[@]} -gt 1 ]] && prompt="Delete all ${#rm_paths[@]}? [y/N] "
                    read -r -p "$prompt" reply < /dev/tty
                    if [[ "$reply" =~ ^[Yy]$ ]]; then
                        for resolved in "${rm_paths[@]}"; do
                            if command -v gio &>/dev/null; then
                                gio trash -- "$resolved"
                            else
                                echo "Warning: gio not found, falling back to permanent rm -rf" >&2
                                rm -rf -- "$resolved"
                            fi
                        done
                    fi
                fi
                [[ $had_error -eq 0 ]] || exit 1
                ;;
            "")
                list_prefix_gallery
                ;;
            *)
                echo "Usage: kettle prefix [rm <source>_<name>]" >&2
                exit 1
                ;;
        esac
        ;;
    runners|runner)
        case "${2:-}" in
            refresh|sync)
                sync_all_runners
                ;;
            ""|ls|list)
                list_runners
                ;;
            *)
                echo "Usage: kettle runners [list|refresh]" >&2
                exit 1
                ;;
        esac
        ;;
    inspect)
        prefix="${2:-}"
        if [[ -z "$prefix" ]]; then
            echo "Usage: kettle inspect <path-to-prefix>" >&2
            exit 1
        fi
        inspect_prefix "$prefix"
        ;;
    run)
        exe="${2:-}"
        if [[ -z "$exe" ]]; then
            echo "Usage: kettle run <path/to/exe> [args...]" >&2
            exit 1
        fi
        exe="${exe/#\~/$HOME}"
        exe=$(realpath -m -- "$exe")
        if [[ ! -f "$exe" ]]; then
            echo "Error: executable not found: $exe" >&2
            exit 1
        fi
        check_deps "${RUN_DEPS[@]}"
        if [[ -z "$PROTON_PATH" ]]; then
            echo "Error: no Proton build found under $STEAM_ROOT (checked compatibilitytools.d and steamapps/common)" >&2
            exit 1
        fi
        mkdir -p "$RUN_PREFIX"
        export WINEPREFIX="$RUN_PREFIX"
        export GAMEID="${GAMEID:-umu-default}"
        export PROTONPATH="${PROTONPATH:-$PROTON_PATH}"
        shift 2
        _working_dir=$(dirname -- "$exe")
        _exe_name=$(basename -- "$exe")
        if ! cd -- "$_working_dir"; then
            echo "Error: could not set working directory: $_working_dir" >&2
            exit 1
        fi
        exec umu-run "./$_exe_name" "$@"
        ;;
    kill|stop)
        game="${2:-}"
        if [[ -z "$game" ]]; then
            echo "Usage: kettle kill <game-slug>"
            exit 1
        fi
        if custom_entry=$(get_custom_game "$game") && [[ -n "$custom_entry" ]]; then
            exe="${custom_entry%%|*}"
            killed=1
            pkill -f "$exe" 2>/dev/null || killed=0
            if [[ $killed -eq 1 ]]; then
                echo "Killed $game"
            else
                echo "Not running: $game"
            fi
            exit 0
        fi
        appid=$(get_appid "$game")
        if [[ -z "$appid" ]]; then
            echo "Unknown game: $game"
            exit 1
        fi
        if ! installdir=$(get_installdir "$appid"); then
            echo "Error: could not determine install directory for $game (appid $appid)" >&2
            exit 1
        fi
        # Kill reaper + all processes matching installdir (. matches both / and \)
        killed_reaper=1
        pkill -f "SteamLaunch AppId=$appid" 2>/dev/null || killed_reaper=0
        killed_process=1
        pkill -9 -f "common.$installdir" || killed_process=0
        if [[ $killed_reaper -eq 1 ]] || [[ $killed_process -eq 1 ]]; then
            echo "Killed $game"
        else
            echo "Not running: $game"
        fi
        ;;
    add)
        shift
        exe="" title="" prefix_target="" prefix_path=""
        gallery_entries=() source_="" target_name="" real="" reuse="" pick="" entry="" i=0
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --name|-n)
                    title="${2:-}"
                    [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; exit 1; }
                    shift 2
                    ;;
                --prefix|-p)
                    prefix_target="${2:-}"
                    [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; exit 1; }
                    shift 2
                    ;;
                -*)
                    echo "Error: unknown flag '$1' (see 'kettle help')" >&2
                    exit 1
                    ;;
                *)
                    if [[ -n "$exe" ]]; then
                        echo "Error: unexpected argument '$1'" >&2
                        exit 1
                    fi
                    exe="$1"
                    shift
                    ;;
            esac
        done
        if [[ -z "$exe" ]]; then
            read -rp "Path to executable: " exe
        fi
        if [[ -z "$exe" ]]; then
            echo "Error: executable path required" >&2
            exit 1
        fi
        exe="${exe/#\~/$HOME}"
        exe=$(realpath -m -- "$exe")
        if [[ -z "$title" ]]; then
            read -rp "Game name: " title
        fi
        if [[ -z "$title" ]]; then
            echo "Error: game name required" >&2
            exit 1
        fi
        title=$(normalize_title "$title")
        if [[ -n "$prefix_target" ]]; then
            prefix_path=$(resolve_prefix_input "$prefix_target") || exit 1
        else
            gallery_entries=()
            while IFS=$'\t' read -r source_ target_name real; do
                [[ -n "$real" ]] || continue
                gallery_entries+=("$(gallery_label "$source_" "$target_name")|$real")
            done < <(walk_prefix_gallery)
            if [[ ${#gallery_entries[@]} -gt 0 ]]; then
                read -r -p "Reuse an existing prefix? [y/N] " reuse < /dev/tty
                if [[ "$reuse" =~ ^[Yy]$ ]]; then
                    i=1
                    for entry in "${gallery_entries[@]}"; do
                        echo "  $i) ${entry%%|*}"
                        ((i++))
                    done
                    read -r -p "Pick a number: " pick < /dev/tty
                    if [[ ! "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#gallery_entries[@]} )); then
                        echo "Error: invalid selection" >&2
                        exit 1
                    fi
                    prefix_path="${gallery_entries[$((pick - 1))]#*|}"
                fi
            fi
        fi
        add_custom_game "$title" "$exe" "$prefix_path"
        ;;
    set)
        slug="${2:-}" key="${3:-}" value="${4:-}"
        if [[ -z "$slug" || -z "$key" || -z "$value" ]]; then
            echo "Usage: kettle set <slug> <mangohud|offload> <on|off>" >&2
            exit 1
        fi
        if ! custom_entry=$(get_custom_game "$slug") || [[ -z "$custom_entry" ]]; then
            echo "Error: '$slug' is not a registered custom game. Steam-library games can't be configured via kettle — set mangohud/GPU options through Steam's own Launch Options." >&2
            exit 1
        fi
        case "$key" in
            mangohud|offload) ;;
            *) echo "Error: unknown setting '$key' (expected mangohud or offload)" >&2; exit 1 ;;
        esac
        case "$value" in
            on) normalized=1 ;;
            off) normalized=0 ;;
            *) echo "Error: invalid value '$value' (expected on or off)" >&2; exit 1 ;;
        esac
        check_deps jq
        set_setting "$slug" "$key" "$normalized"
        exe="${custom_entry%%|*}"
        custom_prefix="${custom_entry##*|}"
        create_custom_wrapper "$slug" "$exe" "$custom_prefix"
        kettle_status_line "$([[ "$normalized" == 1 ]] && echo + || echo -)" "$key:$slug"
        ;;
    edit)
        slug="${2:-}"
        if [[ -z "$slug" ]]; then
            echo "Usage: kettle edit <slug>" >&2
            exit 1
        fi
        if ! full_entry=$(get_custom_game_full "$slug") || [[ -z "$full_entry" ]]; then
            echo "Error: '$slug' is not a registered custom game." >&2
            exit 1
        fi
        old_title="${full_entry%%|*}"
        old_rest="${full_entry#*|}"
        old_exe="${old_rest%%|*}"
        old_prefix="${old_rest#*|}"
        old_prefix_display=$(gallery_label_for_path "$old_prefix")

        tmpfile=$(mktemp)
        trap 'rm -f "$tmpfile"' EXIT
        original_content=$'name='"$old_title"$'\n''executable-path='"$old_exe"$'\n''prefix='"$old_prefix_display"
        printf '%s\n' "$original_content" > "$tmpfile"

        "${EDITOR:-vi}" "$tmpfile" < /dev/tty > /dev/tty 2>&1

        if [[ "$(cat "$tmpfile")" == "$original_content" ]]; then
            echo "No changes made."
            exit 0
        fi

        new_title="" new_exe="" new_prefix=""
        while IFS='=' read -r key value; do
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            case "$key" in
                name) new_title="$value" ;;
                executable-path) new_exe="$value" ;;
                prefix) new_prefix="$value" ;;
            esac
        done < "$tmpfile"

        if [[ -z "$new_title" ]]; then
            echo "Error: name is required" >&2
            exit 1
        fi
        if [[ -z "$new_exe" ]]; then
            echo "Error: executable-path is required" >&2
            exit 1
        fi
        new_exe="${new_exe/#\~/$HOME}"
        new_exe=$(realpath -m -- "$new_exe")
        if [[ ! -f "$new_exe" ]]; then
            echo "Error: executable not found: $new_exe" >&2
            exit 1
        fi
        if [[ -z "$new_prefix" ]]; then
            echo "Error: prefix is required" >&2
            exit 1
        fi
        if ! resolved_prefix=$(resolve_prefix_input "$new_prefix"); then
            exit 1
        fi

        new_title=$(normalize_title "$new_title")
        new_slug=$(get_slug "$new_title")
        if [[ -z "$new_slug" ]]; then
            echo "Error: could not derive a slug from name: $new_title" >&2
            exit 1
        fi

        if [[ "$new_slug" != "$slug" ]]; then
            if existing=$(get_custom_game "$new_slug") && [[ -n "$existing" ]]; then
                echo "Error: a custom game with slug '$new_slug' already exists" >&2
                exit 1
            fi
            init_settings_registry
            old_settings_entry=$(jq -r --arg k "$slug" '.[$k] // empty' "$SETTINGS_REGISTRY" 2>/dev/null)
            if [[ -n "$old_settings_entry" ]]; then
                if jq --arg old "$slug" --arg new "$new_slug" \
                    '.[$new] = .[$old] | del(.[$old])' \
                    "$SETTINGS_REGISTRY" > "$SETTINGS_REGISTRY.tmp"; then
                    mv "$SETTINGS_REGISTRY.tmp" "$SETTINGS_REGISTRY"
                else
                    rm -f "$SETTINGS_REGISTRY.tmp"
                fi
            fi
            rm -f "$CUSTOM_WRAPPER_DIR/$slug" "$SYMLINK_DIR/$slug"
            if ! jq --arg old "$slug" --arg new "$new_slug" \
                --arg title "$new_title" --arg exe "$new_exe" --arg prefix "$resolved_prefix" \
                '.[$new] = {title: $title, executable: $exe, prefix: $prefix} | del(.[$old])' \
                "$CUSTOM_REGISTRY" > "$CUSTOM_REGISTRY.tmp"; then
                echo "Error: failed to update registry $CUSTOM_REGISTRY" >&2
                rm -f "$CUSTOM_REGISTRY.tmp"
                exit 1
            fi
            mv "$CUSTOM_REGISTRY.tmp" "$CUSTOM_REGISTRY"
            create_custom_wrapper "$new_slug" "$new_exe" "$resolved_prefix"
            kettle_status_line x "$slug"
            kettle_status_line + "$new_slug"
        else
            if ! jq --arg k "$slug" --arg title "$new_title" --arg exe "$new_exe" --arg prefix "$resolved_prefix" \
                '.[$k] = {title: $title, executable: $exe, prefix: $prefix}' \
                "$CUSTOM_REGISTRY" > "$CUSTOM_REGISTRY.tmp"; then
                echo "Error: failed to update registry $CUSTOM_REGISTRY" >&2
                rm -f "$CUSTOM_REGISTRY.tmp"
                exit 1
            fi
            mv "$CUSTOM_REGISTRY.tmp" "$CUSTOM_REGISTRY"
            create_custom_wrapper "$slug" "$new_exe" "$resolved_prefix"
            kettle_status_line + "$slug"
        fi
        ;;
    rm|remove)
        slug="${2:-}"
        if [[ -z "$slug" ]]; then
            echo "Usage: kettle rm <slug>" >&2
            exit 1
        fi
        if ! custom_entry=$(get_custom_game "$slug") || [[ -z "$custom_entry" ]]; then
            echo "Error: '$slug' is not a registered custom game." >&2
            exit 1
        fi
        rm -f "$CUSTOM_WRAPPER_DIR/$slug" "$SYMLINK_DIR/$slug"
        if jq --arg k "$slug" 'del(.[$k])' "$CUSTOM_REGISTRY" > "$CUSTOM_REGISTRY.tmp"; then
            mv "$CUSTOM_REGISTRY.tmp" "$CUSTOM_REGISTRY"
        else
            rm -f "$CUSTOM_REGISTRY.tmp"
        fi
        init_settings_registry
        if setting_entry=$(jq -r --arg k "$slug" '.[$k] // empty' "$SETTINGS_REGISTRY" 2>/dev/null) && [[ -n "$setting_entry" ]]; then
            if jq --arg k "$slug" 'del(.[$k])' "$SETTINGS_REGISTRY" > "$SETTINGS_REGISTRY.tmp"; then
                mv "$SETTINGS_REGISTRY.tmp" "$SETTINGS_REGISTRY"
            else
                rm -f "$SETTINGS_REGISTRY.tmp"
            fi
        fi
        kettle_status_line x "$slug"
        ;;
    status)
        slug="${2:-}"
        if [[ -n "$slug" ]]; then
            if ! custom_entry=$(get_custom_game "$slug") || [[ -z "$custom_entry" ]]; then
                echo "Error: '$slug' is not a registered custom game." >&2
                exit 1
            fi
            print_settings "$slug"
        else
            while IFS='|' read -r s _title _exe; do
                print_settings "$s"
            done < <(list_custom_games)
        fi
        ;;
    big|bigpicture)
        init_wrappers
        exec gamemoderun steam -tenfoot
        ;;
    steam)
        init_wrappers
        exec gamemoderun steam
        ;;
    *)
        echo "Error: unknown command '$1' (see 'kettle help')" >&2
        exit 1
        ;;
esac
