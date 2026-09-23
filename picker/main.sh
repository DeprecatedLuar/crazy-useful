#!/usr/bin/env bash
command -v hyprpicker &>/dev/null || { echo "hyprpicker not found" >&2; exit 1; }
command -v wl-copy    &>/dev/null || { echo "wl-copy not found" >&2; exit 1; }
color=$(hyprpicker)
echo "$color" | wl-copy
notify-send "Color picked" "$color"
