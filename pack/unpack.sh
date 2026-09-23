#!/usr/bin/env bash
# unpack - Universal archive extractor

check_dependency() {
  local tool=$1
  if ! command -v "$tool" &> /dev/null; then
    echo "Error: '$tool' is required but not installed"
    exit 1
  fi
}

KEEP_ORIGINAL=true
DEBUG=false
FORCE=false

while [[ "$1" == -* ]]; do
  case "$1" in
    -h|--help)
      shift
      set -- ""
      break
      ;;
    --rm|--remove)
      KEEP_ORIGINAL=false
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    *)
      echo "Error: Unknown option: $1"
      exit 1
      ;;
  esac
done

if [ -z "$1" ]; then
  echo "Usage: unpack [--rm] [-f] [--debug] <archive_file>"
  echo "  --rm, --remove  Remove original archive after unpacking"
  echo "  -f, --force     Overwrite existing files/folders"
  echo "  --debug         Show debug information"
  exit 1
fi

if [ ! -f "$1" ]; then
  echo "Error: File not found: $1"
  exit 1
fi

ARCHIVE="$1"
ARCHIVE_NAME=$(basename "$ARCHIVE")
IS_SPLIT=false

if [[ "$ARCHIVE_NAME" == *.aa ]]; then
  BASE_NAME="${ARCHIVE_NAME%.aa}"
  case "$BASE_NAME" in
    *.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar)
      IS_SPLIT=true
      SPLIT_PATTERN="${ARCHIVE%.aa}.a?"
      if [ "$DEBUG" = true ]; then
        echo "[DEBUG] Split archive detected"
        echo "[DEBUG] Base name: $BASE_NAME"
        echo "[DEBUG] Split pattern: $SPLIT_PATTERN"
        echo "[DEBUG] Matching files:"
        ls -1 $SPLIT_PATTERN 2>&1 | head -10
        echo "[DEBUG] Total parts: $(ls -1 $SPLIT_PATTERN 2>/dev/null | wc -l)"
      fi
      ;;
  esac
fi
ORIGINAL_DIR=$(pwd)

# Longest/compound extensions must precede their bare suffix (tar.gz before gz, etc.)
# Kept as the single source of truth for supported formats; the dispatch case below
# must stay in sync since each format needs different extraction handling.
ARCHIVE_EXTENSIONS=(
  tar.gz tgz tar.bz2 tbz2 tar.xz txz tar
  zip bacpac kra docx xlsx pptx
  7z iso rar gz bz2 xz
)

if [ "$IS_SPLIT" = false ]; then
  BASE_NAME="$ARCHIVE_NAME"
  for ext in "${ARCHIVE_EXTENSIONS[@]}"; do
    if [[ "$ARCHIVE_NAME" == *".$ext" ]]; then
      BASE_NAME="${ARCHIVE_NAME%."$ext"}"
      break
    fi
  done
fi

TEMP_ARCHIVE_DIR=""
TEMP_EXTRACT_DIR=$(mktemp -d)
TEMP_ARCHIVE=""
UNPACK_PID=""
SUCCESS=false

cleanup() {
    if [ -n "$UNPACK_PID" ] && kill -0 $UNPACK_PID 2>/dev/null; then
        kill $UNPACK_PID 2>/dev/null
        wait $UNPACK_PID 2>/dev/null
    fi

    if [ -n "$TEMP_ARCHIVE_DIR" ] && [ -d "$TEMP_ARCHIVE_DIR" ]; then
        rm -rf "$TEMP_ARCHIVE_DIR"
    fi

    if [ -n "$TEMP_EXTRACT_DIR" ] && [ -d "$TEMP_EXTRACT_DIR" ]; then
        rm -rf "$TEMP_EXTRACT_DIR"
    fi
}

trap cleanup INT TERM EXIT

printf "Unpacking"

if [ "$IS_SPLIT" = true ]; then
  check_dependency "tar"
  check_dependency "cat"

  BASE_ARCHIVE="${ARCHIVE%.aa}"
  case "$BASE_ARCHIVE" in
    *.tar.gz|*.tgz)
      (cat $SPLIT_PATTERN | tar xzf - -C "$TEMP_EXTRACT_DIR") &
      ;;
    *.tar.bz2|*.tbz2)
      (cat $SPLIT_PATTERN | tar xjf - -C "$TEMP_EXTRACT_DIR") &
      ;;
    *.tar.xz|*.txz)
      (cat $SPLIT_PATTERN | tar xJf - -C "$TEMP_EXTRACT_DIR") &
      ;;
    *.tar)
      (cat $SPLIT_PATTERN | tar xf - -C "$TEMP_EXTRACT_DIR") &
      ;;
  esac
else
  case "$ARCHIVE" in
    *.tar.gz|*.tgz)
      check_dependency "tar"
      tar xzf "$ARCHIVE" -C "$TEMP_EXTRACT_DIR" &
      ;;
    *.tar.bz2|*.tbz2)
      check_dependency "tar"
      tar xjf "$ARCHIVE" -C "$TEMP_EXTRACT_DIR" &
      ;;
    *.tar.xz|*.txz)
      check_dependency "tar"
      tar xJf "$ARCHIVE" -C "$TEMP_EXTRACT_DIR" &
      ;;
    *.tar)
      check_dependency "tar"
      tar xf "$ARCHIVE" -C "$TEMP_EXTRACT_DIR" &
      ;;
esac
fi

if [ "$IS_SPLIT" = false ]; then
  case "$ARCHIVE" in
  *.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar)
    ;;
  *.zip|*.bacpac|*.kra|*.docx|*.xlsx|*.pptx)
    check_dependency "unzip"
    if [ "$FORCE" = true ]; then
      unzip -qo "$ARCHIVE" -d "$TEMP_EXTRACT_DIR" &
    else
      unzip -q "$ARCHIVE" -d "$TEMP_EXTRACT_DIR" &
    fi
    ;;
  *.7z|*.iso)
    check_dependency "7z"
    7z x -bd -o"$TEMP_EXTRACT_DIR" "$ARCHIVE" > /dev/null &
    ;;
  *.rar)
    check_dependency "unrar"
    unrar x -inul "$ARCHIVE" "$TEMP_EXTRACT_DIR/" &
    ;;
  *.gz)
    check_dependency "gzip"
    if [ "$KEEP_ORIGINAL" = true ]; then
      gunzip -k -c "$ARCHIVE" > "$TEMP_EXTRACT_DIR/${ARCHIVE_NAME%.gz}" &
    else
      gunzip -c "$ARCHIVE" > "$TEMP_EXTRACT_DIR/${ARCHIVE_NAME%.gz}" &
    fi
    ;;
  *.bz2)
    check_dependency "bzip2"
    if [ "$KEEP_ORIGINAL" = true ]; then
      bunzip2 -k -c "$ARCHIVE" > "$TEMP_EXTRACT_DIR/${ARCHIVE_NAME%.bz2}" &
    else
      bunzip2 -c "$ARCHIVE" > "$TEMP_EXTRACT_DIR/${ARCHIVE_NAME%.bz2}" &
    fi
    ;;
  *.xz)
    check_dependency "xz"
    if [ "$KEEP_ORIGINAL" = true ]; then
      xz -d -k -c "$ARCHIVE" > "$TEMP_EXTRACT_DIR/${ARCHIVE_NAME%.xz}" &
    else
      xz -d -c "$ARCHIVE" > "$TEMP_EXTRACT_DIR/${ARCHIVE_NAME%.xz}" &
    fi
    ;;
    *)
      echo "Error: Unknown archive format: $ARCHIVE"
      echo "Supported formats: .tar.gz, .tar.bz2, .tar.xz, .tar, .zip, .docx, .xlsx, .pptx, .bacpac, .kra, .7z, .iso, .rar, .gz, .bz2, .xz"
      exit 1
      ;;
  esac
fi

UNPACK_PID=$!
DOTS=""
while kill -0 $UNPACK_PID 2>/dev/null; do
    printf "\rUnpacking%-3s" "$DOTS"
    DOTS="${DOTS}."
    if [ ${#DOTS} -gt 3 ]; then DOTS=""; fi
    sleep 0.3
done
wait $UNPACK_PID
UNPACK_EXIT=$?

if [ $UNPACK_EXIT -ne 0 ]; then
    printf "\rUnpacking failed\n"
    exit 1
fi

shopt -s dotglob nullglob
EXTRACTED_ITEMS=("$TEMP_EXTRACT_DIR"/*)
shopt -u dotglob nullglob

FINAL_DEST=""
if [ ${#EXTRACTED_ITEMS[@]} -eq 1 ]; then
    ITEM_NAME=$(basename "${EXTRACTED_ITEMS[0]}")
    FINAL_DEST="$ORIGINAL_DIR/$ITEM_NAME"
else
    FINAL_DEST="$ORIGINAL_DIR/$BASE_NAME"
fi

if [ -e "$FINAL_DEST" ] && [ "$FORCE" = false ]; then
    printf "\rError: '%s' already exists. Use -f to overwrite.\n" "$(basename "$FINAL_DEST")"
    exit 1
fi

if [ -e "$FINAL_DEST" ] && [ "$FORCE" = true ]; then
    rm -rf "$FINAL_DEST"
fi

if [ ${#EXTRACTED_ITEMS[@]} -eq 1 ]; then
    mv "${EXTRACTED_ITEMS[0]}" "$ORIGINAL_DIR/"
else
    mkdir -p "$FINAL_DEST"
    mv "$TEMP_EXTRACT_DIR"/* "$FINAL_DEST/"
fi

SUCCESS=true

if [ "$KEEP_ORIGINAL" = false ]; then
    rm -f "$ARCHIVE"
fi

if [ "$IS_SPLIT" = true ] && [ "$KEEP_ORIGINAL" = false ]; then
    rm -f $SPLIT_PATTERN
fi

printf "\rExtracted to: %s\n" "$(basename "$FINAL_DEST")"
