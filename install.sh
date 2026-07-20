#!/bin/zsh
# install.sh — build photocap and install the menu-bar app to /Applications.
#
# Usage:
#   zsh install.sh            # build + copy to /Applications/photocap.app
#   PREFIX=~/Applications zsh install.sh   # install to a custom location
set -e
cd "$(dirname "$0")"

echo "=== building release ==="
xcrun swift build --configuration release

APP="photocap-gui.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp .build/release/photocap-gui "$MACOS/photocap-gui"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>photocap</string>
    <key>CFBundleDisplayName</key>
    <string>photocap</string>
    <key>CFBundleIdentifier</key>
    <string>com.photocap.gui</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>photocap-gui</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped — ad-hoc sign failed)"

DEST="${PREFIX:-/Applications}/photocap.app"
echo "=== installing to $DEST ==="
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "=== done. Launch it from /Applications or your menu bar. ==="
open "$DEST"

# Optional: install the nightly prune agent (substitute the real repo path into
# the plist template, then load it). Set INSTALL_NIGHTLY=1 to enable.
if [ "${INSTALL_NIGHTLY:-0}" = "1" ]; then
  AGENT_SRC="com.photocap.nightly.plist"
  AGENT_DST="$HOME/Library/LaunchAgents/com.photocap.nightly.plist"
  sed "s|__PHOTOCAP_REPO_DIR__|$PWD|g" "$AGENT_SRC" > "$AGENT_DST"
  launchctl load "$AGENT_DST" 2>/dev/null || echo "(launchd load skipped — run manually)"
  echo "=== nightly agent installed to $AGENT_DST ==="
fi
