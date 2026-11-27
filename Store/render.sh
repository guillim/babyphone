#!/bin/bash
# Renders a page to a picture of exactly the given size, with Chrome.
# Usage: render.sh page.html picture.png width height
set -e
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=1 --window-size="$3,$4" --screenshot="$2" "file://$1" >/dev/null 2>&1
