#!/usr/bin/env bash
# Builds Headroom.app from the Swift package.
#
#   scripts/build-app.sh            # build into ./build/Headroom.app
#   scripts/build-app.sh --install  # also copy to ~/Applications and relaunch
#
# Signing: uses $HEADROOM_SIGN_IDENTITY if set, else the first "Apple Development"
# identity in your keychain, else ad-hoc. A real identity keeps the code signature
# stable across rebuilds, so macOS remembers the Full Disk Access grant.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/Headroom.app"

swift build -c release --product Headroom
BIN="$(swift build -c release --product Headroom --show-bin-path)/Headroom"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Headroom"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.joshvermaire.headroom</string>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Josh Vermaire</string>
</dict>
</plist>
PLIST

IDENTITY="${HEADROOM_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ { print $2; exit }')"
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
  echo "Signed with $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed ad hoc. Full Disk Access will need re-granting after each rebuild."
fi

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/Headroom.app"
  mkdir -p "$HOME/Applications"
  pkill -x Headroom 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
