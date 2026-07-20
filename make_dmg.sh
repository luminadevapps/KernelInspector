#!/bin/bash
# Builds Kernel Inspector and packages it into a distributable .dmg
# suitable for a GitHub release (drag-to-Applications installer).
#
#   ./make_dmg.sh            # builds app (via build_app.sh) then makes the DMG
#   ./make_dmg.sh --no-build # skip the build, package the existing build/*.app
#
# Requires macOS (uses hdiutil / SetFile). No signing identity needed.
set -euo pipefail

APP_NAME="Kernel Inspector"
VOL_NAME="Kernel Inspector"
VERSION="1.0"

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
APP="$OUT/${APP_NAME}.app"
STAGE="$OUT/dmg-stage"
DMG="$OUT/KernelInspector-${VERSION}.dmg"
TMP_DMG="$OUT/.ki-tmp.dmg"

# 1. Build the app unless told to skip.
if [ "${1:-}" != "--no-build" ]; then
  echo "==> Building app…"
  "$ROOT/build_app.sh" >/dev/null || { echo "build_app.sh failed"; exit 1; }
fi
[ -d "$APP" ] || { echo "No app at $APP — run without --no-build first."; exit 1; }

# 2. Stage a clean folder: the .app + a symlink to /Applications.
echo "==> Staging DMG contents…"
rm -rf "$STAGE" "$DMG" "$TMP_DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3. Create a read/write DMG we can arrange, sized to fit + headroom.
echo "==> Creating disk image…"
SIZE_KB=$(du -sk "$STAGE" | cut -f1)
SIZE_MB=$(( SIZE_KB / 1024 + 40 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" \
  -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$TMP_DMG" >/dev/null

# 4. Mount it and arrange the icon layout (best-effort; harmless if it fails).
echo "==> Arranging window…"
MOUNT_DIR="/Volumes/$VOL_NAME"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" | \
      grep -E '^/dev/' | head -1 | awk '{print $1}')
sleep 2

osascript <<EOF 2>/dev/null || true
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 720, 460}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 112
    set position of item "${APP_NAME}.app" of container window to {140, 170}
    set position of item "Applications" of container window to {380, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
sync

# 5. Detach, convert to compressed read-only, clean up.
echo "==> Finalising…"
hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGE"

echo ""
echo "Done → $DMG"
echo "Size: $(du -h "$DMG" | cut -f1)"
echo "Upload this .dmg as a GitHub release asset."
open -R "$DMG" 2>/dev/null || true
