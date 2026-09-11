#!/bin/bash
# Builds Lucid.app. No Xcode project, no SPM — one swiftc call plus a bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="Lucid"
OUT="build/$APP.app"
TARGET="arm64-apple-macos14.0"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "compiling…"
swiftc -O -target "$TARGET" \
    -framework SwiftUI -framework AppKit -framework IOKit \
    -framework Carbon -framework UserNotifications \
    -o "$OUT/Contents/MacOS/$APP" \
    Sources/*.swift

cp Info.plist "$OUT/Contents/Info.plist"

echo "icon…"
swift tools/wordmark.swift --iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$OUT/Contents/Resources/AppIcon.icns"

# The setup window shells out to these, so they ship inside the bundle.
mkdir -p "$OUT/Contents/Resources/hooks"
cp hooks/install-hooks.sh hooks/lucid-notify "$OUT/Contents/Resources/hooks/"
chmod +x "$OUT/Contents/Resources/hooks/"*

# Ad-hoc signature. A real Developer ID would only be needed for distribution
# (or for an SMAppService daemon, which this deliberately avoids).
codesign --force --sign - --timestamp=none "$OUT" 2>/dev/null

echo "built $OUT"
echo "run:      open $OUT"
echo "selftest: $OUT/Contents/MacOS/$APP --selftest"
