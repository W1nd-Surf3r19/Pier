#!/bin/bash
# Baut Pier.app, signiert sie mit einer festen Identität und installiert nach ~/Applications.
# Feste Signatur = Berechtigungen (Bedienungshilfen, Bildschirmaufnahme) bleiben nach Rebuilds erhalten.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${PIER_SIGN_IDENTITY:-A910E2703F005D185988AB80C46030C706BCC50B}"
APP="build/Pier.app"
DEST="$HOME/Applications/Pier.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pier "$APP/Contents/MacOS/Pier"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
codesign --force --sign "$IDENTITY" "$APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Pier 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installiert: $DEST"
fi
