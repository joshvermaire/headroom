#!/usr/bin/env bash
# Renders the README screenshots from made-up data (--demo), so no real disk shows up.
#
#   scripts/screenshots.sh
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh >/dev/null
BIN="build/Headroom.app/Contents/MacOS/Headroom"
OUT="docs/screenshots"
mkdir -p "$OUT"

for appearance in light dark; do
  "$BIN" --demo --debug-snapshot "$OUT/panel-$appearance.png" --appearance "$appearance"
  "$BIN" --demo --debug-snapshot "$OUT/node-modules-$appearance.png" --page nodeModules --appearance "$appearance"
done

echo "Wrote $(ls "$OUT" | wc -l | tr -d ' ') screenshots to $OUT"
