#!/usr/bin/env bash

PROGRAM_NAME="$(basename "$0")"
DEFAULT_GAP_WIDTH=1
DEFAULT_DELIMITER="whitespace"
TRUNCATION_MARK="…"

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME --columns COUNT [OPTIONS]

Read whitespace-separated rows from stdin and print aligned columns. The last
column receives the remainder of each row, including spaces. Empty lines split
the input into independently aligned sections and are preserved.

Options:
  -c, --columns COUNT       Maximum number of columns to parse
  -r, --right COLUMN       Right-align COLUMN (repeatable, one-based)
  -d, --dim COLUMN         Dim COLUMN on a color-capable terminal (repeatable)
      --delimiter MODE     Split fields on whitespace or tabs (default: $DEFAULT_DELIMITER)
      --min-width COL:SIZE Set a minimum width for COL (repeatable)
      --max-width COL:SIZE Truncate COL to SIZE characters, ending in $TRUNCATION_MARK (repeatable)
      --gap SIZE           Spaces between columns (default: $DEFAULT_GAP_WIDTH)
      --gap-after COL:SIZE Override the gap after a column (repeatable)
  -h, --help                Show this help

Example:
  printf '80 nginx 127.0.0.1\\n' | \\
    $PROGRAM_NAME --columns 3 --right 1 --min-width 1:5
EOF
}

fail() {
    printf '%s: %s\n' "$PROGRAM_NAME" "$1" >&2
    printf "Try '%s --help' for usage.\n" "$PROGRAM_NAME" >&2
    exit 2
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

columns=""
gap_width="$DEFAULT_GAP_WIDTH"
delimiter="$DEFAULT_DELIMITER"
right_columns=()
dim_columns=()
minimum_widths=()
maximum_widths=()
gap_after_widths=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--columns)
            [[ $# -ge 2 ]] || fail "$1 requires a count"
            columns="$2"
            shift 2
            ;;
        -r|--right)
            [[ $# -ge 2 ]] || fail "$1 requires a column"
            right_columns+=("$2")
            shift 2
            ;;
        -d|--dim)
            [[ $# -ge 2 ]] || fail "$1 requires a column"
            dim_columns+=("$2")
            shift 2
            ;;
        --delimiter)
            [[ $# -ge 2 ]] || fail "$1 requires whitespace or tab"
            delimiter="$2"
            shift 2
            ;;
        --min-width)
            [[ $# -ge 2 ]] || fail "$1 requires COL:SIZE"
            minimum_widths+=("$2")
            shift 2
            ;;
        --max-width)
            [[ $# -ge 2 ]] || fail "$1 requires COL:SIZE"
            maximum_widths+=("$2")
            shift 2
            ;;
        --gap)
            [[ $# -ge 2 ]] || fail "$1 requires a size"
            gap_width="$2"
            shift 2
            ;;
        --gap-after)
            [[ $# -ge 2 ]] || fail "$1 requires COL:SIZE"
            gap_after_widths+=("$2")
            shift 2
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option '$1'"
            ;;
    esac
done

is_positive_integer "$columns" || fail "--columns must be a positive integer"
[[ "$gap_width" =~ ^[0-9]+$ ]] || fail "--gap must be a non-negative integer"
[[ "$delimiter" == "whitespace" || "$delimiter" == "tab" ]] \
    || fail "--delimiter must be whitespace or tab"

for column in "${right_columns[@]}" "${dim_columns[@]}"; do
    is_positive_integer "$column" || fail "column numbers must be positive integers"
    (( column <= columns )) || fail "column $column exceeds --columns $columns"
done

for width in "${minimum_widths[@]}"; do
    [[ "$width" =~ ^([1-9][0-9]*):([0-9]+)$ ]] \
        || fail "minimum widths must use COL:SIZE"
    (( BASH_REMATCH[1] <= columns )) \
        || fail "column ${BASH_REMATCH[1]} exceeds --columns $columns"
done

for width in "${maximum_widths[@]}"; do
    [[ "$width" =~ ^([1-9][0-9]*):([1-9][0-9]*)$ ]] \
        || fail "maximum widths must use COL:SIZE with a positive SIZE"
    (( BASH_REMATCH[1] <= columns )) \
        || fail "column ${BASH_REMATCH[1]} exceeds --columns $columns"
done

for width in "${gap_after_widths[@]}"; do
    [[ "$width" =~ ^([1-9][0-9]*):([0-9]+)$ ]] \
        || fail "gap overrides must use COL:SIZE"
    (( BASH_REMATCH[1] < columns )) \
        || fail "gap override column ${BASH_REMATCH[1]} must precede the last column"
done

join_by_comma() {
    local IFS=,
    printf '%s' "$*"
}

DIM_STYLE=""
RESET_STYLE=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    DIM_STYLE=$'\e[2m'
    RESET_STYLE=$'\e[0m'
fi

awk \
    -v column_limit="$columns" \
    -v gap_width="$gap_width" \
    -v delimiter="$delimiter" \
    -v right_list="$(join_by_comma "${right_columns[@]}")" \
    -v dim_list="$(join_by_comma "${dim_columns[@]}")" \
    -v minimum_list="$(join_by_comma "${minimum_widths[@]}")" \
    -v maximum_list="$(join_by_comma "${maximum_widths[@]}")" \
    -v truncation_mark="$TRUNCATION_MARK" \
    -v gap_after_list="$(join_by_comma "${gap_after_widths[@]}")" \
    -v dim_style="$DIM_STYLE" \
    -v reset_style="$RESET_STYLE" '
    function list_contains(list, value) {
        return index("," list ",", "," value ",") > 0
    }

    function clear_section(row, column) {
        for (row = 1; row <= row_count; row++) {
            for (column = 1; column <= cell_counts[row]; column++) {
                delete cells[row, column]
            }
            delete cell_counts[row]
        }
        for (column = 1; column <= column_limit; column++) {
            delete widths[column]
        }
        row_count = 0
    }

    function print_cell(value, width, align_right, style) {
        printf "%s", style
        if (align_right) {
            printf "%*s", width, value
        } else {
            printf "%-*s", width, value
        }
        if (style != "") {
            printf "%s", reset_style
        }
    }

    function print_section(row, column, last_column, padding, gap, cell_gap) {
        for (row = 1; row <= row_count; row++) {
            last_column = cell_counts[row]
            for (column = 1; column <= last_column; column++) {
                padding = column < last_column ? widths[column] : length(cells[row, column])
                align_right = list_contains(right_list, column)
                style = list_contains(dim_list, column) ? dim_style : ""
                print_cell(cells[row, column], padding, align_right, style)
                if (column < last_column) {
                    cell_gap = column in gap_after ? gap_after[column] : gap_width
                    for (gap = 1; gap <= cell_gap; gap++) {
                        printf " "
                    }
                }
            }
            printf "\n"
        }
        clear_section()
    }

    BEGIN {
        minimum_count = split(minimum_list, minimum_entries, ",")
        for (entry = 1; entry <= minimum_count; entry++) {
            if (minimum_entries[entry] == "") {
                continue
            }
            split(minimum_entries[entry], pair, ":")
            minimum_width[pair[1]] = pair[2]
        }
        maximum_count = split(maximum_list, maximum_entries, ",")
        for (entry = 1; entry <= maximum_count; entry++) {
            if (maximum_entries[entry] == "") {
                continue
            }
            split(maximum_entries[entry], pair, ":")
            maximum_width[pair[1]] = pair[2]
        }
        gap_after_count = split(gap_after_list, gap_after_entries, ",")
        for (entry = 1; entry <= gap_after_count; entry++) {
            if (gap_after_entries[entry] == "") {
                continue
            }
            split(gap_after_entries[entry], pair, ":")
            gap_after[pair[1]] = pair[2]
        }
    }

    {
        line = $0
        if (delimiter == "whitespace") {
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
        } else {
            sub(/^ +/, "", line)
            sub(/ +$/, "", line)
        }

        if (line == "") {
            print_section()
            print ""
            next
        }

        if (delimiter == "tab") {
            part_count = split(line, parts, /\t/)
            join_separator = "\t"
        } else {
            part_count = split(line, parts, /[[:space:]]+/)
            join_separator = " "
        }
        row_count++
        cell_count = part_count < column_limit ? part_count : column_limit
        cell_counts[row_count] = cell_count

        for (column = 1; column <= cell_count; column++) {
            if (column < column_limit) {
                value = parts[column]
            } else {
                value = parts[column]
                for (part = column + 1; part <= part_count; part++) {
                    value = value join_separator parts[part]
                }
            }
            if (column in maximum_width && length(value) > maximum_width[column]) {
                value = substr(value, 1, maximum_width[column] - length(truncation_mark)) truncation_mark
            }
            cells[row_count, column] = value
            if (length(value) > widths[column]) {
                widths[column] = length(value)
            }
        }

        for (column = 1; column <= column_limit; column++) {
            if (minimum_width[column] > widths[column]) {
                widths[column] = minimum_width[column]
            }
        }
    }

    END {
        print_section()
    }
'
