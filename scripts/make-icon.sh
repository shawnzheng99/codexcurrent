#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "Usage: $0 SOURCE_PNG OUTPUT_ICNS" >&2
    exit 64
fi

source_png="$1"
output_icns="$2"

if [[ ! -f "$source_png" ]]; then
    echo "Icon source not found: $source_png" >&2
    exit 66
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-current-icon.XXXXXX")"
iconset="$work_dir/AppIcon.iconset"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$iconset"

make_icon() {
    local size="$1"
    local filename="$2"
    sips -z "$size" "$size" "$source_png" --out "$iconset/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

mkdir -p "$(dirname "$output_icns")"
iconutil -c icns "$iconset" -o "$output_icns"
