#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release --product StudyRocketHost
APP="$ROOT/.build/StudyRocket Host.app"
rm -rf "$APP"
ICONSET="$ROOT/.build/HostIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/StudyRocketHost "$APP/Contents/MacOS/StudyRocketHost"
swift "$ROOT/Scripts/generate_host_icon.swift" "$ROOT/Assets/NCUStudyRocketLogo.png" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/HostIcon.icns"
MAIN_ICON="/Applications/NCU StudyRocket.app/Contents/Resources/NCUStudyRocket.icns"
if [[ ! -f "$MAIN_ICON" ]]; then
  MAIN_ICON="$ROOT/.build/NCUStudyRocket.icns"
fi
if [[ ! -f "$MAIN_ICON" ]]; then
  print -u2 "NCUStudyRocket.icns was not found. Install the main app first or set up $ROOT/.build/NCUStudyRocket.icns."
  exit 1
fi
cp "$MAIN_ICON" "$APP/Contents/Resources/NCUStudyRocket.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>StudyRocket Host</string>
<key>CFBundleExecutable</key><string>StudyRocketHost</string>
<key>CFBundleIdentifier</key><string>com.skyfrost.ncustudyrocket.host</string>
<key>CFBundleIconFile</key><string>HostIcon</string>
<key>CFBundleName</key><string>StudyRocket Host</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "$APP"
