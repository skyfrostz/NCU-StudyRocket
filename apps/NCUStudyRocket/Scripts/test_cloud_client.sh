#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift build --build-system native --product NCUStudyRocket
BIN_PATH="$(swift build --build-system native --show-bin-path)"
OBJECTS=("$BIN_PATH/StudyRocketShared.build/"*.swift.o)
swiftc -parse-as-library -I "$BIN_PATH/Modules" \
  Sources/NCUStudyRocket/Models.swift Sources/NCUStudyRocket/DesktopCloudBackup.swift Sources/NCUStudyRocket/DesktopCloudWorkspace.swift \
  Tests/DesktopCloudChecks.swift "${OBJECTS[@]}" -o "$BIN_PATH/DesktopCloudChecks"
"$BIN_PATH/DesktopCloudChecks"
