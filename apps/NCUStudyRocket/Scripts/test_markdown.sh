#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
mkdir -p .build
CHECK_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/NCUStudyRocket-markdown-checks.XXXXXX")"
CHECK_ROOT="$CHECK_OUTPUT/repository"
CHECK_STATE="$CHECK_OUTPUT/state"
CHECK_RUN_ID="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"

cleanup() {
  [[ -n "${CHECK_OUTPUT:-}" && -d "$CHECK_OUTPUT" ]] || return
  /bin/rm -rf -- "$CHECK_OUTPUT"
}
trap cleanup EXIT INT TERM

mkdir -p "$CHECK_ROOT" "$CHECK_STATE"
swift build --product NCUStudyRocket
BIN_PATH="$(swift build --show-bin-path)"
typeset -a SHARED_OBJECTS
SHARED_OBJECTS=("$BIN_PATH/StudyRocketShared.build"/*.swift.o(N))
(( ${#SHARED_OBJECTS} > 0 )) || {
  print -u2 -- "StudyRocketShared object files are missing."
  exit 1
}
swiftc -parse-as-library \
  Sources/NCUStudyRocket/Models.swift \
  Scripts/MarkdownChecks.swift \
  -I "$BIN_PATH/Modules" \
  "${SHARED_OBJECTS[@]}" \
  -o .build/markdown-checks
.build/markdown-checks \
  --studyrocket-self-check \
  --self-check-root "$CHECK_ROOT" \
  --self-check-state "$CHECK_STATE" \
  --self-check-run-id "$CHECK_RUN_ID" \
  --self-check-no-codex
