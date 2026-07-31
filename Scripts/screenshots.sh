#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/docs/screenshots"
MANIFEST_PATH="$ROOT_DIR/docs/SCREENSHOT_MANIFEST.json"
DERIVED_DATA="${CARETHREAD_SCREENSHOT_DERIVED_DATA:-/tmp/carethread-screenshots-derived}"
BUNDLE_ID="me.multiego.carethread"
EXPECTED_DEVICE_NAME="iPhone 16"
EXPECTED_OS_VERSION="26.5"
MANIFEST_ROWS="$(mktemp "${TMPDIR:-/tmp}/carethread-screenshot-rows.XXXXXX")"
trap 'rm -f "$MANIFEST_ROWS"' EXIT
source "$ROOT_DIR/Scripts/screenshot-routes.sh"
routes=("${CARETHREAD_SCREENSHOT_ROUTES[@]}")

log() {
  printf '[screenshots] %s\n' "$1"
}

fail() {
  printf '[screenshots] FAIL %s\n' "$1" >&2
  exit 1
}

find_or_create_device() {
  local runtime device
  runtime="$(
    xcrun simctl list runtimes -j |
      /usr/bin/jq -r --arg version "$EXPECTED_OS_VERSION" '
        [
          .runtimes[]
          | select(
              .isAvailable == true
              and .platform == "iOS"
              and .version == $version
            )
        ]
        | first
        | select(. != null)
        | .identifier
      '
  )"
  [[ -n "$runtime" ]] || return 1
  device="$(
    xcrun simctl list devices available -j |
      /usr/bin/jq -r --arg runtime "$runtime" '
        [
          .devices[$runtime][]
          | select(.isAvailable == true and .name == "iPhone 16")
        ]
        | first
        | select(. != null)
        | .udid
      '
  )"
  if [[ -n "$device" ]]; then
    printf '%s\n' "$device"
    return
  fi
  xcrun simctl create \
    "iPhone 16" \
    "com.apple.CoreSimulator.SimDeviceType.iPhone-16" \
    "$runtime"
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
  for attempt in {1..40}; do
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
  standard=0
  elder=0
  for entry in "${routes[@]}"; do
    IFS='|' read -r number slug _ mode _ <<<"$entry"
    for appearance in light dark; do
      file_path="$OUTPUT_DIR/$number-$slug-$appearance.png"
      [[ -s "$file_path" ]] || continue
      if [[ "$mode" == "standard" ]]; then
        standard=$((standard + 1))
      else
        elder=$((elder + 1))
      fi
    done
  done

  [[ "$total" == "$CARETHREAD_SCREENSHOT_COUNT" ]] ||
    fail "PNG 数量应为 $CARETHREAD_SCREENSHOT_COUNT，实际 $total"
  [[ "$standard" == "$CARETHREAD_SCREENSHOT_STANDARD_COUNT" ]] ||
    fail "标准版应为 $CARETHREAD_SCREENSHOT_STANDARD_COUNT，实际 $standard"
  [[ "$elder" == "$CARETHREAD_SCREENSHOT_ELDER_COUNT" ]] ||
    fail "老人版应为 $CARETHREAD_SCREENSHOT_ELDER_COUNT，实际 $elder"

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
  [[ "$unique_hashes" == "$CARETHREAD_SCREENSHOT_COUNT" ]] ||
    fail "$CARETHREAD_SCREENSHOT_COUNT 张截图中仅有 $unique_hashes 个不同 SHA-256"

  log "PASS $CARETHREAD_SCREENSHOT_COUNT PNG（标准 $CARETHREAD_SCREENSHOT_STANDARD_COUNT / 老人 $CARETHREAD_SCREENSHOT_ELDER_COUNT），尺寸 $(printf '%s' "$dimensions" | head -1)，SHA-256 去重 $CARETHREAD_SCREENSHOT_COUNT"
}

cd "$ROOT_DIR"
command -v xcodegen >/dev/null || fail "缺少 xcodegen"
command -v jq >/dev/null || fail "缺少 jq"

if [[ -n "${CARETHREAD_SIMULATOR_UDID:-}" ]]; then
  DEVICE_UDID="$CARETHREAD_SIMULATOR_UDID"
elif ! DEVICE_UDID="$(find_or_create_device)"; then
  fail "无法为 iOS $EXPECTED_OS_VERSION 找到或创建 iPhone 16；请确认平台组件完整并重启 Xcode/CoreSimulator"
fi
[[ -n "$DEVICE_UDID" ]] ||
  fail "iOS $EXPECTED_OS_VERSION 的 iPhone 16 设备标识为空"

log "使用模拟器 $DEVICE_UDID"
xcrun simctl boot "$DEVICE_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_UDID" -b

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
[[ "$DEVICE_NAME" == "$EXPECTED_DEVICE_NAME" &&
  -n "$RUNTIME_IDENTIFIER" ]] ||
  fail "截图设备必须是可用的 $EXPECTED_DEVICE_NAME，当前 UDID 不符合"
OS_VERSION="$(
  xcrun simctl list runtimes -j |
    jq -r --arg runtime "$RUNTIME_IDENTIFIER" '
      .runtimes[]
      | select(.identifier == $runtime)
      | .version
    '
)"
[[ "$OS_VERSION" == "$EXPECTED_OS_VERSION" ]] ||
  fail "截图 runtime 必须是 iOS $EXPECTED_OS_VERSION，实际为 ${OS_VERSION:-未知}"

log "生成工程并构建一次，$CARETHREAD_SCREENSHOT_COUNT 张图全部复用该构建"
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
  IFS='|' read -r number slug route mode expected_shell \
    expected_presentation expected_selected_tab expected_tab_bar \
    expected_feature_marker <<<"$entry"
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
      "-screenshotAppearance" "$appearance"
      "-AppleLanguages" "(zh-Hans)"
      "-AppleLocale" "zh_CN"
    )
    if [[ "$route" == "onboarding" ]]; then
      args+=("-resetOnboarding")
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

    wait_for_ready_marker "$ready_marker" "$DEVICE_UDID" "$pid" ||
      fail "$route/$appearance 未发布真实功能就绪标记 screenshot.route.$route"
    jq -e \
      --arg route "$route" \
      --arg shell "$expected_shell" \
      --arg presentation "$expected_presentation" \
      --argjson selectedTab "${expected_selected_tab:-null}" \
      --argjson tabBarExpected "$expected_tab_bar" \
      --arg featureMarker "$expected_feature_marker" \
      --arg resolvedAppearance "$appearance" '
        .route == $route
        and .shell == $shell
        and .presentation == $presentation
        and .selectedTab == $selectedTab
        and .tabBarExpected == $tabBarExpected
        and .featureMarker == $featureMarker
        and .resolvedAppearance == $resolvedAppearance
      ' "$ready_marker" >/dev/null ||
      fail "$route/$appearance 就绪载荷与真实导航壳合同不一致"
    ready_payload="$(jq -c . "$ready_marker")"

    xcrun simctl io "$DEVICE_UDID" screenshot --type=png "$output"
    [[ -s "$output" ]] || fail "截图为空：$output"
    file_path="docs/screenshots/$(basename "$output")"
    ready_marker_name="screenshot.route.$route"
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
      --argjson ready "$ready_payload" \
      --argjson width "$width" \
      --argjson height "$height" '
        {
          file: $file,
          route: $route,
          mode: $mode,
          appearance: $appearance,
          readyMarker: $readyMarker,
          shell: $ready.shell,
          presentation: $ready.presentation,
          selectedTab: $ready.selectedTab,
          tabBarExpected: $ready.tabBarExpected,
          featureMarker: $ready.featureMarker,
          resolvedAppearance: $ready.resolvedAppearance,
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
  --arg bundleID "$BUNDLE_ID" \
  --argjson routeCount "$CARETHREAD_SCREENSHOT_ROUTE_COUNT" \
  --argjson screenshotCount "$CARETHREAD_SCREENSHOT_COUNT" \
  --argjson standardCount "$CARETHREAD_SCREENSHOT_STANDARD_COUNT" \
  --argjson elderCount "$CARETHREAD_SCREENSHOT_ELDER_COUNT" '
    {
      schemaVersion: 2,
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
      expectedCounts: {
        routes: $routeCount,
        screenshots: $screenshotCount,
        standard: $standardCount,
        elder: $elderCount,
        light: $routeCount,
        dark: $routeCount
      },
      screenshots: .
    }
  ' "$MANIFEST_ROWS" >"$MANIFEST_PATH"

jq -e --argjson expected "$CARETHREAD_SCREENSHOT_COUNT" \
  '.screenshots | length == $expected' "$MANIFEST_PATH" >/dev/null ||
  fail "截图 manifest 条目数不是 $CARETHREAD_SCREENSHOT_COUNT"
log "已生成 docs/SCREENSHOT_MANIFEST.json（sourceTreeDirty=${SOURCE_TREE_DIRTY}）"
