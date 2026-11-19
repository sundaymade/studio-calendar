#!/bin/bash
# Renders icon.html with Chrome and builds ../AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --virtual-time-budget=6000 --screenshot="$PWD/icon-1024.png" "file://$PWD/icon.html" 2>/dev/null
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon-1024.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2)); sips -z $d $d icon-1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o ../AppIcon.icns
rm -rf AppIcon.iconset
echo "AppIcon.icns written"
