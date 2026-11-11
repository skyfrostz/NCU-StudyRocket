#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift build --build-system native --product NCUStudyRocket
BIN_PATH="$(swift build --build-system native --show-bin-path)"
OBJECTS=("$BIN_PATH/StudyRocketShared.build/"*.swift.o "$BIN_PATH/StudyRocketChatCore.build/"*.swift.o "$BIN_PATH/cmark_gfm.build/"*.c.o "$BIN_PATH/cmark_gfm_extensions.build/"*.c.o)
swiftc -parse-as-library -I "$BIN_PATH/Modules" \
  -I "$ROOT/.build/checkouts/swift-cmark/src/include" \
  -I "$ROOT/.build/checkouts/swift-cmark/extensions/include" \
  Sources/NCUStudyRocket/DesktopCloudBackup.swift Sources/NCUStudyRocket/DesktopCloudWorkspace.swift Sources/NCUStudyRocket/Models.swift Sources/NCUStudyRocket/StudyChat.swift \
  Sources/NCUStudyRocket/StudyRocketHostClient.swift Sources/NCUStudyRocket/StudyRocketTheme.swift \
  Sources/NCUStudyRocket/UserMessageLayout.swift Tests/DesktopChatChecks.swift \
  "${OBJECTS[@]}" -o "$BIN_PATH/DesktopChatChecks"
"$BIN_PATH/DesktopChatChecks"
