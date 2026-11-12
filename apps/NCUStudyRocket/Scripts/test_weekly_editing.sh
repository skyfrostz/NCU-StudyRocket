#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift build --product NCUStudyRocket
BIN_PATH="$(swift build --show-bin-path)"
CHECK_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/StudyRocket-weekly-editing.XXXXXX")"
trap '/bin/rm -rf -- "$CHECK_OUTPUT"' EXIT
if [[ -f "$BIN_PATH/StudyRocketShared.o" ]]; then
  MODULES_DIR="$BIN_PATH"
  SHARED_OBJECTS=("$BIN_PATH/StudyRocketShared.o")
else
  MODULES_DIR="$BIN_PATH/Modules"
  SHARED_OBJECTS=("$BIN_PATH/StudyRocketShared.build/"*.swift.o)
fi
swiftc -parse-as-library -I "$MODULES_DIR" \
  Sources/NCUStudyRocket/DesktopCloudBackup.swift \
  Sources/NCUStudyRocket/DesktopCloudWorkspace.swift \
  Sources/NCUStudyRocket/Models.swift \
  Sources/NCUStudyRocket/WeeklyPlanEditingSession.swift \
  Tests/WeeklyPlanEditingChecks.swift "${SHARED_OBJECTS[@]}" \
  -o "$CHECK_OUTPUT/WeeklyPlanEditingChecks"
"$CHECK_OUTPUT/WeeklyPlanEditingChecks"
