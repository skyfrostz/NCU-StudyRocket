#!/bin/zsh
set -u
set -o pipefail

ROOT="${0:A:h:h}"
REPOSITORY_ROOT="${ROOT:h:h}"
SHARED_ROOT="$REPOSITORY_ROOT/apps/NCUStudyRocketShared"
MOBILE_ROOT="$REPOSITORY_ROOT/apps/NCUStudyRocketMobile"
MODE="${1:-all}"
RG_PATH="$(command -v rg 2>/dev/null || true)"
DEVICE_RUNTIME_FLAG="${2:-}"

case "$MODE" in
  automated|runtime|device|all) ;;
  *)
    print -u2 -- "Usage: zsh Scripts/self_check.sh [automated|runtime|device|all]"
    exit 64
    ;;
esac
if [[ -n "$DEVICE_RUNTIME_FLAG" && "$DEVICE_RUNTIME_FLAG" != "--self-check-device-runtime" ]]; then
  print -u2 -- "Usage: zsh Scripts/self_check.sh [automated|runtime|device|all] [--self-check-device-runtime]"
  exit 64
fi
if [[ "$MODE" != "device" && "$MODE" != "all" && "$DEVICE_RUNTIME_FLAG" == "--self-check-device-runtime" ]]; then
  print -u2 -- "--self-check-device-runtime 只能与 device 或 all 模式一起使用"
  exit 64
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')-$$"
REPORT_ROOT="$ROOT/.build/self-check/$TIMESTAMP"
mkdir -p "$REPORT_ROOT/logs" "$REPORT_ROOT/screenshots"
SUMMARY="$REPORT_ROOT/summary.tsv"
print -- $'status\tcheck\tdetail' > "$SUMMARY"

typeset -i FAILURES=0
typeset -i BLOCKED=0
typeset -i MARKDOWN_MANIFEST_READY=0
ISOLATED_HOST_PID=""
ISOLATED_FIXTURE=""
ISOLATED_STATE=""
ISOLATED_KEYCHAIN_SERVICE=""
ISOLATED_PREFERENCES_SUITE=""

record() {
  local result_status="$1"
  local check="$2"
  local detail="$3"
  print -- "$result_status\t$check\t$detail" >> "$SUMMARY"
  print -- "[$result_status] $check: $detail"
  if [[ "$result_status" == "FAIL" ]]; then
    (( FAILURES += 1 ))
  elif [[ "$result_status" == "BLOCKED" ]]; then
    (( BLOCKED += 1 ))
  fi
}

run_step() {
  local name="$1"
  shift
  local log="$REPORT_ROOT/logs/${name}.log"
  if "$@" > "$log" 2>&1; then
    record PASS "$name" "日志：logs/${name}.log"
    return 0
  else
    record FAIL "$name" "失败；查看 logs/${name}.log"
    return 1
  fi
}

run_in_directory() {
  local directory="$1"
  local name="$2"
  shift 2
  local log="$REPORT_ROOT/logs/${name}.log"
  if (cd "$directory" && "$@") > "$log" 2>&1; then
    record PASS "$name" "日志：logs/${name}.log"
    return 0
  else
    record FAIL "$name" "失败；查看 logs/${name}.log"
    return 1
  fi
}

run_xcode_step() {
  local name="$1"
  shift
  local log="$REPORT_ROOT/logs/${name}.log"
  if "$@" > "$log" 2>&1; then
    record PASS "$name" "日志：logs/${name}.log"
    return 0
  fi
  if /usr/bin/grep -Eqi 'No profiles for|Provisioning profile|requires a development team|code signing|signing certificate' "$log"; then
    record BLOCKED "$name" "签名或 provisioning 未就绪；查看 logs/${name}.log"
    return 2
  fi
  record FAIL "$name" "失败；查看 logs/${name}.log"
  return 1
}

capture_baseline() {
  local baseline="$REPORT_ROOT/baseline.txt"
  local collection_failures=0
  local desktop_installed=0
  local host_running=0
  local tailscale_ready=0
  local host_health=""
  local tailscale=""
  local candidate

  print -- "captured_at=$(date -Iseconds)" > "$baseline"
  print -- "repository=$REPOSITORY_ROOT" >> "$baseline"

  local head origin_main branch
  if head=$(/usr/bin/git -C "$REPOSITORY_ROOT" rev-parse HEAD 2>&1); then
    print -- "head=$head" >> "$baseline"
  else
    print -- "head=unavailable ($head)" >> "$baseline"
    collection_failures=1
  fi
  if origin_main=$(/usr/bin/git -C "$REPOSITORY_ROOT" rev-parse origin/main 2>&1); then
    print -- "origin_main=$origin_main" >> "$baseline"
  else
    print -- "origin_main=unavailable ($origin_main)" >> "$baseline"
    collection_failures=1
  fi
  if branch=$(/usr/bin/git -C "$REPOSITORY_ROOT" branch --show-current 2>&1); then
    print -- "branch=$branch" >> "$baseline"
  else
    print -- "branch=unavailable ($branch)" >> "$baseline"
    collection_failures=1
  fi

  print -- "" >> "$baseline"
  print -- "[git-status]" >> "$baseline"
  if ! /usr/bin/git -C "$REPOSITORY_ROOT" status --short >> "$baseline" 2>&1; then
    collection_failures=1
  fi

  print -- "" >> "$baseline"
  print -- "[system]" >> "$baseline"
  if ! /usr/bin/sw_vers >> "$baseline" 2>&1; then collection_failures=1; fi
  if ! /usr/bin/swift --version >> "$baseline" 2>&1; then collection_failures=1; fi
  if ! /usr/bin/xcodebuild -version >> "$baseline" 2>&1; then collection_failures=1; fi

  print -- "" >> "$baseline"
  print -- "[processes]" >> "$baseline"
  /usr/bin/pgrep -fl 'NCU StudyRocket|StudyRocketHost' >> "$baseline" 2>&1 || print -- "no matching StudyRocket process" >> "$baseline"
  if /usr/bin/pgrep -f 'NCU StudyRocket.app/Contents/MacOS/NCUStudyRocket' >/dev/null 2>&1; then
    desktop_installed=1
  fi
  if /usr/bin/pgrep -f 'StudyRocket Host.app/Contents/MacOS/StudyRocketHost|StudyRocketHost' >/dev/null 2>&1; then
    host_running=1
  fi

  print -- "" >> "$baseline"
  print -- "[installed-desktop-app]" >> "$baseline"
  if [[ -d "/Applications/NCU StudyRocket.app" ]]; then
    desktop_installed=1
    if ! /usr/bin/shasum -a 256 "/Applications/NCU StudyRocket.app/Contents/MacOS/NCUStudyRocket" >> "$baseline" 2>&1; then
      collection_failures=1
    fi
    if ! /usr/bin/codesign -dvv "/Applications/NCU StudyRocket.app" >> "$baseline" 2>&1; then
      collection_failures=1
    fi
    if ! /usr/bin/codesign --verify --deep --strict "/Applications/NCU StudyRocket.app" >> "$baseline" 2>&1; then
      collection_failures=1
    fi
  else
    print -- "not installed" >> "$baseline"
  fi

  print -- "" >> "$baseline"
  print -- "[production-host-public-health]" >> "$baseline"
  if host_health=$(/usr/bin/curl --silent --show-error --max-time 3 "http://127.0.0.1:43817/v1/health" 2>&1); then
    print -- "$host_health" >> "$baseline"
    if [[ "$host_health" == *'"repositoryBound":true'* && "$host_health" == *'"codexReady":true'* && "$host_health" == *'"dynamicToolsReady":true'* ]]; then
      host_running=1
    fi
  else
    print -- "unavailable: $host_health" >> "$baseline"
  fi

  print -- "" >> "$baseline"
  print -- "[tailscale-serve]" >> "$baseline"
  for candidate in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale /usr/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    if [[ -x "$candidate" ]]; then
      tailscale="$candidate"
      break
    fi
  done
  if [[ -n "$tailscale" ]]; then
    local tailscale_output
    if tailscale_output=$("$tailscale" serve status --json 2>&1); then
      print -- "$tailscale_output" >> "$baseline"
      if print -r -- "$tailscale_output" | /usr/bin/grep -Eq '"Proxy"[[:space:]]*:[[:space:]]*"http://127\.0\.0\.1:43817"'; then
        tailscale_ready=1
      fi
    else
      print -- "unavailable: $tailscale_output" >> "$baseline"
    fi
  else
    print -- "tailscale executable unavailable" >> "$baseline"
  fi

  if (( collection_failures > 0 )); then
    record FAIL baseline "版本、Git、进程、安装包哈希或签名采集不完整；查看 baseline.txt"
  else
    record PASS baseline "版本、Git、进程、安装包哈希与签名已完整记录"
  fi
  if (( desktop_installed == 0 )); then
    record BLOCKED desktop-installation "未检测到正式 Desktop 安装包；查看 baseline.txt"
  fi
  if (( host_running == 0 )); then
    record BLOCKED production-host-runtime "正式 Host health 未达到 repositoryBound/codexReady/dynamicToolsReady；查看 baseline.txt"
  fi
  if (( tailscale_ready == 0 )); then
    record BLOCKED tailscale-serve-runtime "未确认 Tailscale Serve 正代理 127.0.0.1:43817；查看 baseline.txt"
  fi
}

write_markdown_manifest() {
  local output="$1"
  [[ -n "$RG_PATH" ]] || return 127
  local temporary="${output}.tmp"
  (
    cd "$REPOSITORY_ROOT" || exit 1
    typeset -aU paths
    paths=("PROFILE.md" "工作台/学期/2026秋季个人课表.md")
    [[ -f "${paths[1]}" && -f "${paths[2]}" ]] || exit 1
    local listed_paths
    listed_paths="$("$RG_PATH" --files -g '*.md' 工作台)" || exit 1
    while IFS= read -r path; do
      [[ -n "$path" ]] && paths+=("$path")
    done <<< "$listed_paths"
    for path in ${(on)paths}; do
      [[ -f "$path" ]] || exit 1
      /usr/bin/shasum -a 256 -- "$path" || exit 1
    done
  ) > "$temporary" || {
    /bin/rm -f -- "$temporary"
    return 1
  }
  [[ -s "$temporary" ]] || {
    /bin/rm -f -- "$temporary"
    return 1
  }
  /bin/mv -- "$temporary" "$output"
}

verify_real_markdown_unchanged() {
  local before="$REPORT_ROOT/real-markdown-before.sha256"
  local after="$REPORT_ROOT/real-markdown-after.sha256"
  if (( MARKDOWN_MANIFEST_READY == 0 )); then
    record FAIL real-markdown-integrity "未能生成执行前真实 Markdown 哈希清单"
    return
  fi
  if ! write_markdown_manifest "$after"; then
    record FAIL real-markdown-integrity "未能生成执行后真实 Markdown 哈希清单"
    return
  fi
  if /usr/bin/diff -u "$before" "$after" > "$REPORT_ROOT/logs/real-markdown-diff.log"; then
    record PASS real-markdown-integrity "PROFILE、工作台 Markdown 与课表源哈希未变化"
  else
    record FAIL real-markdown-integrity "真实 Markdown 哈希变化；查看 logs/real-markdown-diff.log"
  fi
}

cleanup_isolation() {
  if [[ -n "$ISOLATED_HOST_PID" ]] && /bin/kill -0 "$ISOLATED_HOST_PID" 2>/dev/null; then
    /bin/kill "$ISOLATED_HOST_PID" 2>/dev/null || true
    wait "$ISOLATED_HOST_PID" 2>/dev/null || true
  fi
  ISOLATED_HOST_PID=""
  if [[ -n "$ISOLATED_KEYCHAIN_SERVICE" ]]; then
    /usr/bin/security delete-generic-password -s "$ISOLATED_KEYCHAIN_SERVICE" -a "paired-devices" >/dev/null 2>&1 || true
  fi
  ISOLATED_KEYCHAIN_SERVICE=""
  if [[ -n "$ISOLATED_PREFERENCES_SUITE" ]]; then
    /usr/bin/defaults delete "$ISOLATED_PREFERENCES_SUITE" >/dev/null 2>&1 || true
  fi
  ISOLATED_PREFERENCES_SUITE=""
  if [[ -n "$ISOLATED_FIXTURE" && -d "$ISOLATED_FIXTURE" ]]; then
    /bin/rm -rf -- "$ISOLATED_FIXTURE"
  fi
  if [[ -n "$ISOLATED_STATE" && -d "$ISOLATED_STATE" ]]; then
    /bin/rm -rf -- "$ISOLATED_STATE"
  fi
  ISOLATED_FIXTURE=""
  ISOLATED_STATE=""
}

write_fixture_manifest() {
  local fixture_root="$1"
  local output="$2"
  [[ -n "$RG_PATH" ]] || return 127
  local temporary="${output}.tmp"
  (
    cd "$fixture_root" || exit 1
    local paths
    paths="$("$RG_PATH" --files)" || exit 1
    [[ -n "$paths" ]] || exit 1
    while IFS= read -r path; do
      [[ -n "$path" && -f "$path" ]] || exit 1
      /usr/bin/shasum -a 256 -- "$path" || exit 1
    done <<< "$paths"
  ) > "$temporary" || {
    /bin/rm -f -- "$temporary"
    return 1
  }
  [[ -s "$temporary" ]] || {
    /bin/rm -f -- "$temporary"
    return 1
  }
  /bin/mv -- "$temporary" "$output"
}

verify_isolation_fixture_integrity() {
  local fixture_root="$1"
  local before="$2"
  local after="$3"
  local expected_daily="工作台/每日记录/$(date '+%Y-%m').md"
  local before_filtered="${before}.filtered"
  local after_filtered="${after}.filtered"

  /usr/bin/grep -v -F \
    -e "  工作台/下周计划.md" \
    -e "  $expected_daily" \
    "$before" > "$before_filtered" || true
  /usr/bin/grep -v -F \
    -e "  工作台/下周计划.md" \
    -e "  $expected_daily" \
    "$after" > "$after_filtered" || true

  if ! /usr/bin/diff -u "$before_filtered" "$after_filtered" > "$REPORT_ROOT/logs/isolation-fixture-diff.log"; then
    record FAIL isolated-fixture-integrity "除预期周计划和每日账写入外，fixture 存在未授权变化；查看 logs/isolation-fixture-diff.log"
    return
  fi
  if [[ ! -f "$fixture_root/$expected_daily" ]] || ! /usr/bin/grep -Fq "隔离每日行为账" "$fixture_root/$expected_daily"; then
    record FAIL isolated-fixture-integrity "隔离每日行为账没有按预期落盘；查看 fixture 内容"
    return
  fi
  if ! /usr/bin/grep -Fq "隔离多任务甲" "$fixture_root/工作台/下周计划.md" || \
     ! /usr/bin/grep -Fq "隔离待分时事项" "$fixture_root/工作台/下周计划.md"; then
    record FAIL isolated-fixture-integrity "隔离周计划的多任务或待分时写入没有按预期落盘"
    return
  fi
  record PASS isolated-fixture-integrity "预期周计划/每日账写入已核验，其余 fixture 路径与哈希未变化"
}
trap cleanup_isolation EXIT INT TERM

wait_for_isolated_host() {
  local port="$1"
  local attempt
  for attempt in {1..100}; do
    if /usr/bin/curl --silent --show-error --max-time 1 "http://127.0.0.1:${port}/v1/health" > "$REPORT_ROOT/isolation-public-health.json" 2> "$REPORT_ROOT/logs/isolation-health-wait.log"; then
      return 0
    fi
    /bin/sleep 0.2
  done
  return 1
}

run_isolated_http() {
  local port="${STUDYROCKET_SELF_CHECK_PORT:-43818}"
  if [[ ! "$port" == <-> || "$port" -lt 1024 || "$port" -gt 65535 || "$port" -eq 43817 ]]; then
    record FAIL isolated-http "STUDYROCKET_SELF_CHECK_PORT 必须是 1024-65535 且不能使用正式 Host 端口 43817"
    return
  fi

  ISOLATED_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/NCUStudyRocket-fixture.XXXXXX")"
  ISOLATED_STATE="$(mktemp -d "${TMPDIR:-/tmp}/NCUStudyRocket-self-check-state.XXXXXX")"
  local run_id
  run_id="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
  ISOLATED_KEYCHAIN_SERVICE="com.skyfrost.ncustudyrocket.host.self-check.${run_id}"
  ISOLATED_PREFERENCES_SUITE="com.skyfrost.ncustudyrocket.desktop.self-check.${run_id}"

  if ! /bin/cp -R "$ROOT/Fixtures/SelfCheck/." "$ISOLATED_FIXTURE"; then
    record FAIL isolated-fixture "无法复制隔离 fixture"
    return
  fi
  local today_label
  today_label="$(date '+%-m 月 %-d 日')"
  if ! /usr/bin/sed -i '' "s/__TODAY_LABEL__/${today_label}/g" "$ISOLATED_FIXTURE/工作台/下周计划.md"; then
    record FAIL isolated-fixture "无法填充隔离日期"
    return
  fi
  /usr/bin/git -C "$ISOLATED_FIXTURE" init -q > "$REPORT_ROOT/logs/isolation-git-init.log" 2>&1 || true
  if ! write_fixture_manifest "$ISOLATED_FIXTURE" "$REPORT_ROOT/isolation-fixture-before.sha256"; then
    record FAIL isolated-fixture "无法生成隔离 fixture 初始哈希清单"
    return
  fi
  print -- "root=$ISOLATED_FIXTURE" > "$REPORT_ROOT/isolation-config.txt"
  print -- "state=$ISOLATED_STATE" >> "$REPORT_ROOT/isolation-config.txt"
  print -- "port=$port" >> "$REPORT_ROOT/isolation-config.txt"
  print -- "run_id=$run_id" >> "$REPORT_ROOT/isolation-config.txt"

  local failures_before_host_build=$FAILURES
  run_in_directory "$ROOT" isolated-host-build /usr/bin/swift build --product StudyRocketHost
  if (( FAILURES > failures_before_host_build )); then
    return
  fi
  local bin_path
  bin_path="$(cd "$ROOT" && /usr/bin/swift build --show-bin-path)" || {
    record FAIL isolated-host-start "无法确定隔离 Host 产物目录"
    return
  }
  "$bin_path/StudyRocketHost" \
    --autostart \
    --studyrocket-self-check \
    --self-check-root "$ISOLATED_FIXTURE" \
    --self-check-state "$ISOLATED_STATE" \
    --self-check-port "$port" \
    --self-check-run-id "$run_id" \
    --self-check-no-codex \
    > "$REPORT_ROOT/logs/isolation-host.log" 2>&1 &
  ISOLATED_HOST_PID="$!"

  if wait_for_isolated_host "$port"; then
    record PASS isolated-host-start "Host 在 127.0.0.1:${port} 启动，未接触正式端口"
  else
    record FAIL isolated-host-start "隔离 Host 未在端口 ${port} 启动；查看 logs/isolation-host.log"
    return
  fi

  run_in_directory "$ROOT" isolated-http-protocol /usr/bin/swift run StudyRocketSelfCheckHTTPChecks \
    --studyrocket-self-check \
    --self-check-root "$ISOLATED_FIXTURE" \
    --self-check-state "$ISOLATED_STATE" \
    --self-check-port "$port" \
    --self-check-run-id "$run_id" \
    --self-check-no-codex

  if write_fixture_manifest "$ISOLATED_FIXTURE" "$REPORT_ROOT/isolation-fixture-after.sha256"; then
    verify_isolation_fixture_integrity \
      "$ISOLATED_FIXTURE" \
      "$REPORT_ROOT/isolation-fixture-before.sha256" \
      "$REPORT_ROOT/isolation-fixture-after.sha256"
  else
    record FAIL isolated-fixture-final-manifest "无法生成隔离 fixture 最终哈希清单"
  fi
  cleanup_isolation
}

verify_mobile_bundle() {
  local products="$1"
  local expected_app_id="$2"
  local expected_widget_id="$3"
  local expected_group="$4"
  local expected_keychain="$5"
  local expected_url_scheme="$6"
  local label="$7"
  local entitlement_mode="$8"
  local app
  app="$(/usr/bin/find "$products" -type d -name 'NCUStudyRocketMobile.app' -print -quit 2>/dev/null)"
  if [[ -z "$app" ]]; then
    record FAIL "$label" "未找到 NCUStudyRocketMobile.app"
    return
  fi
  local widget="$app/PlugIns/NCUStudyRocketWidget.appex"
  [[ -d "$widget" ]] || {
    record FAIL "$label" "未找到 NCUStudyRocketWidget.appex"
    return
  }
  local app_id widget_id app_group widget_group app_keychain app_url widget_url app_url_scheme app_executable widget_executable app_version widget_version
  app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" 2>/dev/null || true)"
  widget_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget/Info.plist" 2>/dev/null || true)"
  app_group="$(/usr/libexec/PlistBuddy -c 'Print :StudyRocketAppGroupIdentifier' "$app/Info.plist" 2>/dev/null || true)"
  widget_group="$(/usr/libexec/PlistBuddy -c 'Print :StudyRocketAppGroupIdentifier' "$widget/Info.plist" 2>/dev/null || true)"
  app_keychain="$(/usr/libexec/PlistBuddy -c 'Print :StudyRocketKeychainService' "$app/Info.plist" 2>/dev/null || true)"
  app_url="$(/usr/libexec/PlistBuddy -c 'Print :StudyRocketURLScheme' "$app/Info.plist" 2>/dev/null || true)"
  widget_url="$(/usr/libexec/PlistBuddy -c 'Print :StudyRocketURLScheme' "$widget/Info.plist" 2>/dev/null || true)"
  app_url_scheme="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$app/Info.plist" 2>/dev/null || true)"
  app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist" 2>/dev/null || true)"
  widget_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$widget/Info.plist" 2>/dev/null || true)"
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist" 2>/dev/null || true)"
  widget_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$widget/Info.plist" 2>/dev/null || true)"
  if [[ "$app_id" != "$expected_app_id" || "$widget_id" != "$expected_widget_id" ]]; then
    record FAIL "$label" "bundle ID 不匹配（App=${app_id} Widget=${widget_id}）"
    return
  fi
  if [[ "$app_group" != "$expected_group" || "$widget_group" != "$expected_group" ]]; then
    record FAIL "$label" "编译后的 App Group 配置不匹配"
    return
  fi
  if [[ "$app_keychain" != "$expected_keychain" || "$app_url" != "$expected_url_scheme" || "$widget_url" != "$expected_url_scheme" || "$app_url_scheme" != "$expected_url_scheme" ]]; then
    record FAIL "$label" "Keychain service 或 URL scheme 配置不匹配（Keychain=${app_keychain} App=${app_url} URL=${app_url_scheme} Widget=${widget_url}）"
    return
  fi
  if [[ -z "$app_executable" || -z "$widget_executable" || -z "$app_version" || -z "$widget_version" || ! -f "$app/$app_executable" || ! -f "$widget/$widget_executable" || ! -f "$app/Assets.car" ]]; then
    record FAIL "$label" "版本、可执行文件或资源成员不完整"
    return
  fi
  local app_architectures widget_architectures
  app_architectures="$(/usr/bin/lipo -archs "$app/$app_executable" 2>/dev/null || true)"
  widget_architectures="$(/usr/bin/lipo -archs "$widget/$widget_executable" 2>/dev/null || true)"
  if [[ "$app_architectures" != *arm64* || "$widget_architectures" != *arm64* ]]; then
    record FAIL "$label" "App 或 Widget 缺少 arm64 架构"
    return
  fi
  local signing_detail=" 配置"
  if [[ "$entitlement_mode" == "signed" ]]; then
    if ! /usr/bin/codesign --verify --deep --strict "$app" > "$REPORT_ROOT/logs/${label}-codesign.log" 2>&1; then
      record FAIL "$label" "严格签名校验失败；查看 logs/${label}-codesign.log"
      return
    fi
    if ! /usr/bin/codesign -d --entitlements :- "$app" 2>&1 | /usr/bin/grep -Fq "$expected_group" || ! /usr/bin/codesign -d --entitlements :- "$widget" 2>&1 | /usr/bin/grep -Fq "$expected_group"; then
      record FAIL "$label" "签名 App Group entitlement 不匹配"
      return
    fi
    signing_detail=" 与严格签名"
  fi
  record PASS "$label" "bundle ID、版本、arm64、资源、App Group${signing_detail}已核对"
}

discover_simulator_id() {
  /usr/bin/xcrun simctl list devices available 2>/dev/null | /usr/bin/awk -F '[()]' '/^[[:space:]]+iPhone / { print $2; exit }'
}

run_automated() {
  capture_baseline
  if write_markdown_manifest "$REPORT_ROOT/real-markdown-before.sha256"; then
    MARKDOWN_MANIFEST_READY=1
    record PASS real-markdown-baseline "已记录 PROFILE、工作台 Markdown 与课表源哈希"
  else
    record FAIL real-markdown-baseline "无法生成真实 Markdown 哈希清单；请确认 rg、PROFILE、课表源与工作台文件"
  fi
  run_in_directory "$SHARED_ROOT" shared-checks /usr/bin/swift run StudyRocketSharedChecks
  run_in_directory "$ROOT" markdown-checks /bin/zsh Scripts/test_markdown.sh
  run_in_directory "$ROOT" host-model-checks /bin/zsh Scripts/test_host.sh
  run_in_directory "$ROOT" timetable-import-checks /usr/bin/swift run TimetableImportChecks
  run_in_directory "$ROOT" desktop-debug-build /usr/bin/swift build
  run_in_directory "$ROOT" desktop-release-build /usr/bin/swift build -c release
  run_in_directory "$ROOT" desktop-chat-checks /usr/bin/swift run NCUStudyRocketTests
  run_isolated_http

  run_in_directory "$MOBILE_ROOT" mobile-swift-tests /usr/bin/swift test
  run_in_directory "$MOBILE_ROOT" mobile-swift-release-build /usr/bin/swift build -c release
  local mobile_derived="$REPORT_ROOT/mobile-derived-data"
  local simulator_id
  simulator_id="$(discover_simulator_id)"
  if [[ -z "$simulator_id" ]]; then
    record BLOCKED mobile-simulator-discovery "未找到可用 iPhone 模拟器"
  else
    if run_xcode_step mobile-simulator-build /usr/bin/xcodebuild \
      -project "$MOBILE_ROOT/NCUStudyRocketMobile.xcodeproj" \
      -scheme NCUStudyRocketMobile \
      -configuration Debug \
      -destination "platform=iOS Simulator,id=${simulator_id}" \
      -derivedDataPath "$mobile_derived/production-debug" \
      build; then
      verify_mobile_bundle \
        "$mobile_derived/production-debug/Build/Products" \
        "com.skyfrost.ncustudyrocket.mobile" \
        "com.skyfrost.ncustudyrocket.mobile.widget" \
        "group.com.skyfrost.ncustudyrocket" \
        "com.skyfrost.ncustudyrocket.mobile" \
        "ncustudyrocket" \
        mobile-production-bundle-debug \
        simulator
    fi
    if run_xcode_step mobile-self-check-simulator-build /usr/bin/xcodebuild \
      -project "$MOBILE_ROOT/NCUStudyRocketMobile.xcodeproj" \
      -scheme NCUStudyRocketMobile-SelfCheck \
      -configuration SelfCheck \
      -destination "platform=iOS Simulator,id=${simulator_id}" \
      -derivedDataPath "$mobile_derived/self-check-simulator" \
      build; then
      verify_mobile_bundle \
        "$mobile_derived/self-check-simulator/Build/Products" \
        "com.skyfrost.ncustudyrocket.mobile.selfcheck" \
        "com.skyfrost.ncustudyrocket.mobile.selfcheck.widget" \
        "group.com.skyfrost.ncustudyrocket.selfcheck" \
        "com.skyfrost.ncustudyrocket.mobile.selfcheck" \
        "ncustudyrocket-selfcheck" \
        mobile-self-check-bundle-debug \
        simulator
    fi
  fi
  if run_xcode_step mobile-generic-release-build /usr/bin/xcodebuild \
    -project "$MOBILE_ROOT/NCUStudyRocketMobile.xcodeproj" \
    -scheme NCUStudyRocketMobile \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$mobile_derived/production-release" \
    build; then
    verify_mobile_bundle \
      "$mobile_derived/production-release/Build/Products" \
      "com.skyfrost.ncustudyrocket.mobile" \
      "com.skyfrost.ncustudyrocket.mobile.widget" \
      "group.com.skyfrost.ncustudyrocket" \
      "com.skyfrost.ncustudyrocket.mobile" \
      "ncustudyrocket" \
      mobile-production-bundle-release \
      signed
  fi
  if run_xcode_step mobile-self-check-generic-build /usr/bin/xcodebuild \
    -project "$MOBILE_ROOT/NCUStudyRocketMobile.xcodeproj" \
    -scheme NCUStudyRocketMobile-SelfCheck \
    -configuration SelfCheck \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$mobile_derived/self-check-release" \
    build; then
    verify_mobile_bundle \
      "$mobile_derived/self-check-release/Build/Products" \
      "com.skyfrost.ncustudyrocket.mobile.selfcheck" \
      "com.skyfrost.ncustudyrocket.mobile.selfcheck.widget" \
      "group.com.skyfrost.ncustudyrocket.selfcheck" \
      "com.skyfrost.ncustudyrocket.mobile.selfcheck" \
      "ncustudyrocket-selfcheck" \
      mobile-self-check-bundle-release \
      signed
  fi
  run_in_directory "$REPOSITORY_ROOT" git-diff-check /usr/bin/git diff --check
  verify_real_markdown_unchanged
}

write_runtime_checklist() {
  local checklist="$REPORT_ROOT/mac-runtime-checklist.md"
  cat > "$checklist" <<'EOF'
# Mac 运行验收（BLOCKED，需人工完成）

本轮工具不会启动、停止、安装或覆盖正式 Desktop/Host，也无法读取内存中的未保存编辑。开始前确认 Desktop 无未保存草稿、Mobile 无待审核或待同步队列。

- [ ] 在隔离仓库启动 Desktop：首页、课表、周计划、每日复盘、四条航线、资料库、设置、通知入口均可读取。
- [ ] 周计划验证稀疏计划、长文本、多任务、待分时、编辑、退回待分时、保存前未保存提示、窗口缩放与大字号；确认显示为“周四”，不是“周周四”。
- [ ] 日程/周览切换、日期选择和折叠不触发 Markdown 保存；保存后按日期保持当前选择。
- [ ] 使用 `--chat-stress-fixture` 连续滚动 60 秒；检查流式回复切页、停止回复、Markdown 表格和代码块、终态去重。
- [ ] 完成一条真实只读课程答疑、一条情绪支持和一条混合情境对话；情绪支持先承接具体困难，建议前询问，且没有写入 Markdown。
- [ ] Host 持有 Codex 租约时 Desktop 复用 Host；Host 停止后 Desktop 回退 stdio；恢复后没有双 app-server。
- [ ] 使用正式 Host 的公开 health、Desktop、Mobile 和 Widget 核对同一 snapshot 的日期、标题、完成状态和数量。
- [ ] 仅在用户确认无未保存草稿后，按项目安装脚本覆盖安装；不要卸载正式应用。
EOF
  cat > "$REPORT_ROOT/screenshots/README.md" <<'EOF'
# 截图索引

自动化门禁不会在未确认用户草稿状态时打开或操作正式 GUI。人工 Mac、模拟器和真机验收的截图应按页面、外观、Dynamic Type、VoiceOver 和运行模式保存到此目录，并在报告中标明时间与环境。
EOF
  record BLOCKED mac-runtime "需要人工 GUI、无障碍、真实对话与未保存草稿确认；清单：mac-runtime-checklist.md"
}

write_device_checklist() {
  local checklist="$REPORT_ROOT/device-runtime-checklist.md"
  {
    if [[ "$DEVICE_RUNTIME_FLAG" == "--self-check-device-runtime" ]]; then
      print -- "# iPhone / Widget / Tailscale 验收（BLOCKED，需人工完成）"
    else
      print -- "# iPhone / Widget / Tailscale 验收（BLOCKED，需显式设备运行开关）"
    fi
    print -- ""
    print -- "当前脚本只执行只读设备枚举，不安装、卸载、重启正式 App 或清理正式容器。"
    if [[ "$DEVICE_RUNTIME_FLAG" != "--self-check-device-runtime" ]]; then
      print -- "未传入 --self-check-device-runtime，因此本轮不会进入设备运行前置检查。"
    else
      print -- "已传入 --self-check-device-runtime；进入真实设备前置检查前，必须先确认正式 Host 已停止。"
    fi
    print -- ""
    print -- "## 设备枚举"
    /usr/bin/xcrun devicectl list devices 2>&1 || true
    print -- ""
    print -- "## 需完成的验收"
    print -- '- [ ] 解锁真机；若出现 `kAMDMobileImageMounterDeviceLocked`，保持 BLOCKED，不能记为通过。'
    print -- "- [ ] 覆盖安装正式 App，保留正式容器、配对和待同步队列；不要卸载。"
    print -- "- [ ] 安装独立 SelfCheck App，在正式 Host 短暂停止期间使隔离 Host 监听 43817，并通过真实 HTTPS/Tailscale 完成配对、snapshot、SSE、后台/前台、离线补交、冲突回滚、通知、Widget 和一次草案拒绝/确认验证。"
    print -- "- [ ] 检查浅色/深色、最大 Dynamic Type、VoiceOver、Reduce Motion、键盘、前后台和所有主要页面。"
    print -- "- [ ] Widget 检查小/中/大尺寸、零任务、长文本、课表缺失/无课/待刷新、上海时区午夜清空与首页深链。"
    print -- "- [ ] 正式 App 最终只做只读一致性验收，不制造真实完成状态或离线队列。"
    print -- "- [ ] 关闭隔离 Host，删除本 run ID 的 SelfCheck 状态和 Keychain 项，移除 SelfCheck App，恢复正式 Host 后复核正式 snapshot。"
  } > "$checklist"
  if [[ "$DEVICE_RUNTIME_FLAG" == "--self-check-device-runtime" ]]; then
    local production_health
    if production_health=$(/usr/bin/curl --silent --show-error --max-time 2 "http://127.0.0.1:43817/v1/health" 2>&1); then
      print -- "$production_health" > "$REPORT_ROOT/device-production-health.json"
      record BLOCKED device-production-host "正式 Host 仍在运行，设备阶段不会启动隔离 Host 或接触正式设备；先由用户停止正式 Host"
    else
      record BLOCKED device-runtime "设备阶段已显式授权但仍需用户在场完成解锁、签名、安装和恢复；清单：device-runtime-checklist.md"
    fi
  else
    record BLOCKED device-runtime "未传入 --self-check-device-runtime；仅生成只读设备清单，未执行设备运行前置检查"
  fi
}

case "$MODE" in
  automated)
    run_automated
    ;;
  runtime)
    capture_baseline
    write_runtime_checklist
    ;;
  device)
    capture_baseline
    write_device_checklist
    ;;
  all)
    run_automated
    write_runtime_checklist
    write_device_checklist
    ;;
esac

if (( FAILURES > 0 )); then
  RESULT="FAIL"
  EXIT_CODE=1
elif (( BLOCKED > 0 )); then
  RESULT="BLOCKED"
  EXIT_CODE=2
else
  RESULT="PASS"
  EXIT_CODE=0
fi
print -- "$RESULT" > "$REPORT_ROOT/result.txt"
print -- "报告目录：$REPORT_ROOT"
print -- "结论：$RESULT"
exit "$EXIT_CODE"
