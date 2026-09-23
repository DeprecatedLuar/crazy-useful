#!/usr/bin/env bash
# pack - Universal archive creator

check_dependency() {
  local tool=$1
  if ! command -v "$tool" &> /dev/null; then
    echo "Error: '$tool' is required but not installed"
    exit 1
  fi
}

KEEP_ORIGINAL=true
TARGET=""
FORMAT=""
VOLUME=""

i=0
while [ $i -lt $# ]; do
  i=$((i + 1))
  arg=${!i}

  case "$arg" in
    -h|--help)
      TARGET=""
      break
      ;;
    --rm|--remove)
      KEEP_ORIGINAL=false
      ;;
    -v|--volume|-s|--split)
      i=$((i + 1))
      VOLUME=${!i}
      if [ -z "$VOLUME" ]; then
        echo "Error: -v/--volume/-s/--split requires an argument (e.g., '2' or '200mb')"
        exit 1
      fi
      ;;
    -*)
      echo "Error: Unknown option: $arg"
      exit 1
      ;;
    .*)
      if [ -e "$arg" ]; then
        if [ -z "$TARGET" ]; then
          TARGET="$arg"
        else
          FORMAT="$arg"
        fi
      else
        FORMAT="$arg"
      fi
      ;;
    *)
      if [ -z "$TARGET" ]; then
        TARGET="$arg"
      elif [ -z "$FORMAT" ]; then
        FORMAT="$arg"
      else
        echo "Error: Too many arguments"
        exit 1
      fi
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "Usage: pack [--rm] [-v|-s SIZE|COUNT] <file_or_folder> <.extension>"
  echo ""
  echo "Options:"
  echo "  --rm, --remove          Remove original file/folder after packing"
  echo "  -v, --volume SIZE       Split into volumes by size (e.g., '100mb', '1g')"
  echo "  -s, --split SIZE|COUNT  Split by size or number of parts (e.g., '2', '50mb')"
  echo ""
  echo "Supported formats:"
  echo "  .tar.gz, .tgz           Gzip compressed tar (most common)"
  echo "  .tar.bz2, .tbz2         Bzip2 compressed tar"
  echo "  .tar.xz, .txz           XZ compressed tar"
  echo "  .tar                    Uncompressed tar"
  echo "  .zip                    ZIP archive"
  echo "  .bacpac                 ZIP (SQL Server format)"
  echo "  .kra                    ZIP (Krita format)"
  echo "  .7z                     7-Zip archive"
  echo ""
  echo "Examples:"
  echo "  pack folder .tgz        # Create folder.tgz, keep original"
  echo "  pack --rm folder .zip   # Create archive and remove original"
  echo "  pack -v 100mb folder .tgz    # Split into 100MB volumes"
  echo "  pack -s 3 folder .7z    # Split into 3 parts using 7z"
  exit 1
fi

if [ ! -e "$TARGET" ]; then
  echo "Error: File or folder not found: $TARGET"
  exit 1
fi

if [ -z "$FORMAT" ]; then
  echo "Error: Format required. Specify extension (e.g., .tgz, .tar.gz, .zip)"
  echo "Run 'pack --help' for supported formats"
  exit 1
fi

FORMAT="${FORMAT#.}"

BASENAME=$(basename "$TARGET")
ORIGINAL_DIR=$(pwd)
OUTPUT="${BASENAME}.${FORMAT}"

normalize_size() {
  local size=$1
  local format=$2

  local num=$(echo "$size" | grep -oiE '^[0-9]+')
  local unit=$(echo "$size" | grep -oiE '[kmg]b?$' | tr '[:lower:]' '[:upper:]' | tr -d 'B')

  if [ -z "$unit" ]; then
    echo "${num}"
    return
  fi

  case "$format" in
    split)
      echo "${num}${unit}"
      ;;
    zip|7z)
      echo "${num}$(echo "$unit" | tr '[:upper:]' '[:lower:]')"
      ;;
    *)
      echo "${num}${unit}"
      ;;
  esac
}

VOLUME_SIZE=""
VOLUME_COUNT=""
if [ -n "$VOLUME" ]; then
  if echo "$VOLUME" | grep -qE '^[0-9]+$'; then
    VOLUME_COUNT="$VOLUME"
    check_dependency "du"

    TARGET_SIZE=$(du -sb "$TARGET" 2>/dev/null | cut -f1)
    if [ -z "$TARGET_SIZE" ] || [ "$TARGET_SIZE" -eq 0 ]; then
      echo "Error: Cannot determine size of $TARGET"
      exit 1
    fi

    BYTES_PER_VOLUME=$((TARGET_SIZE / VOLUME_COUNT + 1048576))
    VOLUME_SIZE="${BYTES_PER_VOLUME}"
  elif echo "$VOLUME" | grep -qiE '^[0-9]+[kmg]b?$'; then
    VOLUME_SIZE="$VOLUME"
  else
    echo "Error: Invalid volume specification: $VOLUME"
    echo "Use size (e.g., '100mb', '1g') or count (e.g., '2', '5')"
    exit 1
  fi
fi

case "$FORMAT" in
  tar.gz|tgz)
    check_dependency "tar"
    PACK_CMD="tar czf"
    TAR_FLAG="z"
    ;;
  tar.bz2|tbz2)
    check_dependency "tar"
    PACK_CMD="tar cjf"
    TAR_FLAG="j"
    ;;
  tar.xz|txz)
    check_dependency "tar"
    PACK_CMD="tar cJf"
    TAR_FLAG="J"
    ;;
  tar)
    check_dependency "tar"
    PACK_CMD="tar cf"
    TAR_FLAG=""
    ;;
  zip|bacpac|kra)
    check_dependency "zip"
    PACK_CMD="zip"
    ;;
  7z)
    check_dependency "7z"
    PACK_CMD="7z"
    ;;
  *)
    echo "Error: Unsupported format: .$FORMAT"
    echo "Run 'pack' without arguments to see supported formats"
    exit 1
    ;;
esac

if [ -n "$VOLUME_SIZE" ]; then
  case "$PACK_CMD" in
    tar*)
      check_dependency "split"
      USE_SPLIT=true
      ;;
  esac
fi

TEMP_DIR=""
TEMP_TARGET=""
PACK_PID=""
SUCCESS=false

cleanup() {
    if [ -n "$PACK_PID" ] && kill -0 $PACK_PID 2>/dev/null; then
        kill $PACK_PID 2>/dev/null
        wait $PACK_PID 2>/dev/null
    fi

    if [ "$KEEP_ORIGINAL" = false ] && [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        if [ "$SUCCESS" = false ] && [ -e "$TEMP_TARGET" ]; then
            if ! mv "$TEMP_TARGET" "$ORIGINAL_DIR/"; then
                echo "Error: failed to restore '$BASENAME' from $TEMP_TARGET — not deleting, recover it manually" >&2
                trap - INT TERM EXIT
                exit 1
            fi
        fi
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup INT TERM EXIT

if [ "$KEEP_ORIGINAL" = false ]; then
    TEMP_DIR=$(mktemp -d)
    TEMP_TARGET="$TEMP_DIR/$BASENAME"
    if ! mv "$TARGET" "$TEMP_TARGET"; then
        echo "Error: failed to stage '$TARGET' for packing" >&2
        exit 1
    fi
    TARGET="$TEMP_TARGET"
fi

printf "Packing"

case "$PACK_CMD" in
  tar*)
    if [ -n "$VOLUME_SIZE" ]; then
      NORMALIZED_SIZE=$(normalize_size "$VOLUME_SIZE" "split")
      (tar c${TAR_FLAG}f - -C "$(dirname "$TARGET")" "$(basename "$TARGET")" | \
       split -b "$NORMALIZED_SIZE" - "$ORIGINAL_DIR/$OUTPUT.") &
    else
      $PACK_CMD "$ORIGINAL_DIR/$OUTPUT" -C "$(dirname "$TARGET")" "$(basename "$TARGET")" &
    fi
    ;;
  zip)
    if [ -n "$VOLUME_SIZE" ]; then
      NORMALIZED_SIZE=$(normalize_size "$VOLUME_SIZE" "zip")
      (cd "$(dirname "$TARGET")" && zip -rq -s "$NORMALIZED_SIZE" "$ORIGINAL_DIR/$OUTPUT" "$(basename "$TARGET")") &
    else
      (cd "$(dirname "$TARGET")" && zip -rq "$ORIGINAL_DIR/$OUTPUT" "$(basename "$TARGET")") &
    fi
    ;;
  7z)
    if [ -n "$VOLUME_SIZE" ]; then
      NORMALIZED_SIZE=$(normalize_size "$VOLUME_SIZE" "7z")
      (cd "$(dirname "$TARGET")" && 7z a -bd -v"$NORMALIZED_SIZE" "$ORIGINAL_DIR/$OUTPUT" "$(basename "$TARGET")" > /dev/null) &
    else
      (cd "$(dirname "$TARGET")" && 7z a -bd "$ORIGINAL_DIR/$OUTPUT" "$(basename "$TARGET")" > /dev/null) &
    fi
    ;;
esac

PACK_PID=$!
DOTS=""
while kill -0 $PACK_PID 2>/dev/null; do
    printf "\rPacking%-3s" "$DOTS"
    DOTS="${DOTS}."
    if [ ${#DOTS} -gt 3 ]; then DOTS=""; fi
    sleep 0.3
done
wait $PACK_PID
PACK_EXIT=$?

if [ $PACK_EXIT -ne 0 ]; then
    printf "\rPacking failed\n"
    exit 1
fi

SUCCESS=true
printf "\rDone        \n"
