#!/bin/zsh
# Build ClipboardHistory → .app bundle, optionally install + autostart.
#   ./build.sh            build only (output: build/ClipboardHistory.app)
#   ./build.sh --install  build, copy to ~/Applications, register LaunchAgent
set -e
cd "$(dirname "$0")"

APP_NAME="ClipboardHistory"
BUILD=build
APP="$BUILD/$APP_NAME.app"

echo "▸ Compiling Swift sources…"
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/$APP_NAME" \
  Sources/*.swift \
  -framework Cocoa -framework Carbon -framework Security \
  -framework CryptoKit -framework ApplicationServices

echo "▸ Assembling .app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD/$APP_NAME" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.chrisgomes.clipboardhistory</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" 2>/dev/null || true
echo "✓ Built $APP"

if [[ "$1" == "--install" ]]; then
  echo "▸ Installing to ~/Applications…"
  mkdir -p ~/Applications
  rm -rf ~/Applications/"$APP_NAME".app
  cp -R "$APP" ~/Applications/

  echo "▸ Registering LaunchAgent (starts at login)…"
  PLIST_PATH=~/Library/LaunchAgents/com.chrisgomes.clipboardhistory.plist
  cat > "$PLIST_PATH" <<LAUNCH
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.chrisgomes.clipboardhistory</string>
    <key>ProgramArguments</key>
    <array><string>$HOME/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
LAUNCH

  launchctl bootout "gui/$(id -u)/com.chrisgomes.clipboardhistory" 2>/dev/null || true
  sleep 2   # let the old instance exit before re-bootstrap
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  echo "✓ Installed & running — look for the clipboard icon in the menu bar."
else
  echo "Run './build.sh --install' to install to ~/Applications with autostart."
fi
