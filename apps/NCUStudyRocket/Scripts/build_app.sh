#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swiftc Scripts/make_icon.swift -o .build/make-icon
ICONSET="$ROOT/.build/NCUStudyRocket.iconset"
rm -rf "$ICONSET"
.build/make-icon "$ROOT/.build" >/dev/null
iconutil -c icns "$ICONSET" -o "$ROOT/.build/NCUStudyRocket.icns"
swift build -c release
APP="$ROOT/.build/NCU StudyRocket.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/NCUStudyRocket "$APP/Contents/MacOS/NCUStudyRocket"
cp .build/NCUStudyRocket.icns "$APP/Contents/Resources/NCUStudyRocket.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>NCU StudyRocket</string>
<key>CFBundleExecutable</key><string>NCUStudyRocket</string>
<key>CFBundleIdentifier</key><string>com.skyfrost.ncustudyrocket</string>
<key>CFBundleName</key><string>NCU StudyRocket</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>NCUStudyRocket</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "$APP"
