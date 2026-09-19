#!/bin/sh
# icon.svg -> Unplug.icns, into the directory given. Quick Look does the SVG
# rasterising so nothing has to be installed; run.sh calls this every build.
set -e
cd "$(dirname "$0")"
OUT="${1:?usage: icon.sh <out dir>}"
SET="$OUT/Unplug.iconset"
rm -rf "$SET" "$OUT/icon.svg.png"
mkdir -p "$SET"
qlmanage -t -s 1024 -o "$OUT" icon.svg >/dev/null 2>&1
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$OUT/icon.svg.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$OUT/icon.svg.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT/Unplug.icns"
rm -rf "$SET" "$OUT/icon.svg.png"
