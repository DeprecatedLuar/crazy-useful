#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COLUMN_FORMATTER="$SCRIPT_DIR/columns.sh"
OUTPUT_COLUMN_COUNT=3
PERCENT_COLUMN=1
PROCESS_NAME_COLUMN=2
DETAIL_COLUMN=3
COLUMN_GAP_WIDTH=2
PROCESS_NAME_MAX_WIDTH=32
FORMAT_PROCESS_COLUMNS=(
    "$COLUMN_FORMATTER"
    --delimiter tab
    --columns "$OUTPUT_COLUMN_COUNT"
    --right "$PERCENT_COLUMN"
    --dim "$PROCESS_NAME_COLUMN"
    --dim "$DETAIL_COLUMN"
    --max-width "$PROCESS_NAME_COLUMN:$PROCESS_NAME_MAX_WIDTH"
    --gap "$COLUMN_GAP_WIDTH"
)

if ! "${FORMAT_PROCESS_COLUMNS[@]}"; then
    printf 'Could not format process rows\n' >&2
    exit 1
fi
