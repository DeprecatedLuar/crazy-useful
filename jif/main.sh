#!/usr/bin/env bash
# jif - Video to GIF encoder with smart size targeting

SIZE_CAP_MB=9       # default, overridable via --cap
SAMPLE_SECS=3       # seconds of footage used per parallel sample
SAFETY=0.92         # model targets this fraction of cap to leave headroom
HEADROOM_THRESHOLD=0.85  # if actual/cap < this, retry with correction-adjusted candidate

# Sampling reference points
SAMPLE_BASE_FPS=15;    SAMPLE_BASE_SCALE=900;  SAMPLE_BASE_COLORS=256
SAMPLE_TEST_FPS=12;    SAMPLE_TEST_SCALE=720;  SAMPLE_TEST_COLORS=128

# Grid search ranges (space-separated, best→worst quality per axis)
GRID_FPS="15 12 10 8 6"
GRID_SCALE="900 720 560 400 300 200"
GRID_COLORS="256 128 64 32"

# Color diminishing-returns exponent (separate from sensitivity weights)
WEIGHT_COLOR_EXP=0.3

# Default power-law exponents when sample data is degenerate
DEFAULT_EXP_A=1.0; DEFAULT_EXP_B=2.0; DEFAULT_EXP_C=0.5

# Fallback ladder — used only if model undershoots (worst→best within ladder)
LADDER=(
    "15 900 256"
    "12 900 256"
    "10 900 128"
    "8  900 64"
    "8  720 64"
    "8  560 64"
    "8  400 64"
    "8  300 32"
    "6  300 32"
    "6  200 32"
)

#--[Helpers]------------------------------------------------------------------

die()     { echo "Error: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found (needed for jif)"; }

get_duration() {
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null
}

file_size() { stat -c%s "$1" 2>/dev/null || echo 0; }

encode_gif() {
    local input="$1" output="$2" fps="$3" scale="$4" colors="$5" duration_flag="$6"
    ffmpeg -i "$input" $duration_flag \
        -vf "mpdecimate,fps=${fps},scale=${scale}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=${colors}[p];[s1][p]paletteuse=dither=bayer:diff_mode=rectangle" \
        -loop 0 "$output" -y >/dev/null 2>&1
}

quality_score() {
    awk -v f="$1" -v s="$2" -v c="$3" \
        -v wf="$WEIGHT_FPS" -v ws="$WEIGHT_SCALE" -v wc="$WEIGHT_COLORS" \
        -v ce="$WEIGHT_COLOR_EXP" -v bf="$SAMPLE_BASE_FPS" \
        -v bs="$SAMPLE_BASE_SCALE" -v bc="$SAMPLE_BASE_COLORS" \
        'BEGIN { printf "%.4f", wf*(f/bf) + ws*(s/bs) + wc*(c/bc)^ce }'
}

#--[Main]---------------------------------------------------------------------

require ffmpeg
require ffprobe

DEBUG=false
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --debug) DEBUG=true; shift ;;
        --cap)   SIZE_CAP_MB="$2"; shift 2 ;;
        *) echo "Error: unknown option $1" >&2; exit 1 ;;
    esac
done

SIZE_CAP=$((SIZE_CAP_MB * 1024 * 1024))

if [[ $# -lt 1 ]]; then
    echo "Usage: jif [--cap MB] [--debug] <input> [output.gif]"
    echo "  Encodes video to a GIF targeting ≤${SIZE_CAP_MB}MB"
    exit 1
fi

INPUT="$1"
OUTPUT="${2:-${INPUT%.*}.gif}"

[[ -f "$INPUT" ]] || die "Input not found: $INPUT"

DURATION=$(get_duration "$INPUT")
[[ -n "$DURATION" ]] || die "Could not read duration: $INPUT"
DURATION_INT=$(printf "%.0f" "$DURATION")

echo "Duration: ${DURATION_INT}s  Target: ≤${SIZE_CAP_MB}MB"

#--[Parallel samples]---------------------------------------------------------

TMP_BASE="${TMPDIR:-/tmp}/jif-base-$$.gif"
TMP_FPS="${TMPDIR:-/tmp}/jif-fps-$$.gif"
TMP_SCALE="${TMPDIR:-/tmp}/jif-scale-$$.gif"
TMP_COLORS="${TMPDIR:-/tmp}/jif-colors-$$.gif"
TMP_FULL="${TMPDIR:-/tmp}/jif-full-$$.gif"
trap 'rm -f "$TMP_BASE" "$TMP_FPS" "$TMP_SCALE" "$TMP_COLORS" "$TMP_FULL"' EXIT

SDUR=$SAMPLE_SECS
[[ $DURATION_INT -le $SAMPLE_SECS ]] && SDUR=$DURATION_INT

echo "Sampling..."
encode_gif "$INPUT" "$TMP_BASE"   $SAMPLE_BASE_FPS $SAMPLE_BASE_SCALE $SAMPLE_BASE_COLORS "-t $SDUR" & PID_BASE=$!
encode_gif "$INPUT" "$TMP_FPS"    $SAMPLE_TEST_FPS $SAMPLE_BASE_SCALE $SAMPLE_BASE_COLORS "-t $SDUR" & PID_FPS=$!
encode_gif "$INPUT" "$TMP_SCALE"  $SAMPLE_BASE_FPS $SAMPLE_TEST_SCALE $SAMPLE_BASE_COLORS "-t $SDUR" & PID_SCALE=$!
encode_gif "$INPUT" "$TMP_COLORS" $SAMPLE_BASE_FPS $SAMPLE_BASE_SCALE $SAMPLE_TEST_COLORS "-t $SDUR" & PID_COLORS=$!
wait $PID_BASE $PID_FPS $PID_SCALE $PID_COLORS

SIZE_BASE=$(file_size "$TMP_BASE")
SIZE_FPS=$(file_size "$TMP_FPS")
SIZE_SCALE=$(file_size "$TMP_SCALE")
SIZE_COLORS=$(file_size "$TMP_COLORS")

[[ $SIZE_BASE -eq 0 ]] && die "Baseline sample failed"

#--[Sensitivity model + grid search]------------------------------------------

# Fit power-law exponents from parallel samples, then grid search all
# combinations for highest quality that fits under cap.
# size(fps,scale,colors) = est_base × (fps/BASE_FPS)^A × (scale/BASE_SCALE)^B × (colors/BASE_COLORS)^C
ALL_CANDIDATES=$(awk \
    -v sb="$SIZE_BASE" -v sf="$SIZE_FPS" -v ss="$SIZE_SCALE" -v sc="$SIZE_COLORS" \
    -v dur="$DURATION" -v sdur="$SDUR" \
    -v cap="$SIZE_CAP" -v safety="$SAFETY" \
    -v bf="$SAMPLE_BASE_FPS"    -v bs="$SAMPLE_BASE_SCALE"  -v bc="$SAMPLE_BASE_COLORS" \
    -v tf="$SAMPLE_TEST_FPS"    -v ts="$SAMPLE_TEST_SCALE"  -v tc="$SAMPLE_TEST_COLORS" \
    -v grid_fps="$GRID_FPS"     -v grid_scale="$GRID_SCALE" -v grid_colors="$GRID_COLORS" \
    -v ce="$WEIGHT_COLOR_EXP" \
    -v da="$DEFAULT_EXP_A" -v db="$DEFAULT_EXP_B" -v dc="$DEFAULT_EXP_C" \
    -v dbg="$DEBUG" \
'BEGIN {
    est_base = (sb / sdur) * dur * (1 / safety)

    A = (sf > 0 && sb > 0 && sf != sb) ? log(sf/sb) / log(tf/bf) : da
    B = (ss > 0 && sb > 0 && ss != sb) ? log(ss/sb) / log(ts/bs) : db
    C = (sc > 0 && sb > 0 && sc != sb) ? log(sc/sb) / log(tc/bc) : dc
    wf = 1 / (A > 0.1 ? A : 0.1)
    ws = 1 / (B > 0.1 ? B : 0.1)
    wc = 1 / (C > 0.1 ? C : 0.1)

    n_fps    = split(grid_fps,    fps_vals)
    n_scale  = split(grid_scale,  scale_vals)
    n_colors = split(grid_colors, color_vals)

    if (dbg) printf "[debug] est_base=%.1fMB  A=%.3f B=%.3f C=%.3f  wf=%.2f ws=%.2f wc=%.2f  cap=%.1fMB\n", \
        est_base/1024/1024, A, B, C, wf, ws, wc, cap/1024/1024 > "/dev/stderr"

    for (fi = 1; fi <= n_fps; fi++) {
        for (si = 1; si <= n_scale; si++) {
            for (ci = 1; ci <= n_colors; ci++) {
                fp = fps_vals[fi]+0
                sc = scale_vals[si]+0
                co = color_vals[ci]+0

                est = est_base * (fp/bf)^A * (sc/bs)^B * (co/bc)^C
                q   = wf*(fp/bf) + ws*(sc/bs) + wc*(co/bc)^ce

                if (dbg) printf "[debug] fps=%-2s scale=%-3s colors=%-3s  est=%.1fMB  q=%.3f  %s\n", \
                    fp, sc, co, est/1024/1024, q, (est <= cap ? "OK" : "over") > "/dev/stderr"

                print fp, sc, co, est, q
            }
        }
    }
}')

read -r CHOSEN_FPS CHOSEN_SCALE CHOSEN_COLORS CHOSEN_EST CHOSEN_Q < <(
    awk -v cap="$SIZE_CAP" '$4 <= cap && $5 > best_q { best_q=$5; r=$0 } END { print r }' <<< "$ALL_CANDIDATES"
)

echo "Model: fps=${CHOSEN_FPS} scale=${CHOSEN_SCALE} colors=${CHOSEN_COLORS}"

#--[Full encode + headroom retry + ladder fallback]---------------------------

encode_and_check() {
    local fps="$1" scale="$2" colors="$3"
    printf "Encoding fps=%s scale=%s colors=%s..." "$fps" "$scale" "$colors" >&2
    rm -f "$TMP_FULL"
    encode_gif "$INPUT" "$TMP_FULL" "$fps" "$scale" "$colors" ""
    [[ ! -f "$TMP_FULL" ]] && die "Encoding failed"
    local size mb
    size=$(file_size "$TMP_FULL")
    mb=$(awk -v s="$size" 'BEGIN{printf "%.1f", s/1024/1024}')
    echo " ${mb}MB" >&2
    echo "$size"
}

# First encode
FIRST_SIZE=$(encode_and_check "$CHOSEN_FPS" "$CHOSEN_SCALE" "$CHOSEN_COLORS")

if [[ $FIRST_SIZE -le $SIZE_CAP ]]; then
    FIRST_MB=$(awk -v s="$FIRST_SIZE" 'BEGIN{printf "%.1f", s/1024/1024}')

    HAS_HEADROOM=$(awk -v a="$FIRST_SIZE" -v cap="$SIZE_CAP" -v t="$HEADROOM_THRESHOLD" \
        'BEGIN{print (a/cap < t) ? "true" : "false"}')
    if [[ $HAS_HEADROOM == "true" ]]; then
        CORRECTION=$(awk -v a="$FIRST_SIZE" -v e="$CHOSEN_EST" 'BEGIN{printf "%.6f", a/e}')
        read -r RETRY_FPS RETRY_SCALE RETRY_COLORS RETRY_EST RETRY_Q < <(
            awk -v cap="$SIZE_CAP" -v corr="$CORRECTION" -v cq="$CHOSEN_Q" \
                '$4 * corr <= cap && $5 > cq && $5 > best_q { best_q=$5; r=$0 } END { if (best_q > 0) print r }' \
                <<< "$ALL_CANDIDATES"
        )
        if [[ -n "$RETRY_FPS" ]]; then
            RETRY_ADJ=$(awk -v e="$RETRY_EST" -v corr="$CORRECTION" 'BEGIN{printf "%.1f", e*corr/1024/1024}')
            echo "Headroom (${FIRST_MB}MB/${SIZE_CAP_MB}MB, correction=${CORRECTION}) — retrying fps=${RETRY_FPS} scale=${RETRY_SCALE} colors=${RETRY_COLORS} (adj est ${RETRY_ADJ}MB)..."
            SECOND_SIZE=$(encode_and_check "$RETRY_FPS" "$RETRY_SCALE" "$RETRY_COLORS")
            if [[ $SECOND_SIZE -le $SIZE_CAP ]]; then
                FINAL_MB=$(awk -v s="$SECOND_SIZE" 'BEGIN{printf "%.1f", s/1024/1024}')
                mv "$TMP_FULL" "$OUTPUT"
                echo "Done: $OUTPUT (${FINAL_MB}MB)"
                exit 0
            fi
            echo "Retry exceeded cap — keeping first result"
        fi
    fi

    mv "$TMP_FULL" "$OUTPUT"
    echo "Done: $OUTPUT (${FIRST_MB}MB)"
    exit 0
fi

# Over cap — walk ladder sequentially from beginning
echo "Over cap — entering ladder"
for i in "${!LADDER[@]}"; do
    read -r fps scale colors <<< "${LADDER[$i]}"
    CUR_SIZE=$(encode_and_check "$fps" "$scale" "$colors")
    FINAL_MB=$(awk -v s="$CUR_SIZE" 'BEGIN{printf "%.1f", s/1024/1024}')

    if [[ $CUR_SIZE -le $SIZE_CAP ]]; then
        mv "$TMP_FULL" "$OUTPUT"
        echo "Done: $OUTPUT (${FINAL_MB}MB)"
        exit 0
    fi

    echo "Over cap, stepping down"
done

FINAL_MB=$(awk -v s="$(file_size "$TMP_FULL")" 'BEGIN{printf "%.1f", s/1024/1024}')
echo "Warning: exhausted all presets"
mv "$TMP_FULL" "$OUTPUT"
echo "Done: $OUTPUT (${FINAL_MB}MB — exceeded ${SIZE_CAP_MB}MB cap)"
