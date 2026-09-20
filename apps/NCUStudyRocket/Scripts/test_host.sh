#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

CHECK_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/NCUStudyRocket-host-checks.XXXXXX")"
RUNTIME_HOME="$CHECK_OUTPUT/home"
RUNTIME_TMP="$CHECK_OUTPUT/tmp"
SELF_CHECK_ROOT="$CHECK_OUTPUT/repository"
SELF_CHECK_STATE="$CHECK_OUTPUT/state"
SELF_CHECK_RUN_ID="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
typeset -a SELF_CHECK_ARGS
SELF_CHECK_ARGS=(
  --studyrocket-self-check
  --self-check-root "$SELF_CHECK_ROOT"
  --self-check-state "$SELF_CHECK_STATE"
  --self-check-run-id "$SELF_CHECK_RUN_ID"
  --self-check-no-codex
)

cleanup() {
  [[ -n "${CHECK_OUTPUT:-}" && -d "$CHECK_OUTPUT" ]] || return
  /bin/rm -rf -- "$CHECK_OUTPUT"
}
trap cleanup EXIT INT TERM

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "required build artifact is missing: $1"
}

compile_check() {
  local name="$1"
  shift
  print -- "==> Building $name"
  if ! swiftc "$@" -o "$CHECK_OUTPUT/$name"; then
    print -u2 -- "FAIL: $name did not compile"
    return 1
  fi
}

run_check() {
  local name="$1"
  print -- "==> Running $name"
  if ! env CFFIXED_USER_HOME="$RUNTIME_HOME" TMPDIR="$RUNTIME_TMP" "$CHECK_OUTPUT/$name" "${SELF_CHECK_ARGS[@]}"; then
    print -u2 -- "FAIL: $name failed"
    return 1
  fi
  print -- "PASS: $name"
}

mkdir -p "$RUNTIME_HOME" "$RUNTIME_TMP" "$SELF_CHECK_ROOT" "$SELF_CHECK_STATE"

print -- "==> Building StudyRocketHost dependencies"
swift build --product StudyRocketHost
BIN_PATH="$(swift build --show-bin-path)"
MODULES_DIR="$BIN_PATH/Modules"
SHARED_BUILD_DIR="$BIN_PATH/StudyRocketShared.build"

require_file "$MODULES_DIR/StudyRocketShared.swiftmodule"
typeset -a SHARED_OBJECTS
SHARED_OBJECTS=("$SHARED_BUILD_DIR"/*.swift.o(N))
(( ${#SHARED_OBJECTS} > 0 )) || fail "StudyRocketShared object files are missing from $SHARED_BUILD_DIR"

# These checks need Host internal types, so compile each test with just the Host
# implementation it exercises rather than changing Package.swift to expose them.
compile_check HostHTTPRequestParserChecks \
  -parse-as-library \
  Sources/StudyRocketHost/HostHTTPRequestParser.swift \
  Tests/HostHTTPRequestParserChecks.swift

compile_check HostPairingStoreChecks \
  -parse-as-library \
  -I "$MODULES_DIR" \
  Sources/StudyRocketHost/HostPairingStore.swift \
  Tests/HostPairingStoreChecks.swift \
  "${SHARED_OBJECTS[@]}"

compile_check HostWriteServiceChecks \
  -parse-as-library \
  -I "$MODULES_DIR" \
  Sources/StudyRocketHost/HostSnapshotBuilder.swift \
  Sources/StudyRocketHost/HostWriteService.swift \
  Sources/StudyRocketHost/HostProposalStore.swift \
  Tests/HostWriteServiceChecks.swift \
  "${SHARED_OBJECTS[@]}"

compile_check WeeklyPlanModelChecks \
  -parse-as-library \
  -DSTUDYROCKET_MODEL_TESTS \
  -I "$MODULES_DIR" \
  Sources/NCUStudyRocket/Models.swift \
  Tests/WeeklyPlanModelChecks.swift \
  "${SHARED_OBJECTS[@]}"

# HostWriteServiceChecks uses temporary fixtures. CFFIXED_USER_HOME also keeps
# its proposal-backup fixture out of the real Application Support directory.
run_check HostHTTPRequestParserChecks
run_check HostPairingStoreChecks
run_check HostWriteServiceChecks
run_check WeeklyPlanModelChecks

print -- "Host checks passed: 4/4"
