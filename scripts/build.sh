#!/bin/zsh
# Baut Akku Monitor als .app und installiert sie nach ~/Applications.
# Der Build läuft außerhalb von iCloud (~/Library/Caches), damit der Desktop-Sync nicht stört.
set -euo pipefail
cd "${0:A:h}/.."
SCRATCH="$HOME/Library/Caches/akku-monitor-build"
APP="$HOME/Applications/Akku Monitor.app"

swift build -c release --scratch-path "$SCRATCH"
BIN="$SCRATCH/release/AkkuMonitor"

pkill -x AkkuMonitor 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AkkuMonitor"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Akku Monitor</string>
  <key>CFBundleDisplayName</key><string>Akku Monitor</string>
  <key>CFBundleIdentifier</key><string>com.timhildesheim.akkumonitor</string>
  <key>CFBundleExecutable</key><string>AkkuMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Installiert: $APP"
[[ "${1:-}" == "--open" ]] && open "$APP"
