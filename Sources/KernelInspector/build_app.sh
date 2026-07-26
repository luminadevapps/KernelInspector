#!/bin/bash
# Builds Kernel Inspector as a proper double-clickable .app bundle.
# No Xcode project required — just the Swift toolchain + Command Line Tools.
set -euo pipefail

APP_NAME="Kernel Inspector"
EXE="KernelInspector"
BUNDLE_ID="com.lumina.KernelInspector"

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
APP="$OUT/${APP_NAME}.app"

echo "==> [1/5] Building release binary…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXE"
[ -f "$BIN" ] || { echo "Build product not found at $BIN"; exit 1; }

echo "==> [2/5] Assembling ${APP_NAME}.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp "$ROOT/AppResources/Info.plist" "$APP/Contents/Info.plist"

echo "==> [3/5] Building app icon…"
SRC="$ROOT/AppResources/icon_1024.png"
ICNS="$APP/Contents/Resources/AppIcon.icns"
if command -v iconutil >/dev/null 2>&1 && [ -f "$SRC" ]; then
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  specs=("16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" \
         "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" \
         "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" \
         "1024 icon_512x512@2x.png")
  for s in "${specs[@]}"; do
    set -- $s
    sips -z "$1" "$1" "$SRC" --out "$ICONSET/$2" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET"
  if [ -f "$ICNS" ]; then echo "    icon: $(du -h "$ICNS" | cut -f1) → AppIcon.icns"; else echo "    WARNING: AppIcon.icns not created"; fi
else
  echo "    (skipping icon — iconutil or source PNG missing)"
fi

echo "==> [4/5] Ad-hoc code signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "    (codesign skipped/failed — app still runs)"

echo "==> [5/5] Registering icon & refreshing Dock…"
# Bump mtimes so Finder/Dock notice the new icon, re-register with Launch
# Services, and restart the Dock so the icon shows immediately.
touch "$APP" "$APP/Contents/Info.plist" "$ICNS" 2>/dev/null || true
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP" >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true

echo ""
echo "Done → $APP"
echo "Launching…"
open "$APP" || true
