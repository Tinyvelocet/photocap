#!/bin/zsh
# Build and package the photocap menu-bar app as a proper .app bundle.
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

# Copy the compiled executable.
cp .build/release/photocap-gui "$MACOS/photocap-gui"

# Info.plist — LSUIElement=1 makes it an agent (no Dock icon), pure menu-bar app.
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

# Ad-hoc code sign (menu-bar/agent apps are fine ad-hoc; notarization only
# needed for distribution outside your own machine).
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "=== built: $APP ==="
ls -la "$APP/Contents/MacOS/photocap-gui"
echo "To run: open $APP   (or double-click in Finder)"
