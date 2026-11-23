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
  pkill -x Pier 2>/dev/null || true
  # Warten, bis Pier wirklich beendet ist (ein offener Dialog kann das Beenden aufhalten).
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Pier >/dev/null || break; sleep 0.5; done
  if pgrep -x Pier >/dev/null; then echo "Pier läuft noch (offener Dialog?) – bitte schließen und erneut versuchen." >&2; exit 1; fi
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installiert: $DEST"
fi
