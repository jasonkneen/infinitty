#!/bin/zsh
# Build assets/AppIcon.icns from assets/icon.png
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
swift scripts/mask-icon.swift assets/icon.png "$tmp/masked.png"
iconset="$tmp/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$tmp/masked.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  dbl=$((size * 2))
  sips -z $dbl $dbl "$tmp/masked.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o assets/AppIcon.icns
rm -rf "$tmp"
echo "assets/AppIcon.icns written"
