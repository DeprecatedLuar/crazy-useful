#!/usr/bin/env bash
# squish - Optimize images to target file size using binary search

#--[Configuration]----------------------------------------------------------

KEEP_ORIGINAL=true
FORCE_OVERWRITE=false
DEBUG=false
PARALLEL=4  # Default parallel jobs (use -j 1 for sequential, -j N for custom)
TOLERANCE_KB=5  # Acceptable deviation from target

#--[Argument Parsing]-------------------------------------------------------

ORIGINAL_ARGS=("$@")  # preserved for nix-shell re-exec before flags are shifted away

# Handle flags
while [[ "$1" == -* ]]; do
    case "$1" in
        --rm)
            KEEP_ORIGINAL=false
            shift
            ;;
        -f|--force)
            FORCE_OVERWRITE=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        -j|--parallel)
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                PARALLEL="$2"
                shift 2
            else
                PARALLEL=$(nproc 2>/dev/null || echo 4)
                shift
            fi
            ;;
        *)
            echo "Error: Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate arguments
if [ "$#" -lt 2 ]; then
    echo "Usage: squish [--rm] [-f|--force] [--debug] [-j|--parallel [N]] <input_file...> <target_size>"
    echo "  --rm              Remove unsquished backup after optimization"
    echo "  -f, --force       Overwrite existing unsquished backups"
    echo "  --debug           Show binary search iterations"
    echo "  -j, --parallel [N]  Process N images in parallel (default: 4, use 1 for sequential)"
    echo ""
    echo "Behavior: Originals moved to unsquished/, squished versions replace them in-place"
    echo ""
    echo "Target size examples: 50k, 100kb, 1m, 200 (assumes kb)"
    echo ""
    echo "Examples:"
    echo "  squish image.webp 50k             # Optimize to ~50KB, backup to unsquished/"
    echo "  squish *.webp 40k                 # Batch optimize all to ~40KB"
    echo "  squish --rm photo.jpg 100k        # Optimize and delete unsquished backup"
    echo "  squish -f *.png 50k               # Force overwrite existing unsquished backups"
    exit 1
fi

# Last arg = target size, everything else = inputs
TARGET_ARG="${@: -1}"
INPUTS=("${@:1:$#-1}")

#--[Size Parsing]-----------------------------------------------------------

parse_size() {
    local size="$1"
    size="${size,,}"  # lowercase

    if [[ "$size" =~ ^([0-9]+)kb?$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$size" =~ ^([0-9]+)mb?$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 1024 ))
    elif [[ "$size" =~ ^([0-9]+)$ ]]; then
        echo "$size"  # assume KB if no unit
    else
        echo "0"
    fi
}

TARGET_KB=$(parse_size "$TARGET_ARG")

if [ "$TARGET_KB" -eq 0 ]; then
    echo "Error: Invalid target size: $TARGET_ARG"
    echo "Use: 50k, 100kb, 1m, or plain number (kb assumed)"
    exit 1
fi

#--[Tool Check]-------------------------------------------------------------

if ! command -v cwebp >/dev/null 2>&1; then
    # Re-exec the whole run inside a single nix-shell (NixOS only) so cwebp is
    # on PATH for every binary-search iteration — pays the startup cost once.
    if [ -z "$SQUISH_NIX_SHELL" ] && [ -f /etc/NIXOS ] && command -v nix-shell >/dev/null 2>&1; then
        export SQUISH_NIX_SHELL=1
        exec nix-shell -p libwebp --run "$(printf '%q ' "$0" "${ORIGINAL_ARGS[@]}")"
    fi

    echo "Error: cwebp not found"
    echo ""
    echo "On NixOS, install with:"
    echo "  environment.systemPackages = with pkgs; [ libwebp ];"
    exit 1
fi

#--[Optimization Function]--------------------------------------------------

optimize_one() {
    local INPUT="$1"
    local TARGET_KB="$2"

    # Validate input
    if [ ! -f "$INPUT" ]; then
        echo "Warning: Input file not found, skipping: $INPUT"
        return 1
    fi

    # Generate paths: move original to unsquished/, output to original location
    local DIR=$(dirname "$INPUT")
    local FILENAME=$(basename "$INPUT")
    local UNSQUISHED_DIR="$DIR/unsquished"
    local UNSQUISHED_FILE="$UNSQUISHED_DIR/$FILENAME"
    local OUTPUT="$INPUT"  # Replace original with squished version

    # Check the size before creating a backup directory or moving the input.
    # Files already at or below the target should be left completely untouched.
    local INPUT_SIZE_BYTES=$(stat -c%s "$INPUT" 2>/dev/null || stat -f%z "$INPUT" 2>/dev/null)
    local INPUT_SIZE_KB=$((INPUT_SIZE_BYTES / 1024))
    local TARGET_SIZE_BYTES=$((TARGET_KB * 1024))

    if [ "$INPUT_SIZE_BYTES" -le "$TARGET_SIZE_BYTES" ]; then
        printf "Skipped: %s (already %dkb ≤ %dkb)\n" "$FILENAME" "$INPUT_SIZE_KB" "$TARGET_KB"
        return 0
    fi

    # Create unsquished directory if needed
    mkdir -p "$UNSQUISHED_DIR"

    # Check if unsquished backup already exists
    if [ -f "$UNSQUISHED_FILE" ] && [ "$FORCE_OVERWRITE" = false ]; then
        echo "Warning: Unsquished backup already exists, skipping: $UNSQUISHED_FILE"
        return 1
    fi

    # Move original to unsquished/ before processing
    if ! mv "$INPUT" "$UNSQUISHED_FILE"; then
        echo "Error: Failed to move original to unsquished/"
        return 1
    fi

    [ "$DEBUG" = true ] && echo "Starting optimization: %dkb → %dkb" "$INPUT_SIZE_KB" "$TARGET_KB"
    printf "Squishing %s (%dkb → %dkb)" "$(basename "$OUTPUT")" "$INPUT_SIZE_KB" "$TARGET_KB"

    # Try quality 0 first to check if resize is needed
    local BEST_Q=0
    local BEST_SIZE=999999
    local BEST_FILE=""
    local UNIQUE_ID="$$$(basename "$OUTPUT" | tr -dc 'a-zA-Z0-9')"
    local TEMP="${TMPDIR:-/tmp}/squish.$UNIQUE_ID.q0.webp"

    if ! cwebp -q 0 "$UNSQUISHED_FILE" -o "$TEMP" >/dev/null 2>&1; then
        printf "\rFailed: %s (encoding error at q=0)\n" "$(basename "$OUTPUT")"
        rm -f "$TEMP"
        mv "$UNSQUISHED_FILE" "$OUTPUT"  # Restore original on failure
        return 1
    fi

    local SIZE_BYTES=$(stat -c%s "$TEMP" 2>/dev/null || stat -f%z "$TEMP" 2>/dev/null)
    local SIZE_KB=$((SIZE_BYTES / 1024))

    [ "$DEBUG" = true ] && printf "  q=0 → %dkb (checking if resize needed)\n" "$SIZE_KB"

    if [ "$SIZE_KB" -gt "$TARGET_KB" ]; then
        # Even quality 0 is too big, skip quality search and go straight to resize
        [ "$DEBUG" = true ] && echo "  Quality 0 too large, skipping quality search"
        BEST_SIZE=$SIZE_KB
        BEST_FILE="$TEMP"
        BEST_Q=0
    else
        # Quality 0 works! Now binary search for best quality
        [ "$DEBUG" = true ] && echo "  Quality 0 under target, searching for optimal quality"
        rm -f "$TEMP"

        local MIN_Q=0
        local MAX_Q=100
        BEST_Q=75
        BEST_SIZE=999999
        BEST_FILE=""

        while [ $((MAX_Q - MIN_Q)) -gt 2 ]; do
        local Q=$(( (MIN_Q + MAX_Q) / 2 ))
        local TEMP="${TMPDIR:-/tmp}/squish.$UNIQUE_ID.$Q.webp"

        if ! cwebp -q "$Q" "$UNSQUISHED_FILE" -o "$TEMP" >/dev/null 2>&1; then
            printf "\rFailed: %s (encoding error at q=%d)\n" "$(basename "$OUTPUT")" "$Q"
            rm -f "$TEMP" "$BEST_FILE"
            mv "$UNSQUISHED_FILE" "$OUTPUT"  # Restore original on failure
            return 1
        fi

        local SIZE_BYTES=$(stat -c%s "$TEMP" 2>/dev/null || stat -f%z "$TEMP" 2>/dev/null)
        local SIZE_KB=$((SIZE_BYTES / 1024))

        # Calculate distance from target
        local CURRENT_DIST=$((SIZE_KB > TARGET_KB ? SIZE_KB - TARGET_KB : TARGET_KB - SIZE_KB))
        local BEST_DIST=$((BEST_SIZE > TARGET_KB ? BEST_SIZE - TARGET_KB : TARGET_KB - BEST_SIZE))

        # Debug output
        if [ "$DEBUG" = true ]; then
            printf "\n  q=%d → %dkb (target=%dkb, range=%d-%d)" "$Q" "$SIZE_KB" "$TARGET_KB" "$MIN_Q" "$MAX_Q"
        fi

        # Update best if this is closer to target
        if [ "$CURRENT_DIST" -lt "$BEST_DIST" ]; then
            BEST_Q=$Q
            BEST_SIZE=$SIZE_KB
            [ -n "$BEST_FILE" ] && rm -f "$BEST_FILE"
            BEST_FILE="$TEMP"
            [ "$DEBUG" = true ] && printf " ← new best (dist=%d)" "$CURRENT_DIST"
        else
            rm -f "$TEMP"
        fi

        # Adjust search range
        if [ "$SIZE_KB" -lt "$TARGET_KB" ]; then
            MIN_Q=$Q
        else
            MAX_Q=$Q
        fi

            if [ "$DEBUG" = false ]; then
                printf "\rSquishing %s (q=%d, %dkb)" "$(basename "$OUTPUT")" "$Q" "$SIZE_KB"
            fi
        done
        [ "$DEBUG" = true ] && echo ""
    fi

    # If quality 0 still too large, binary search on resize scale
    if [ "$BEST_SIZE" -gt "$TARGET_KB" ]; then
        [ "$DEBUG" = true ] && echo "Target unachievable at full size, binary searching resize scale..."

        # Get image dimensions
        local WIDTH=$(identify -format "%w" "$UNSQUISHED_FILE" 2>/dev/null)
        local HEIGHT=$(identify -format "%h" "$UNSQUISHED_FILE" 2>/dev/null)

        if [ -z "$WIDTH" ] || [ -z "$HEIGHT" ]; then
            [ "$DEBUG" = true ] && echo "  Could not get image dimensions"
        else
            local MIN_SCALE=10
            local MAX_SCALE=100
            local RESIZE_BEST_SCALE=50
            local RESIZE_BEST_SIZE=999999
            local RESIZE_BEST_FILE=""

            while [ $((MAX_SCALE - MIN_SCALE)) -gt 3 ]; do
                local SCALE=$(( (MIN_SCALE + MAX_SCALE) / 2 ))
                local NEW_WIDTH=$((WIDTH * SCALE / 100))
                local NEW_HEIGHT=$((HEIGHT * SCALE / 100))
                local TEMP="${TMPDIR:-/tmp}/squish.$UNIQUE_ID.$SCALE.webp"

                if ! cwebp -resize "$NEW_WIDTH" "$NEW_HEIGHT" -q 75 "$UNSQUISHED_FILE" -o "$TEMP" >/dev/null 2>&1; then
                    [ "$DEBUG" = true ] && echo "  Resize failed at ${SCALE}%"
                    rm -f "$TEMP"
                    break
                fi

                local SIZE_BYTES=$(stat -c%s "$TEMP" 2>/dev/null || stat -f%z "$TEMP" 2>/dev/null)
                local SIZE_KB=$((SIZE_BYTES / 1024))

                [ "$DEBUG" = true ] && printf "  Resize %d%% (%dx%d) @ q75 → %dkb (range=%d-%d)\n" "$SCALE" "$NEW_WIDTH" "$NEW_HEIGHT" "$SIZE_KB" "$MIN_SCALE" "$MAX_SCALE"

                # Track best result (closest to target)
                local CURRENT_DIST=$((SIZE_KB > TARGET_KB ? SIZE_KB - TARGET_KB : TARGET_KB - SIZE_KB))
                local RESIZE_BEST_DIST=$((RESIZE_BEST_SIZE > TARGET_KB ? RESIZE_BEST_SIZE - TARGET_KB : TARGET_KB - RESIZE_BEST_SIZE))

                if [ "$CURRENT_DIST" -lt "$RESIZE_BEST_DIST" ]; then
                    RESIZE_BEST_SCALE=$SCALE
                    RESIZE_BEST_SIZE=$SIZE_KB
                    [ -n "$RESIZE_BEST_FILE" ] && rm -f "$RESIZE_BEST_FILE"
                    RESIZE_BEST_FILE="$TEMP"
                    [ "$DEBUG" = true ] && printf "    ← new best (dist=%dkb)\n" "$CURRENT_DIST"
                else
                    rm -f "$TEMP"
                fi

                # Adjust search range
                if [ "$SIZE_KB" -gt "$TARGET_KB" ]; then
                    # Too big, need smaller scale
                    MAX_SCALE=$SCALE
                else
                    # Too small, can go bigger
                    MIN_SCALE=$SCALE
                fi
            done

            # Use best resize result
            if [ -n "$RESIZE_BEST_FILE" ] && [ -f "$RESIZE_BEST_FILE" ]; then
                [ -n "$BEST_FILE" ] && rm -f "$BEST_FILE"
                BEST_FILE="$RESIZE_BEST_FILE"
                BEST_SIZE=$RESIZE_BEST_SIZE
                BEST_Q=75
                [ "$DEBUG" = true ] && echo "  Best resize: ${RESIZE_BEST_SCALE}% → ${RESIZE_BEST_SIZE}kb"
            fi
        fi
    fi

    # Finalize with best result
    if [ -n "$BEST_FILE" ] && [ -f "$BEST_FILE" ]; then
        mv "$BEST_FILE" "$OUTPUT"
        local DIFF=$((BEST_SIZE - TARGET_KB))
        local SIGN=""
        [ "$DIFF" -gt 0 ] && SIGN="+"
        printf "\rDone: %s (q=%d, %dkb, %s%dkb) [original → unsquished/]\n" \
            "$(basename "$OUTPUT")" "$BEST_Q" "$BEST_SIZE" "$SIGN" "$DIFF"

        if [ "$KEEP_ORIGINAL" = false ]; then
            rm "$UNSQUISHED_FILE"
            rmdir "$UNSQUISHED_DIR" 2>/dev/null || true  # drop dir if now empty
        fi
        return 0
    else
        printf "\rFailed: %s (no valid output)\n" "$(basename "$OUTPUT")"
        rm -f "$BEST_FILE"
        mv "$UNSQUISHED_FILE" "$OUTPUT"  # Restore original on failure
        return 1
    fi
}

#--[Main Loop]--------------------------------------------------------------

OK_COUNT=0
FAIL_COUNT=0

if [ "$PARALLEL" -gt 1 ]; then
    # Parallel processing - simpler approach using xargs-style batching
    [ "$DEBUG" = true ] && echo "Processing ${#INPUTS[@]} images with $PARALLEL parallel jobs"

    BATCH_SIZE=$PARALLEL
    for ((i=0; i<${#INPUTS[@]}; i+=BATCH_SIZE)); do
        BATCH_PIDS=()
        for ((j=0; j<BATCH_SIZE && i+j<${#INPUTS[@]}; j++)); do
            INPUT="${INPUTS[$((i+j))]}"
            optimize_one "$INPUT" "$TARGET_KB" &
            BATCH_PIDS+=($!)
        done

        # Wait for this batch to complete
        for PID in "${BATCH_PIDS[@]}"; do
            if wait "$PID"; then
                ((OK_COUNT++))
            else
                ((FAIL_COUNT++))
            fi
        done
    done
else
    # Sequential processing
    for INPUT in "${INPUTS[@]}"; do
        if optimize_one "$INPUT" "$TARGET_KB"; then
            ((OK_COUNT++))
        else
            ((FAIL_COUNT++))
        fi
    done
fi

# Summary for batch runs
if [ "${#INPUTS[@]}" -gt 1 ]; then
    echo "---"
    echo "Done: $OK_COUNT optimized, $FAIL_COUNT skipped/failed"
fi
