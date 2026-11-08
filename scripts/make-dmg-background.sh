#!/usr/bin/env bash
# Renders App/DMG/background.html to App/DMG/background.png (640 x 400) and background@2x.png
# (1280 x 800) with headless Google Chrome. Run it after changing the HTML and commit the PNGs;
# releases use the committed images, so building a disk image doesn't need Chrome.
#
#   scripts/make-dmg-background.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/App/DMG"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "$CHROME" ]] || { echo "error: Google Chrome not found at $CHROME (set CHROME=...)" >&2; exit 1; }

PROFILE="$(mktemp -d -t dustling-chrome)"
trap 'rm -rf "$PROFILE"' EXIT

render() { # scale, output
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$PROFILE" --allow-file-access-from-files \
    --window-size=640,400 --force-device-scale-factor="$1" \
    --virtual-time-budget=2000 --screenshot="$2" "file://$DIR/background.html" 2>/dev/null
}

render 1 "$DIR/background.png"
render 2 "$DIR/background@2x.png"

for f in background.png background@2x.png; do
  printf '%s: %s x %s\n' "$f" "$(sips -g pixelWidth "$DIR/$f" | awk '/pixelWidth/{print $2}')" \
    "$(sips -g pixelHeight "$DIR/$f" | awk '/pixelHeight/{print $2}')"
done
