#!/bin/zsh
# Baut Akku Monitor als .app und installiert sie nach ~/Applications.
# Der Build läuft außerhalb von iCloud (~/Library/Caches), damit der Desktop-Sync nicht stört.
set -euo pipefail
cd "${0:A:h}/.."
# Voraussetzungen prüfen, bevor der Compiler mit kryptischen Fehlern kommt.
fail() { print -u2 "Fehler: $1"; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || fail "Akku Monitor braucht einen Mac mit Apple-Chip (M1 oder neuer)."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 15 )) || fail "Akku Monitor braucht macOS 15 (Sequoia) oder neuer, hier läuft $(sw_vers -productVersion)."
command -v swift >/dev/null 2>&1 || fail "Swift fehlt. Installier die Xcode Command Line Tools mit: xcode-select --install"
swift_major="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)"
(( ${swift_major:-0} >= 6 )) || fail "Swift 6 oder neuer nötig (gefunden: ${swift_major:-unbekannt}). Aktualisiere Xcode oder die Command Line Tools über die Softwareaktualisierung."
ioreg -rc AppleSmartBattery 2>/dev/null | grep -q CurrentCapacity || print -u2 "Hinweis: Kein Akku gefunden. Die App ist für MacBooks gedacht und zeigt auf einem Mac ohne Akku kaum etwas."

SCRATCH="$HOME/Library/Caches/akku-monitor-build"
APP="$HOME/Applications/Akku Monitor.app"
BUNDLE_ID="${BUNDLE_ID:-com.heyfreiheit.akkumonitor}"

swift build -c release --scratch-path "$SCRATCH"
BIN="$SCRATCH/release/AkkuMonitor"

pkill -x AkkuMonitor 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AkkuMonitor"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R chrome-extension "$APP/Contents/Resources/chrome-extension"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Akku Monitor</string>
  <key>CFBundleDisplayName</key><string>Akku Monitor</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
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
