#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  print -u2 "usage: $0 [debug|release]"
  exit 2
fi
XCODE_CONFIGURATION="Release"
if [[ "$CONFIGURATION" == "debug" ]]; then XCODE_CONFIGURATION="Debug"; fi
swiftc Scripts/make_icon.swift -o .build/make-icon
ICONSET="$ROOT/.build/NCUStudyRocket.iconset"
rm -rf "$ICONSET"
.build/make-icon "$ROOT/.build" >/dev/null
iconutil -c icns "$ICONSET" -o "$ROOT/.build/NCUStudyRocket.icns"
swift build -c "$CONFIGURATION"
xcodebuild -project NCUStudyRocketDesktopWidget.xcodeproj \
  -target NCUStudyRocketDesktopWidget \
  -configuration "$XCODE_CONFIGURATION" \
  -sdk macosx \
  SYMROOT="$ROOT/.build/widget-products" \
  CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="$ROOT/.build/NCU StudyRocket.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/PlugIns"
cp ".build/arm64-apple-macosx/$CONFIGURATION/NCUStudyRocket" "$APP/Contents/MacOS/NCUStudyRocket"
cp .build/NCUStudyRocket.icns "$APP/Contents/Resources/NCUStudyRocket.icns"
cp -R "$ROOT/.build/widget-products/$XCODE_CONFIGURATION/NCUStudyRocketDesktopWidget.appex" "$APP/Contents/PlugIns/"
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
<key>NSUserNotificationAlertStyle</key><string>alert</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>StudyRocket Mac</string><key>CFBundleURLSchemes</key><array><string>ncustudyrocket-mac</string></array></dict></array>
</dict></plist>
PLIST
SIGN_IDENTITY="${STUDYROCKET_CODESIGN_IDENTITY:-Apple Development: skyfrostzhong@gmail.com (3AMP6XVPD4)}"
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Widget/AppGroup.entitlements" "$APP/Contents/PlugIns/NCUStudyRocketDesktopWidget.appex" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Widget/AppGroup.entitlements" "$APP" >/dev/null
TEAM_ID="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "$TEAM_ID" != "QNRY5H3QJ9" ]]; then
  print -u2 "StudyRocket widget requires team QNRY5H3QJ9; signed with ${TEAM_ID:-none}."
  exit 1
fi
codesign --verify --deep --strict "$APP"
echo "$APP"
