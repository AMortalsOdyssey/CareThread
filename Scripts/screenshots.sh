#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/docs/screenshots"
MANIFEST_PATH="$ROOT_DIR/docs/SCREENSHOT_MANIFEST.json"
DERIVED_DATA="${CARETHREAD_SCREENSHOT_DERIVED_DATA:-/tmp/carethread-screenshots-derived}"
BUNDLE_ID="me.multiego.carethread"
MANIFEST_ROWS="$(mktemp "${TMPDIR:-/tmp}/carethread-screenshot-rows.XXXXXX")"
trap 'rm -f "$MANIFEST_ROWS"' EXIT

routes=(
  "01|onboarding|onboarding|standard"
  "02|home|home|standard"
  "03|capture-source|capture-source|standard"
  "04|capture-confirmation|capture-confirmation|standard"
  "05|records|records|standard"
  "06|record-detail|record-detail|standard"
  "07|original-ocr|original-ocr|standard"
  "08|medications|medications|standard"
  "09|followups|followups|standard"
  "10|timeline|timeline|standard"
  "11|brief|brief|standard"
  "12|manage|manage|standard"
  "13|backup|backup|standard"
  "14|lock|lock|standard"
  "15|elder-today|elder-today|elder"
  "16|elder-capture-question|elder-capture-question|elder"
  "17|elder-records|elder-records|elder"
  "18|elder-brief|elder-brief|elder"
)

log() {
  printf '[screenshots] %s\n' "$1"
}

fail() {
  printf '[screenshots] FAIL %s\n' "$1" >&2
  exit 1
}

find_device() {
  xcrun simctl list devices available -j |
    /usr/bin/jq -r '
      .devices
      | to_entries[]
      | select(.key | contains("iOS-18-6"))
      | .value[]
      | select(.name == "iPhone 16")
      | .udid
    ' |
    head -1
}

process_is_running() {
  local device="$1"
  local pid="$2"
  xcrun simctl spawn "$device" launchctl list 2>/dev/null |
    awk -v expected_pid="$pid" -v bundle="$BUNDLE_ID" '
      $1 == expected_pid && index($3, "UIKitApplication:" bundle) == 1 {
        found = 1
      }
      END { exit(found ? 0 : 1) }
    '
}

wait_for_process() {
  local device="$1"
  local pid="$2"
  local attempt
  for attempt in {1..16}; do
    if process_is_running "$device" "$pid"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_ready_marker() {
  local marker_path="$1"
  local device="$2"
  local pid="$3"
  local attempt
  for attempt in {1..24}; do
    if [[ -s "$marker_path" ]]; then
      return 0
    fi
    if ! process_is_running "$device" "$pid"; then
      return 1
    fi
    sleep 0.25
  done
  return 1
}

validate_pngs() {
  local total standard elder dimensions unique_hashes file_path width height
  total="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
  standard="$(find "$OUTPUT_DIR" -maxdepth 1 -type f \
    \( -name '0[1-9]-*.png' -o -name '1[0-4]-*.png' \) |
    wc -l | tr -d ' ')"
  elder="$(find "$OUTPUT_DIR" -maxdepth 1 -type f \
    \( -name '1[5-8]-*.png' \) |
    wc -l | tr -d ' ')"

  [[ "$total" == "36" ]] || fail "PNG 数量应为 36，实际 $total"
  [[ "$standard" == "28" ]] || fail "标准版应为 28，实际 $standard"
  [[ "$elder" == "8" ]] || fail "老人版应为 8，实际 $elder"

  dimensions=""
  while IFS= read -r file_path; do
    [[ -s "$file_path" ]] || fail "空截图：$file_path"
    width="$(sips -g pixelWidth "$file_path" | awk '/pixelWidth/{print $2}')"
    height="$(sips -g pixelHeight "$file_path" | awk '/pixelHeight/{print $2}')"
    [[ "$width" -gt 0 && "$height" -gt 0 ]] ||
      fail "无效尺寸：$file_path"
    dimensions="${dimensions}${width}x${height}"$'\n'
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.png' | sort)

  [[ "$(printf '%s' "$dimensions" | sort -u | wc -l | tr -d ' ')" == "1" ]] ||
    fail "截图尺寸不一致"

  unique_hashes="$(
    find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.png' -print0 |
      sort -z |
      xargs -0 shasum -a 256 |
      awk '{print $1}' |
      sort -u |
      wc -l |
      tr -d ' '
  )"
  [[ "$unique_hashes" == "36" ]] ||
    fail "36 张截图中仅有 $unique_hashes 个不同 SHA-256"

  log "PASS 36 PNG（标准 28 / 老人 8），尺寸 $(printf '%s' "$dimensions" | head -1)，SHA-256 去重 36"
}

cd "$ROOT_DIR"
command -v xcodegen >/dev/null || fail "缺少 xcodegen"
command -v jq >/dev/null || fail "缺少 jq"

DEVICE_UDID="${CARETHREAD_SIMULATOR_UDID:-$(find_device)}"
[[ -n "$DEVICE_UDID" ]] ||
  fail "找不到 iPhone 16 / iOS 18.6 模拟器"

log "使用模拟器 $DEVICE_UDID"
xcrun simctl boot "$DEVICE_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_UDID" -b

log "生成工程并构建一次，36 张图全部复用该构建"
xcodegen generate --quiet
xcodebuild \
  -project CareThread.xcodeproj \
  -scheme CareThread \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/carethread-screenshots-build.log 2>&1 || {
    tail -120 /tmp/carethread-screenshots-build.log >&2
    fail "截图构建失败"
  }

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/CareThread.app"
[[ -d "$APP_PATH" ]] || fail "构建产物不存在：$APP_PATH"
xcrun simctl install "$DEVICE_UDID" "$APP_PATH"
DATA_CONTAINER="$(
  xcrun simctl get_app_container "$DEVICE_UDID" "$BUNDLE_ID" data
)"

mkdir -p "$OUTPUT_DIR"
find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.png' -delete
: >"$MANIFEST_ROWS"

for entry in "${routes[@]}"; do
  IFS='|' read -r number slug route mode <<<"$entry"
  for appearance in light dark; do
    output="$OUTPUT_DIR/$number-$slug-$appearance.png"
    ready_marker="$DATA_CONTAINER/tmp/carethread-screenshot-ready-$route"
    rm -f "$ready_marker"

    xcrun simctl ui "$DEVICE_UDID" appearance "$appearance"
    xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

    args=(
      "-uiTestMode"
      "-displayMode" "$mode"
      "-screenshotRoute" "$route"
      "-AppleLanguages" "(zh-Hans)"
      "-AppleLocale" "zh_CN"
    )
    if [[ "$route" == "capture-confirmation" ]]; then
      args+=("-ScreenshotCaptureConfirmation")
    elif [[ "$route" == "elder-capture-question" ]]; then
      args+=("-ScreenshotElderCaptureQuestion")
    elif [[ "$route" == "lock" ]]; then
      args+=("-M8LockEnabled" "-M8LockResult" "failure")
    fi

    launch_output="$(
      xcrun simctl launch "$DEVICE_UDID" "$BUNDLE_ID" "${args[@]}"
    )"
    pid="${launch_output##*: }"
    [[ "$pid" =~ ^[0-9]+$ ]] ||
      fail "无法解析 $route 的进程号：$launch_output"
    wait_for_process "$DEVICE_UDID" "$pid" ||
      fail "$route/$appearance 启动后进程退出"

    if [[ "$route" == "lock" ]]; then
      # The real privacy gate intentionally prevents its routed content from
      # mounting. Use bounded process polls while its failed-auth state settles.
      for _ in {1..4}; do
        process_is_running "$DEVICE_UDID" "$pid" ||
          fail "lock/$appearance 截图前进程退出"
        sleep 0.25
      done
    else
      wait_for_ready_marker "$ready_marker" "$DEVICE_UDID" "$pid" ||
        fail "$route/$appearance 未发布 AX 就绪标记 screenshot.route.$route"
    fi

    xcrun simctl io "$DEVICE_UDID" screenshot --type=png "$output"
    [[ -s "$output" ]] || fail "截图为空：$output"
    file_path="docs/screenshots/$(basename "$output")"
    ready_marker_name="screenshot.route.$route"
    [[ "$route" == "lock" ]] && ready_marker_name="process-stable"
    width="$(sips -g pixelWidth "$output" | awk '/pixelWidth/{print $2}')"
    height="$(sips -g pixelHeight "$output" | awk '/pixelHeight/{print $2}')"
    sha256="$(shasum -a 256 "$output" | awk '{print $1}')"
    jq -nc \
      --arg file "$file_path" \
      --arg route "$route" \
      --arg mode "$mode" \
      --arg appearance "$appearance" \
      --arg readyMarker "$ready_marker_name" \
      --arg sha256 "$sha256" \
      --argjson width "$width" \
      --argjson height "$height" '
        {
          file: $file,
          route: $route,
          mode: $mode,
          appearance: $appearance,
          readyMarker: $readyMarker,
          width: $width,
          height: $height,
          sha256: $sha256
        }
      ' >>"$MANIFEST_ROWS"
    log "已生成 $(basename "$output")"
  done
done

xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
validate_pngs

IFS=$'\t' read -r DEVICE_NAME RUNTIME_IDENTIFIER < <(
  xcrun simctl list devices available -j |
    jq -r --arg udid "$DEVICE_UDID" '
      .devices
      | to_entries[]
      | .key as $runtime
      | .value[]
      | select(.udid == $udid)
      | [.name, $runtime]
      | @tsv
    '
)
[[ -n "$DEVICE_NAME" && -n "$RUNTIME_IDENTIFIER" ]] ||
  fail "无法读取模拟器设备与 runtime 元数据"
OS_VERSION="$(
  xcrun simctl list runtimes -j |
    jq -r --arg runtime "$RUNTIME_IDENTIFIER" '
      .runtimes[]
      | select(.identifier == $runtime)
      | .version
    '
)"
[[ -n "$OS_VERSION" && "$OS_VERSION" != "null" ]] ||
  fail "无法读取模拟器 OS 版本"

SOURCE_COMMIT="$(git rev-parse HEAD)"
SOURCE_TREE_DIRTY=false
if [[ -n "$(
  git status --porcelain --untracked-files=all -- \
    CareThread CareThreadTests CareThreadUITests Scripts project.yml
)" ]]; then
  SOURCE_TREE_DIRTY=true
fi
SOURCE_FINGERPRINT="$(Scripts/source-fingerprint.sh)"
SCRIPT_SHA256="$(shasum -a 256 Scripts/screenshots.sh | awk '{print $1}')"
GENERATED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

jq -s \
  --arg generatedAtUTC "$GENERATED_AT_UTC" \
  --arg sourceCommit "$SOURCE_COMMIT" \
  --argjson sourceTreeDirty "$SOURCE_TREE_DIRTY" \
  --arg sourceFingerprint "$SOURCE_FINGERPRINT" \
  --arg screenshotScriptSHA256 "$SCRIPT_SHA256" \
  --arg deviceName "$DEVICE_NAME" \
  --arg osVersion "$OS_VERSION" \
  --arg runtimeIdentifier "$RUNTIME_IDENTIFIER" \
  --arg bundleID "$BUNDLE_ID" '
    {
      schemaVersion: 1,
      generator: "Scripts/screenshots.sh",
      generatedAtUTC: $generatedAtUTC,
      sourceCommit: $sourceCommit,
      sourceTreeDirty: $sourceTreeDirty,
      sourceFingerprint: $sourceFingerprint,
      screenshotScriptSHA256: $screenshotScriptSHA256,
      deviceName: $deviceName,
      osVersion: $osVersion,
      runtimeIdentifier: $runtimeIdentifier,
      bundleID: $bundleID,
      configuration: "Debug",
      language: "zh-Hans",
      locale: "zh_CN",
      screenshots: .
    }
  ' "$MANIFEST_ROWS" >"$MANIFEST_PATH"

jq -e '.screenshots | length == 36' "$MANIFEST_PATH" >/dev/null ||
  fail "截图 manifest 条目数不是 36"
log "已生成 docs/SCREENSHOT_MANIFEST.json（sourceTreeDirty=${SOURCE_TREE_DIRTY}）"
