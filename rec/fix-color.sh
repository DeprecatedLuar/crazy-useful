#!/usr/bin/env bash
# Re-mux with BT.709 colorspace tags — lossless, fixes player color misinterpretation

fix_color() {
    local file="$1"
    [[ "$file" == *.mp4 ]] || return 0
    local tmp="${file%.mp4}.fix.mp4"
    ffmpeg -loglevel error -i "$file" -c copy \
        -colorspace bt709 -color_primaries bt709 \
        -color_trc bt709 -color_range pc \
        -y "$tmp" && mv "$tmp" "$file"
}
