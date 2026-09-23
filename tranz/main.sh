#!/usr/bin/env bash
# tranz - Universal file format converter

#--[Configuration]----------------------------------------------------------

KEEP_ORIGINAL=true
FORCE_OVERWRITE=false

# Whisper settings
WHISPER_PATH=""  # Custom whisper Python path (e.g., venv), empty = auto-detect
WHISPER_MODEL="base"
WHISPER_DEVICE="cpu"
WHISPER_COMPUTE="float32"
WHISPER_MODEL_DIR="$HOME/.cache/whisper-cpp"
WHISPER_BEAM_SIZE=5

# Audio conversion quality settings
MP3_QUALITY=2
AUDIO_SAMPLE_RATE=16000
AUDIO_CHANNELS=1

# Image conversion quality settings
WEBP_QUALITY_HEIC=78
WEBP_QUALITY_JPG=50
WEBP_QUALITY_PNG=76

#--[Helper Functions]-------------------------------------------------------
ensure_whisper_model() {
    local model_name="$1"
    local model_path="$WHISPER_MODEL_DIR/ggml-${model_name}.bin"

    if [ -f "$model_path" ]; then
        echo "$model_path"
        return 0
    fi

    # Download model
    mkdir -p "$WHISPER_MODEL_DIR"
    echo "Downloading whisper model '${model_name}'..." >&2

    if ! command -v whisper-cpp-download-ggml-model >/dev/null 2>&1; then
        echo "Error: whisper-cpp-download-ggml-model not found" >&2
        return 1
    fi

    (cd "$WHISPER_MODEL_DIR" && whisper-cpp-download-ggml-model "$model_name" >/dev/null 2>&1)

    if [ -f "$model_path" ]; then
        echo "$model_path"
        return 0
    else
        echo "Error: Failed to download model" >&2
        return 1
    fi
}

# Execute command with nix-shell fallback on NixOS if binary not found
# Usage: exec_with_fallback <binary> <nix-package> <command> [args...]
# Returns: 0 if executed (sets CONVERT_PID), 1 if dependency missing
exec_with_fallback() {
    local bin="$1"
    local pkg="$2"
    shift 2
    local cmd=("$@")

    # Try direct execution
    if command -v "$bin" >/dev/null 2>&1; then
        "${cmd[@]}" >/dev/null 2>&1 &
        CONVERT_PID=$!
        return 0
    fi

    # Fallback: nix-shell (NixOS only)
    if [ -f /etc/NIXOS ] && command -v nix-shell >/dev/null 2>&1; then
        # Build properly quoted command string
        local cmd_str=""
        for arg in "${cmd[@]}"; do
            cmd_str="$cmd_str '${arg//\'/\'\\\'\'}'"
        done
        (nix-shell -p "$pkg" --run "$cmd_str" >/dev/null 2>&1) &
        CONVERT_PID=$!
        return 0
    fi

    # Error message
    echo "" >&2
    echo "Error: $bin not found" >&2
    if [ -f /etc/NIXOS ]; then
        echo "" >&2
        echo "On NixOS, install with:" >&2
        echo "  environment.systemPackages = with pkgs; [ $pkg ];" >&2
        echo "" >&2
        echo "Or run temporarily with:" >&2
        echo "  nix-shell -p $pkg --run 'tranz ...'" >&2
    fi
    return 1
}

detect_whisper() {
    # Try custom path first
    if [ -n "$WHISPER_PATH" ] && [ -f "$WHISPER_PATH" ]; then
        echo "python"
        return 0
    fi

    # Fall back to whisper-cli
    if command -v whisper-cli >/dev/null 2>&1; then
        echo "cli"
        return 0
    fi

    echo "Error: No whisper implementation found" >&2
    echo "" >&2
    echo "Install whisper-cpp via NixOS:" >&2
    echo "  environment.systemPackages = with pkgs; [ whisper-cpp ];" >&2
    echo "" >&2
    echo "Or set WHISPER_PATH to a Python venv with faster-whisper" >&2
    return 1
}

run_whisper_python() {
    local input="$1"
    local output="$2"
    local output_ext="$3"

    case "$output_ext" in
        srt)
            "$WHISPER_PATH" -c "
from faster_whisper import WhisperModel

def format_timestamp(seconds):
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int((seconds % 1) * 1000)
    return f'{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}'

model = WhisperModel('$WHISPER_MODEL', device='$WHISPER_DEVICE', compute_type='$WHISPER_COMPUTE')
segments, info = model.transcribe('$input', beam_size=$WHISPER_BEAM_SIZE)

with open('$output', 'w', encoding='utf-8') as f:
    for i, segment in enumerate(segments, 1):
        f.write(f'{i}\n')
        f.write(f'{format_timestamp(segment.start)} --> {format_timestamp(segment.end)}\n')
        f.write(f'{segment.text.strip()}\n\n')
" &
            ;;
        json)
            "$WHISPER_PATH" -c "
import json
from faster_whisper import WhisperModel

model = WhisperModel('$WHISPER_MODEL', device='$WHISPER_DEVICE', compute_type='$WHISPER_COMPUTE')
segments, info = model.transcribe('$input', beam_size=$WHISPER_BEAM_SIZE)

output = {
    'language': info.language,
    'duration': info.duration,
    'segments': [
        {
            'id': segment.id,
            'start': segment.start,
            'end': segment.end,
            'text': segment.text.strip()
        }
        for segment in segments
    ]
}

with open('$output', 'w', encoding='utf-8') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)
" &
            ;;
        *)
            "$WHISPER_PATH" -c "
from faster_whisper import WhisperModel

model = WhisperModel('$WHISPER_MODEL', device='$WHISPER_DEVICE', compute_type='$WHISPER_COMPUTE')
segments, info = model.transcribe('$input', beam_size=$WHISPER_BEAM_SIZE)

with open('$output', 'w', encoding='utf-8') as f:
    for segment in segments:
        f.write(segment.text.strip() + '\n')
" &
            ;;
    esac
}

#--[Format Detection]-------------------------------------------------------
get_format_type() {
    local ext="$1"
    case "$ext" in
        mp4|mkv|avi|mov|webm|flv|wmv|m4v|mpg|mpeg)
            echo "video"
            ;;
        mp3|flac|wav|aac|ogg|m4a|wma|opus)
            echo "audio"
            ;;
        jpg|jpeg|png|gif|bmp|tiff|tif|webp|heic|heif)
            echo "image"
            ;;
        txt|srt|json)
            echo "text"
            ;;
        docx|odt|rtf|epub|html|htm|rst|org|tex|md|markdown|pdf)
            echo "document"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

#--[Conversion Implementations]---------------------------------------------

convert_video_to_audio() {
    local input="$1" output="$2" output_ext="$3"

    case "$output_ext" in
        flac)
            exec_with_fallback ffmpeg ffmpeg ffmpeg -i "$input" -vn -acodec flac "$output" -y
            ;;
        mp3)
            exec_with_fallback ffmpeg ffmpeg ffmpeg -i "$input" -vn -acodec libmp3lame -q:a "$MP3_QUALITY" "$output" -y
            ;;
        wav)
            exec_with_fallback ffmpeg ffmpeg ffmpeg -i "$input" -vn -acodec pcm_s16le "$output" -y
            ;;
        *)
            exec_with_fallback ffmpeg ffmpeg ffmpeg -i "$input" -vn "$output" -y
            ;;
    esac
}

convert_video_to_image() {
    local input="$1" output="$2" input_ext="$3" output_ext="$4"

    if [ "$output_ext" = "gif" ]; then
        CONVERT_PID=""
        jif --cap 9 "$input" "$output"
        return $?
    fi

    printf " — skipping (unsupported: %s → %s)\n" "$input_ext" "$output_ext"
    CONVERT_PID=""
    return 1
}

convert_video_to_video() {
    local input="$1" output="$2"

    exec_with_fallback ffmpeg ffmpeg ffmpeg -i "$input" "$output" -y
}

convert_audio_to_audio() {
    local input="$1" output="$2" output_ext="$3"

    case "$output_ext" in
        flac)
            exec_with_fallback ffmpeg ffmpeg ffmpeg -i "$input" -acodec flac "$output" -y
            ;;
        mp3)
            exec_with_fallback ffmpeg ffmpeg ffmpeg -i "$input" -acodec libmp3lame -q:a "$MP3_QUALITY" "$output" -y
            ;;
        wav)
            exec_with_fallback ffmpeg ffmpeg ffmpeg -i "$input" -acodec pcm_s16le "$output" -y
            ;;
        *)
            exec_with_fallback ffmpeg ffmpeg ffmpeg -i "$input" "$output" -y
            ;;
    esac
}

convert_image_to_image() {
    local input="$1" output="$2" input_ext="$3" output_ext="$4"

    if [ "$output_ext" = "webp" ]; then
        case "$input_ext" in
            heic|heif)
                exec_with_fallback magick imagemagick magick "$input" -quality "$WEBP_QUALITY_HEIC" "$output"
                ;;
            jpg|jpeg)
                exec_with_fallback magick imagemagick magick "$input" -quality "$WEBP_QUALITY_JPG" "$output"
                ;;
            png)
                exec_with_fallback magick imagemagick magick "$input" -quality "$WEBP_QUALITY_PNG" "$output"
                ;;
            *)
                exec_with_fallback magick imagemagick magick "$input" "$output"
                ;;
        esac
    else
        exec_with_fallback magick imagemagick magick "$input" "$output"
    fi
}

convert_to_text() {
    local input="$1" output="$2" input_ext="$3" output_ext="$4"

    local whisper_type
    whisper_type=$(detect_whisper) || return 1

    if [ "$whisper_type" = "cli" ]; then
        local model_path
        model_path=$(ensure_whisper_model "$WHISPER_MODEL") || return 1

        local audio_input="$input"
        if [ "$input_ext" != "wav" ]; then
            TEMP_WAV_FILE="${TMPDIR:-/tmp}/tranz-$$.wav"
            if ! ffmpeg -i "$input" -ar "$AUDIO_SAMPLE_RATE" -ac "$AUDIO_CHANNELS" -c:a pcm_s16le "$TEMP_WAV_FILE" -y >/dev/null 2>&1; then
                echo "Error: Failed to convert audio to WAV" >&2
                return 1
            fi
            audio_input="$TEMP_WAV_FILE"
        fi

        local format_flag
        case "$output_ext" in
            srt)  format_flag="--output-srt" ;;
            json) format_flag="--output-json" ;;
            *)    format_flag="--output-txt" ;;
        esac

        local output_base="${output%.*}"
        whisper-cli -m "$model_path" -f "$audio_input" -of "$output_base" $format_flag -l auto --no-prints >/dev/null 2>&1 &
    else
        if [ ! -f "$WHISPER_PATH" ]; then
            echo "" >&2
            echo "Error: Whisper Python not found at: $WHISPER_PATH" >&2
            return 1
        fi

        run_whisper_python "$input" "$output" "$output_ext"
    fi

    CONVERT_PID=$!
    return 0
}

convert_document_to_text() {
    local input="$1" output="$2"

    if ! command -v markitdown >/dev/null 2>&1; then
        echo "Error: markitdown not found" >&2
        return 1
    fi

    markitdown "$input" > "$output" 2>/dev/null &
    CONVERT_PID=$!
    return 0
}

convert_document_to_document() {
    local input="$1" output="$2" output_ext="$3"

    if [ "$output_ext" = "pdf" ]; then
        local out_dir expected_pdf
        out_dir=$(dirname "$output")
        expected_pdf="$out_dir/$(basename "${input%.*}").pdf"

        # Try libreoffice first (if installed)
        if command -v libreoffice >/dev/null 2>&1; then
            (
                libreoffice --headless --convert-to pdf --outdir "$out_dir" "$input" >/dev/null 2>&1 || exit 1
                [ "$expected_pdf" != "$output" ] && mv "$expected_pdf" "$output" 2>/dev/null
                true
            ) &
        # Fallback: nix-shell with libreoffice (NixOS only)
        elif [ -f /etc/NIXOS ] && command -v nix-shell >/dev/null 2>&1; then
            (
                nix-shell -p libreoffice --run "libreoffice --headless --convert-to pdf --outdir '$out_dir' '$input'" >/dev/null 2>&1 || exit 1
                [ "$expected_pdf" != "$output" ] && mv "$expected_pdf" "$output" 2>/dev/null
                true
            ) &
        else
            echo "" >&2
            echo "Error: libreoffice not found" >&2
            echo "" >&2
            echo "On NixOS, install with:" >&2
            echo "  environment.systemPackages = with pkgs; [ libreoffice ];" >&2
            echo "" >&2
            echo "Or run temporarily with:" >&2
            echo "  nix-shell -p libreoffice --run \"tranz '$input' '$output'\"" >&2
            return 1
        fi
    else
        if ! command -v markitdown >/dev/null 2>&1; then
            echo "Error: markitdown not found" >&2
            return 1
        fi
        markitdown "$input" > "$output" 2>/dev/null &
    fi

    CONVERT_PID=$!
    return 0
}

convert_document_to_image() {
    local input="$1" output="$2" output_ext="$3"
    local output_base="${output%.*}"

    # Try pdftoppm first (poppler-utils) - more efficient for PDFs
    # Note: pdftoppm adds page numbers to filenames (e.g., output-1.png, output-2.png)
    # Set PDFTOPPM_GLOB flag so output check can glob for files
    case "$output_ext" in
        png)
            if exec_with_fallback pdftoppm poppler-utils pdftoppm -png -r 300 "$input" "$output_base"; then
                PDFTOPPM_GLOB="${output_base}-*.png"
                return 0
            fi
            ;;
        jpg|jpeg)
            if exec_with_fallback pdftoppm poppler-utils pdftoppm -jpeg -r 300 "$input" "$output_base"; then
                PDFTOPPM_GLOB="${output_base}-*.jpg"
                return 0
            fi
            ;;
        tiff|tif)
            if exec_with_fallback pdftoppm poppler-utils pdftoppm -tiff -r 300 "$input" "$output_base"; then
                PDFTOPPM_GLOB="${output_base}-*.tif"
                return 0
            fi
            ;;
    esac

    # Fallback to ImageMagick (requires ghostscript as delegate)
    if exec_with_fallback magick imagemagick magick -density 300 "$input" -flatten "$output"; then
        return 0
    fi

    # If we get here, show combined error
    echo "" >&2
    echo "Error: PDF conversion requires poppler-utils (pdftoppm) or imagemagick+ghostscript" >&2
    return 1
}

#--[Dependency Check]-------------------------------------------------------

if [[ "${1:-}" == "deps" ]]; then
    declare -A optional=(
        [ffmpeg]="audio/video conversion"
        [magick]="image conversion"
        [whisper-cli]="audio/video transcription"
        [markitdown]="document conversion"
        [libreoffice]="document to PDF"
    )
    ok=true
    for dep in "${!optional[@]}"; do
        if command -v "$dep" &>/dev/null; then
            printf "  [ok]      %-20s %s\n" "$dep" "${optional[$dep]}"
        else
            printf "  [missing] %-20s %s\n" "$dep" "${optional[$dep]}"
            ok=false
        fi
    done
    $ok || { echo ""; echo "some dependencies missing (all optional, needed per conversion type)"; exit 1; }
    exit 0
fi

#--[Argument Parsing]-------------------------------------------------------

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
        *)
            echo "Error: Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate arguments
if [ "$#" -lt 2 ]; then
    echo "Usage: tranz [-r|--replace] <input_file...> <output_file|.ext>"
    echo "  --rm           Remove original after conversion (default: keep)"
    echo ""
    echo "Examples:"
    echo "  tranz video.mkv audio.flac       # Convert MKV to FLAC audio"
    echo "  tranz video.mkv .mp3             # Auto-name: video.mp3"
    echo "  tranz image.png image.jpg        # Convert image formats"
    echo "  tranz -r old.avi new.mp4         # Convert and remove original"
    echo "  tranz ./*.png .webp              # Batch convert all PNGs to WebP"
    echo "  tranz ./* .webp                  # Batch convert all images to WebP (skips unsupported)"
    echo "  tranz -f doc.docx doc.pdf        # Overwrite existing output"
    exit 1
fi

# Last arg = output, everything else = inputs
OUTPUT_ARG="${@: -1}"
INPUTS=("${@:1:$#-1}")

# Single-file mode: output can be a full filename
# Batch mode (multiple inputs): output must be an extension
if [ "${#INPUTS[@]}" -gt 1 ] && [[ "$OUTPUT_ARG" != .* ]]; then
    echo "Error: Multiple inputs require an extension as output (e.g., .webp)"
    exit 1
fi

#--[Conversion Function]----------------------------------------------------

CONVERT_PID=""
CURRENT_OUTPUT=""

cleanup() {
    if [ -n "$CONVERT_PID" ] && kill -0 "$CONVERT_PID" 2>/dev/null; then
        kill "$CONVERT_PID" 2>/dev/null
        wait "$CONVERT_PID" 2>/dev/null
    fi
    [ -n "$CURRENT_OUTPUT" ] && rm -f "$CURRENT_OUTPUT"
    [ -n "$TEMP_WAV_FILE" ] && rm -f "$TEMP_WAV_FILE"
}

trap cleanup INT TERM

convert_one() {
    local INPUT="$1"
    local OUTPUT="$2"
    CONVERT_PID=""
    CURRENT_OUTPUT=""
    TEMP_WAV_FILE=""
    PDFTOPPM_GLOB=""

    # Validate input exists
    if [ ! -f "$INPUT" ]; then
        echo "Warning: Input file not found, skipping: $INPUT"
        return 1
    fi

    # Auto-generate output filename if only extension provided
    if [[ "$OUTPUT" == .* ]]; then
        OUTPUT="${INPUT%.*}$OUTPUT"
    fi

    # Check if output already exists
    if [ -f "$OUTPUT" ] && [ "$FORCE_OVERWRITE" = false ]; then
        echo "Warning: Output already exists, skipping: $OUTPUT"
        return 1
    fi

    # Extract extensions
    local INPUT_EXT="${INPUT##*.}"
    local OUTPUT_EXT="${OUTPUT##*.}"
    local INPUT_EXT_LOWER OUTPUT_EXT_LOWER
    INPUT_EXT_LOWER=$(echo "$INPUT_EXT" | tr '[:upper:]' '[:lower:]')
    OUTPUT_EXT_LOWER=$(echo "$OUTPUT_EXT" | tr '[:upper:]' '[:lower:]')

    # Determine conversion type
    local INPUT_TYPE OUTPUT_TYPE CONVERSION
    INPUT_TYPE=$(get_format_type "$INPUT_EXT_LOWER")
    OUTPUT_TYPE=$(get_format_type "$OUTPUT_EXT_LOWER")
    CONVERSION="${INPUT_TYPE}→${OUTPUT_TYPE}"

    CURRENT_OUTPUT="$OUTPUT"
    printf "Converting %s" "$(basename "$INPUT")"

    # Execute conversion based on type
    case "$CONVERSION" in
        video→audio)
            convert_video_to_audio "$INPUT" "$OUTPUT" "$OUTPUT_EXT_LOWER" || return 1
            ;;
        video→image)
            convert_video_to_image "$INPUT" "$OUTPUT" "$INPUT_EXT_LOWER" "$OUTPUT_EXT_LOWER" || return 1
            ;;
        video→video)
            convert_video_to_video "$INPUT" "$OUTPUT" || return 1
            ;;
        audio→audio)
            convert_audio_to_audio "$INPUT" "$OUTPUT" "$OUTPUT_EXT_LOWER" || return 1
            ;;
        image→image)
            convert_image_to_image "$INPUT" "$OUTPUT" "$INPUT_EXT_LOWER" "$OUTPUT_EXT_LOWER" || return 1
            ;;
        video→text|audio→text)
            convert_to_text "$INPUT" "$OUTPUT" "$INPUT_EXT_LOWER" "$OUTPUT_EXT_LOWER" || return 1
            ;;
        document→text)
            convert_document_to_text "$INPUT" "$OUTPUT" || return 1
            ;;
        document→image)
            convert_document_to_image "$INPUT" "$OUTPUT" "$OUTPUT_EXT_LOWER" || return 1
            ;;
        document→document)
            convert_document_to_document "$INPUT" "$OUTPUT" "$OUTPUT_EXT_LOWER" || return 1
            ;;
        *)
            printf " — skipping (unsupported: %s → %s)\n" "$INPUT_EXT_LOWER" "$OUTPUT_EXT_LOWER"
            CURRENT_OUTPUT=""
            return 1
            ;;
    esac

    # Wait for conversion (if backgrounded)
    if [ -n "$CONVERT_PID" ]; then
        local DOTS=""
        while kill -0 "$CONVERT_PID" 2>/dev/null; do
            printf "\rConverting %s%-3s" "$(basename "$INPUT")" "$DOTS"
            DOTS="${DOTS}."
            [ ${#DOTS} -gt 3 ] && DOTS=""
            sleep 0.3
        done
        wait "$CONVERT_PID"
        local EXIT_CODE=$?

        # Check for output: use glob if PDFTOPPM_GLOB is set, otherwise check exact file
        local output_check_failed=false
        if [ -n "$PDFTOPPM_GLOB" ]; then
            # Check if pdftoppm created any files
            local created_files=($PDFTOPPM_GLOB)
            if [ $EXIT_CODE -ne 0 ] || [ ! -f "${created_files[0]}" ]; then
                output_check_failed=true
            fi
        elif [ $EXIT_CODE -ne 0 ] || [ ! -f "$OUTPUT" ]; then
            output_check_failed=true
        fi

        if [ "$output_check_failed" = true ]; then
            printf "\rFailed: %s\n" "$(basename "$INPUT")"
            rm -f "$OUTPUT"
            [ -n "$TEMP_WAV_FILE" ] && rm -f "$TEMP_WAV_FILE"
            CURRENT_OUTPUT=""
            PDFTOPPM_GLOB=""
            return 1
        fi
    fi

    # Show completion message
    if [ -n "$PDFTOPPM_GLOB" ]; then
        local created_files=($PDFTOPPM_GLOB)
        printf "\rDone: %s → %d page(s)\n" "$(basename "$INPUT")" "${#created_files[@]}"
        PDFTOPPM_GLOB=""
    else
        printf "\rDone: %s → %s\n" "$(basename "$INPUT")" "$(basename "$OUTPUT")"
    fi

    # Cleanup temp WAV if created
    [ -n "$TEMP_WAV_FILE" ] && rm -f "$TEMP_WAV_FILE"

    CURRENT_OUTPUT=""
    CONVERT_PID=""

    [ "$KEEP_ORIGINAL" = false ] && rm "$INPUT"
    return 0
}

#--[Main Loop]--------------------------------------------------------------

SKIP_COUNT=0
FAIL_COUNT=0
OK_COUNT=0

for INPUT in "${INPUTS[@]}"; do
    if convert_one "$INPUT" "$OUTPUT_ARG"; then
        (( OK_COUNT++ ))
    else
        # distinguish skip (unsupported) from fail — both increment fail for simplicity
        (( FAIL_COUNT++ ))
    fi
done

# Summary for batch runs
if [ "${#INPUTS[@]}" -gt 1 ]; then
    echo "---"
    echo "Done: $OK_COUNT converted, $FAIL_COUNT skipped/failed"
fi
