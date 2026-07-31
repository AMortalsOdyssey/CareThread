#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf '[verify] ERROR: %s\n' "$1" >&2
  exit 1
}

runtime_diagnostics() {
  printf '[verify] 当前 Xcode：\n' >&2
  xcodebuild -version >&2 || true
  printf '[verify] 当前已注册的 iOS Simulator 运行时：\n' >&2
  xcrun simctl list runtimes | sed -n '/iOS/p' >&2 || true
  printf '[verify] 当前可用的 iPhone 模拟器：\n' >&2
  xcrun simctl list devices available | sed -n '/iPhone/p' >&2 || true
  printf '%s\n' \
    '[verify] 处理建议：先安装 Xcode 的 iOS 平台组件（xcodebuild -downloadPlatform iOS），' \
    '[verify] 再重启 Xcode/CoreSimulator；不要求必须存在旧版 iOS 18.6 运行时。' >&2
}

for required in xcodegen jq xcrun xcodebuild; do
  command -v "$required" >/dev/null ||
    fail "缺少工具 $required。请先完成 README“环境要求”。"
done

simulator_devices_json() {
  if [[ -n "${CARETHREAD_SIMULATOR_DEVICES_JSON:-}" ]]; then
    jq -c . "$CARETHREAD_SIMULATOR_DEVICES_JSON"
  else
    xcrun simctl list devices available -j
  fi
}

select_simulator() {
  if [[ -n "${CARETHREAD_SIMULATOR_UDID:-}" ]]; then
    printf '%s\t%s\t%s\n' \
      "$CARETHREAD_SIMULATOR_UDID" \
      "环境变量指定设备" \
      "环境变量指定运行时"
    return
  fi

  simulator_devices_json | jq -r '
    [
      .devices
      | to_entries[]
      | .key as $runtime
      | .value[]
      | select(.isAvailable == true)
      | select(
          (.deviceTypeIdentifier // "") | contains("iPhone")
        )
      | {
          udid,
          name,
          runtime: $runtime,
          preferred: (if .name == "iPhone 16" then 1 else 0 end)
        }
    ] as $all
    | (
        if any($all[]; .preferred == 1)
        then [$all[] | select(.preferred == 1)]
        else $all
        end
      )
    | sort_by(.runtime)
    | last
    | select(. != null)
    | [.udid, .name, .runtime]
    | @tsv
  '
}

if ! SIMULATOR_ROW="$(select_simulator)" || [[ -z "$SIMULATOR_ROW" ]]; then
  runtime_diagnostics
  fail "没有可用的 iPhone 模拟器，无法开始构建测试。"
fi
IFS=$'\t' read -r SIMULATOR_UDID SIMULATOR_NAME SIMULATOR_RUNTIME \
  <<<"$SIMULATOR_ROW"
printf '[verify] 使用 %s（%s，%s）\n' \
  "$SIMULATOR_NAME" "$SIMULATOR_RUNTIME" "$SIMULATOR_UDID"

# 无 iOS 18.6 的诊断测法：
#   printf '{"devices":{}}' >/tmp/carethread-empty-devices.json
#   CARETHREAD_SIMULATOR_DEVICES_JSON=/tmp/carethread-empty-devices.json \
#     Scripts/verify.sh --diagnose-runtime-only
# 应输出“没有可用的 iPhone 模拟器”及平台组件安装/重启建议。
if [[ "${1:-}" == "--diagnose-runtime-only" ]]; then
  printf '[verify] 运行时探测通过；未执行构建测试。\n'
  exit 0
fi

xcodegen generate --quiet
rm -rf "$ROOT_DIR/DerivedData"

xcodebuild \
  -project CareThread.xcodeproj \
  -scheme CareThread \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath "$ROOT_DIR/DerivedData" \
  -resultBundlePath "$ROOT_DIR/DerivedData/Verify.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  build test
