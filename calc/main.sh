#!/usr/bin/env bash
# calc - simple calculator with natural syntax
# Usage: calc 2x3, calc 4 / 2, calc sqrt(16), echo "2+2" | calc

set -euo pipefail

# Read from stdin if no args
if [[ $# -eq 0 ]]; then
    if [[ -t 0 ]]; then
        echo "Usage: calc <expression>" >&2
        echo "Examples: calc 2x3, calc 4/2, calc sqrt(16)" >&2
        exit 1
    fi
    expr=$(cat)
else
    # Join all args with spaces
    expr="$*"
fi

# Smart replacements for natural syntax
# Replace digit-x-digit with digit*digit (handles 2x3, 10x5)
expr=$(echo "$expr" | sed -E 's/([0-9])x([0-9])/\1*\2/g')

# Replace standalone x with * (handles 2 x 3)
expr=$(echo "$expr" | sed -E 's/ x / * /g')

# Replace digit-( with digit*( for implicit multiplication (handles 2(3+4))
expr=$(echo "$expr" | sed -E 's/([0-9])\(/\1*(/g')

# Evaluate using python with math module
python3 -c "from math import *; print($expr)"
