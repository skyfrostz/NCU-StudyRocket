#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
mkdir -p .build
BIN_PATH="$(swift build --show-bin-path)"
swiftc -parse-as-library \
  Sources/NCUStudyRocket/Models.swift \
  Scripts/MarkdownChecks.swift \
  -I "$BIN_PATH/Modules" \
  "$BIN_PATH/StudyRocketShared.build/StudyRocketShared.swift.o" \
  "$BIN_PATH/StudyRocketShared.build/Timetable.swift.o" \
  "$BIN_PATH/StudyRocketShared.build/TimetableCourseCatalog.swift.o" \
  -o .build/markdown-checks
.build/markdown-checks
