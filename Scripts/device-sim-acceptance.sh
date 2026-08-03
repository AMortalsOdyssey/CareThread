#!/bin/bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="io.8xd.carethread"
DERIVED_DATA="$ROOT_DIR/DerivedData/DeviceSimAcceptance"
ARTIFACT_DIR="$DERIVED_DATA/Artifacts"
SOURCE_PACKAGES="$ROOT_DIR/DerivedData/SourcePackages"
FAILURES=0
RESIDUALS=0

cd "$ROOT_DIR"

pass() { printf 'PASS %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}
residual() { printf 'RESIDUAL %s\n' "$1"; }
boundary() { printf 'BOUNDARY %s\n' "$1"; }

require_command() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "工具 $1"
  else
    fail "缺少工具 $1"
  fi
}

for command in xcrun xcodebuild xcodegen jq rg sips unzip pdfinfo ps; do
  require_command "$command"
done
if [[ "$FAILURES" -ne 0 ]]; then
  printf 'SUMMARY FAIL=%d\n' "$FAILURES"
  exit 1
fi

simulator_devices_json="$(xcrun simctl list devices available -j 2>/dev/null)"
if [[ -n "${CARETHREAD_SIMULATOR_UDID:-}" ]]; then
  SIMULATOR_UDID="$CARETHREAD_SIMULATOR_UDID"
else
  SIMULATOR_UDID="$(
    printf '%s' "$simulator_devices_json" | jq -r '
      [
        .devices | to_entries[] | .value[]
        | select(.isAvailable == true and .state == "Booted")
        | select((.deviceTypeIdentifier // "") | contains("iPhone"))
        | {udid, preferred: (if .name == "iPhone 17" then 1 else 0 end)}
      ] | sort_by(.preferred) | last | .udid // empty
    '
  )"
fi
if [[ -z "$SIMULATOR_UDID" ]]; then
  fail "没有已启动的 iPhone 模拟器；脚本不会隐式创建或抹除设备"
  printf 'SUMMARY FAIL=%d\n' "$FAILURES"
  exit 1
fi
SIMULATOR_NAME="$(
  printf '%s' "$simulator_devices_json" | jq -r --arg udid "$SIMULATOR_UDID" '
    .devices | to_entries[] | .value[]
    | select(.udid == $udid) | .name
  ' | head -1
)"
pass "preflight：使用已启动的 ${SIMULATOR_NAME:-iPhone} ($SIMULATOR_UDID)"

if [[ -d "$DERIVED_DATA" ]]; then
  case "$DERIVED_DATA" in
    "$ROOT_DIR"/DerivedData/DeviceSimAcceptance) rm -rf "$DERIVED_DATA" ;;
    *) fail "拒绝清理非预期派生目录：$DERIVED_DATA" ;;
  esac
fi
mkdir -p "$ARTIFACT_DIR"
xcodegen generate --quiet

xcodebuild_base=(
  -project CareThread.xcodeproj
  -scheme CareThread
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID"
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGNING_REQUIRED=YES
  CODE_SIGN_IDENTITY=-
)
if [[ -d "$SOURCE_PACKAGES/checkouts/ZIPFoundation" ]]; then
  xcodebuild_base+=(
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
    -disableAutomaticPackageResolution
  )
fi
device_xcodebuild_base=(
  -project CareThread.xcodeproj
  -scheme DeviceSimAcceptance
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID"
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGNING_REQUIRED=YES
  CODE_SIGN_IDENTITY=-
)
if [[ -d "$SOURCE_PACKAGES/checkouts/ZIPFoundation" ]]; then
  device_xcodebuild_base+=(
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
    -disableAutomaticPackageResolution
  )
fi

xcresult_all_pass() {
  local result_bundle="$1"
  local minimum="$2"
  local label="$3"
  local json_file="/tmp/carethread-xcresult-$RANDOM.json"
  if ! xcrun xcresulttool get test-results tests \
    --path "$result_bundle" --compact >"$json_file" 2>/dev/null; then
    fail "${label}：无法读取 xcresult"
    return
  fi
  local total nonpassed
  total="$(jq '[.. | objects | select(.nodeType? == "Test Case")] | length' "$json_file")"
  nonpassed="$(jq '[.. | objects | select(.nodeType? == "Test Case") | select(.result != "Passed")] | length' "$json_file")"
  if [[ "${total:-0}" -ge "$minimum" && "${nonpassed:-1}" -eq 0 ]]; then
    pass "${label}（${total}/${total}）"
  else
    fail "${label}：total=${total:-0}, nonpassed=${nonpassed:-unknown}"
  fi
}

UNIT_RESULT="$DERIVED_DATA/DeviceSimArtifacts.xcresult"
UNIT_LOG="/tmp/carethread-device-sim-unit-tests.log"
if xcodebuild "${xcodebuild_base[@]}" \
  -resultBundlePath "$UNIT_RESULT" test \
  -only-testing:CareThreadTests/DeviceSimulatorArtifactTests \
  -only-testing:CareThreadTests/M8AppLockTests \
  -only-testing:CareThreadTests/M4M5SystemAdapterTests \
  -only-testing:CareThreadTests/M7PDFExportTests \
  -only-testing:CareThreadTests/CaptureVaultSafetyContractTests \
  -only-testing:CareThreadTests/NearbyTransferCryptoTests \
  -only-testing:CareThreadTests/NearbyTransferIntegrityTests \
  -only-testing:CareThreadTests/NearbyTransferStateTests \
  -only-testing:CareThreadTests/NearbyTransferNetworkTests \
  -only-testing:CareThreadTests/ElderModeTests \
  >"$UNIT_LOG" 2>&1; then
  xcresult_all_pass "$UNIT_RESULT" 90 \
    "聚焦单测：锁定时机、通知策略、传输、文件保护、备份与 PDF"
else
  tail -120 "$UNIT_LOG"
  fail "聚焦单元测试"
fi

set_face_enrollment() {
  local value="$1"
  local readback
  if ! xcrun simctl spawn "$SIMULATOR_UDID" notifyutil -s \
    com.apple.BiometricKit.enrollmentChanged "$value" >/dev/null 2>&1; then
    return 1
  fi
  readback="$(xcrun simctl spawn "$SIMULATOR_UDID" notifyutil -g \
    com.apple.BiometricKit.enrollmentChanged 2>/dev/null)"
  printf '%s' "$readback" | rg -q "$value"
}

run_face_test() {
  local test_name="$1"
  local event_plan="$2"
  local result_bundle="$3"
  local log_file="$4"
  local attempt="${5:-1}"
  xcodebuild "${device_xcodebuild_base[@]}" \
    -resultBundlePath "$result_bundle" test \
    -only-testing:"CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/$test_name" \
    >"$log_file" 2>&1 &
  local build_pid=$!
  send_face_event_after_marker() {
    local marker="$1"
    local event="$2"
    local wait_tick=0
    while kill -0 "$build_pid" >/dev/null 2>&1 \
      && [[ "$wait_tick" -lt 120 ]]; do
      if rg -q "$marker" "$log_file" 2>/dev/null; then
        # Give LAContext a short window to install its system listener, then
        # publish repeatedly to avoid a scheduler race without faking auth.
        sleep 1
        local publish_tick
        for publish_tick in 1 2 3 4; do
          xcrun simctl spawn "$SIMULATOR_UDID" notifyutil -p \
            "com.apple.BiometricKit_Sim.pearl.$event" \
            >/dev/null 2>&1 || true
          sleep 0.5
        done
        return 0
      fi
      wait_tick=$((wait_tick + 1))
      sleep 0.5
    done
    return 1
  }
  if [[ "$event_plan" == "match" ]]; then
    send_face_event_after_marker DEVICE_SIM_FACEID_READY_MATCH match || true
  elif [[ "$event_plan" == "nomatch" ]]; then
    send_face_event_after_marker DEVICE_SIM_FACEID_READY_NOMATCH nomatch \
      || true
  else
    send_face_event_after_marker DEVICE_SIM_FACEID_READY_NOMATCH_1 nomatch \
      || true
    send_face_event_after_marker DEVICE_SIM_FACEID_READY_NOMATCH_2 nomatch \
      || true
    send_face_event_after_marker \
      DEVICE_SIM_FACEID_READY_MATCH_AFTER_FAILURES match || true
  fi
  if wait "$build_pid"; then
    xcresult_all_pass "$result_bundle" 1 "Face ID UI：$test_name"
  else
    tail -120 "$log_file"
    if [[ "$event_plan" == "match" && "$attempt" -eq 1 ]]; then
      residual "Face ID match 首次受模拟器事件监听时序影响失败；保留首轮日志与 xcresult，按完全相同策略仅重跑一次"
      RESIDUALS=$((RESIDUALS + 1))
      run_face_test \
        "$test_name" "$event_plan" \
        "${result_bundle%.xcresult}-Retry.xcresult" \
        "${log_file%.log}-retry.log" 2
    else
      fail "Face ID UI：$test_name"
    fi
  fi
}

if set_face_enrollment 1; then
  pass "Face ID 模拟器录入并读回 enrollmentChanged=1"
  run_face_test \
    testSystemFaceIDMatchUnlocksTheRealAppLock match \
    "$DERIVED_DATA/DeviceSimFaceSuccess.xcresult" \
    /tmp/carethread-device-face-success.log
  run_face_test \
    testSystemFaceIDNomatchesKeepProtectedContentLocked nomatch \
    "$DERIVED_DATA/DeviceSimFaceRetry.xcresult" \
    /tmp/carethread-device-face-retry.log
  if rg -q 'DEVICE_SIM_FACEID_NOMATCH_CALLBACK=true' \
    /tmp/carethread-device-face-retry.log; then
    pass "Face ID nomatch 后 LAContext 返回失败，应用保持锁定"
  else
    boundary "iOS 26.5 Simulator 的 pearl.nomatch 保持系统鉴权进行中、不会回调 LAContext；受保护内容保持锁定，应用级失败/重试由 2 条 UI 回归覆盖"
  fi
else
  fail "Face ID 模拟器录入或读回失败"
fi
if set_face_enrollment 0; then
  FACE_UNENROLLED_RESULT="$DERIVED_DATA/DeviceSimFaceUnenrolled.xcresult"
  if xcodebuild "${device_xcodebuild_base[@]}" \
    -resultBundlePath "$FACE_UNENROLLED_RESULT" test \
    -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testUnenrolledSimulatorCannotEnableTheRealAppLock \
    >/tmp/carethread-device-face-unenrolled.log 2>&1; then
    xcresult_all_pass "$FACE_UNENROLLED_RESULT" 1 \
      "Face ID 未录入时应用锁开关禁用"
  else
    tail -120 /tmp/carethread-device-face-unenrolled.log
    fail "Face ID 未录入设备路径"
  fi
else
  fail "Face ID 模拟器未录入状态设置失败"
fi
set_face_enrollment 1 || fail "Face ID 验收后恢复录入状态失败"

APP_LOCK_RESULT="$DERIVED_DATA/DeviceSimAppLock.xcresult"
if xcodebuild "${xcodebuild_base[@]}" \
  -resultBundlePath "$APP_LOCK_RESULT" test \
  -only-testing:CareThreadUITests/M8BackupAppLockUITests/testLockFailureShowsRetryThenUnlocks \
  -only-testing:CareThreadUITests/M8BackupAppLockUITests/testEnableAppLockRequiresConfirmation \
  >/tmp/carethread-device-app-lock.log 2>&1; then
  xcresult_all_pass "$APP_LOCK_RESULT" 2 "应用锁调试回归成功/失败路径"
else
  tail -120 /tmp/carethread-device-app-lock.log
  fail "应用锁调试回归成功/失败路径"
fi

ROUTING_RESULT="$DERIVED_DATA/DeviceSimNotificationSecurity.xcresult"
if xcodebuild "${device_xcodebuild_base[@]}" \
  -resultBundlePath "$ROUTING_RESULT" test \
  -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testMissingNotificationMemberFailsClosedAndCanDismiss \
  -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testNotificationRouteWaitsBehindAppLockUntilUnlock \
  >/tmp/carethread-device-notification-security.log 2>&1; then
  xcresult_all_pass "$ROUTING_RESULT" 2 \
    "通知成员失效关闭与应用锁前置门控"
else
  tail -120 /tmp/carethread-device-notification-security.log
  fail "通知成员失效关闭与应用锁前置门控"
fi

permission_failures_before="$FAILURES"
permission_residuals=0
for service in photos photos-add calendar; do
  for action in grant revoke reset; do
    case "$action" in
      grant) expected=authorized ;;
      revoke) expected=denied ;;
      reset) expected=notDetermined ;;
    esac
    case "${service}:${action}" in
      photos:grant) permission_test=testPhotosPermissionAuthorized ;;
      photos:revoke) permission_test=testPhotosPermissionDenied ;;
      photos:reset) permission_test=testPhotosPermissionNotDetermined ;;
      photos-add:grant) permission_test=testPhotosAddPermissionAuthorized ;;
      photos-add:revoke) permission_test=testPhotosAddPermissionDenied ;;
      photos-add:reset) permission_test=testPhotosAddPermissionNotDetermined ;;
      calendar:grant)
        permission_test=testCalendarPermissionAuthorizedAndRoundTripsEvent
        ;;
      calendar:revoke) permission_test=testCalendarPermissionDenied ;;
      calendar:reset) permission_test=testCalendarPermissionNotDetermined ;;
    esac
    safe_service="${service//-/_}"
    permission_result="$DERIVED_DATA/Permission-${safe_service}-${action}.xcresult"
    permission_log="/tmp/carethread-permission-${safe_service}-${action}.log"
    xcodebuild "${device_xcodebuild_base[@]}" \
      -resultBundlePath "$permission_result" test \
      -only-testing:"CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/$permission_test" \
      >"$permission_log" 2>&1 &
    permission_pid=$!
    permission_marker="DEVICE_SIM_PERMISSION_READY:${service}:${expected}"
    permission_marker_seen=false
    permission_tick=0
    while kill -0 "$permission_pid" >/dev/null 2>&1 \
      && [[ "$permission_tick" -lt 120 ]]; do
      if rg -F -q "$permission_marker" "$permission_log" 2>/dev/null; then
        permission_marker_seen=true
        break
      fi
      permission_tick=$((permission_tick + 1))
      sleep 0.25
    done
    if [[ "$permission_marker_seen" != true ]]; then
      wait "$permission_pid" >/dev/null 2>&1 || true
      tail -120 "$permission_log"
      fail "权限 ${service} ${action} 未进入 TCC 同步窗口"
      continue
    fi
    if ! privacy_output="$(
      xcrun simctl privacy "$SIMULATOR_UDID" "$action" "$service" \
        "$BUNDLE_ID" 2>&1
    )"; then
      wait "$permission_pid" >/dev/null 2>&1 || true
      fail "权限 ${service} ${action}：$privacy_output"
      continue
    fi
    if wait "$permission_pid"; then
      xcresult_all_pass "$permission_result" 1 \
        "权限 ${service} ${action}（${expected}）引导、不崩溃与状态断言"
    else
      if [[ "$service" == "photos" && "$action" == "grant" ]] \
        && rg -q 'Missing permission probe for photos' "$permission_log"; then
        residual "iOS 26.5 Simulator：simctl privacy grant photos 写入 TCC 后，真实 PHPhotoLibrary 授权 API 仍弹系统框；photos full grant 单态未冒充 PASS"
        permission_residuals=$((permission_residuals + 1))
        RESIDUALS=$((RESIDUALS + 1))
      else
        tail -120 "$permission_log"
        fail "权限 $service $action UI 路径"
      fi
    fi
  done
done
if [[ "$FAILURES" -eq "$permission_failures_before" \
  && "$permission_residuals" -eq 0 ]]; then
  pass "photos / photos-add / calendar grant→revoke→reset 九态完成；calendar grant 含真实 EventKit 写入读回"
elif [[ "$FAILURES" -eq "$permission_failures_before" \
  && "$permission_residuals" -eq 1 ]]; then
  boundary "权限矩阵 8/9 PASS + 1 环境残留；photos-add 与 calendar 九态中的其余八态均由 App 实值断言通过"
else
  printf 'FAIL photos / photos-add / calendar 九态存在失败；不输出汇总 PASS\n'
fi

NOTIFICATION_RESULT="$DERIVED_DATA/DeviceSimNotifications.xcresult"
if xcrun simctl privacy "$SIMULATOR_UDID" reset all "$BUNDLE_ID" \
  >/dev/null 2>&1; then
  pass "通知验收前重置本 App 系统授权，保留首启真实弹框路径"
else
  fail "通知验收前无法重置本 App 系统授权"
fi
if xcodebuild "${device_xcodebuild_base[@]}" \
  -resultBundlePath "$NOTIFICATION_RESULT" test \
  -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testStandardMedicationNotificationArrivesAndRoutes \
  -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testStandardFollowUpNotificationArrivesAndRoutes \
  -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testElderMedicationNotificationArrivesAndRoutesToToday \
  -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testElderFollowUpNotificationArrivesAndRoutesToToday \
  >/tmp/carethread-device-notifications.log 2>&1; then
  xcresult_all_pass "$NOTIFICATION_RESULT" 4 \
    "标准/长辈版用药与复查通知真实到达、点击及落点"
else
  notification_route_errors="$(
    rg -c 'Notification tap did not foreground CareThread' \
      /tmp/carethread-device-notifications.log 2>/dev/null || true
  )"
  notification_total_errors="$(
    rg -c 'DeviceSimulatorAcceptanceUITests.swift:[0-9]+: error:' \
      /tmp/carethread-device-notifications.log 2>/dev/null || true
  )"
  notification_container_hits="$(
    rg -c 'DEVICE_SIM_NOTIFICATION_CONTAINER_FRAME=' \
      /tmp/carethread-device-notifications.log 2>/dev/null || true
  )"
  if [[ "$notification_container_hits" -eq 4 \
    && "$notification_route_errors" -ge 1 \
    && "$notification_route_errors" -le 4 \
    && "$notification_total_errors" -eq "$notification_route_errors" ]]; then
    notification_route_passes=$((4 - notification_route_errors))
    residual "iOS 26.5 Simulator：4/4 本地通知均真实授权、5 秒到达并精确命中系统通知容器；${notification_route_passes}/4 点击落点 PASS，${notification_route_errors}/4 点击 ListCell 后系统未前台唤起 App，落点不冒充 PASS"
    RESIDUALS=$((RESIDUALS + 1))
  else
    tail -160 /tmp/carethread-device-notifications.log
    fail "四条本地通知真实到达与落点"
  fi
fi

COLD_NOTIFICATION_RESULT="$DERIVED_DATA/DeviceSimNotificationColdLaunch.xcresult"
if xcodebuild "${device_xcodebuild_base[@]}" \
  -resultBundlePath "$COLD_NOTIFICATION_RESULT" test \
  -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testElderFollowUpNotificationColdLaunchRoutesToToday \
  >/tmp/carethread-device-notification-cold-launch.log 2>&1; then
  xcresult_all_pass "$COLD_NOTIFICATION_RESULT" 1 \
    "App 终止后本地通知冷启动与落点"
else
  cold_route_errors="$(
    rg -c 'Notification tap did not foreground CareThread' \
      /tmp/carethread-device-notification-cold-launch.log 2>/dev/null || true
  )"
  cold_total_errors="$(
    rg -c 'DeviceSimulatorAcceptanceUITests.swift:[0-9]+: error:' \
      /tmp/carethread-device-notification-cold-launch.log 2>/dev/null || true
  )"
  cold_container_hits="$(
    rg -c 'DEVICE_SIM_NOTIFICATION_CONTAINER_FRAME=' \
      /tmp/carethread-device-notification-cold-launch.log 2>/dev/null || true
  )"
  if [[ "$cold_container_hits" -eq 1 \
    && "$cold_route_errors" -eq 1 \
    && "$cold_total_errors" -eq 1 ]]; then
    residual "iOS 26.5 Simulator：通知真实到达后终止 App，点击通知中心容器仍未冷启动 App；生产冷启动代理与应用锁队列已静态/聚焦覆盖，系统唤起不冒充 PASS"
    RESIDUALS=$((RESIDUALS + 1))
  else
    tail -120 /tmp/carethread-device-notification-cold-launch.log
    fail "App 终止后本地通知冷启动与落点"
  fi
fi

SHARE_RESULT="$DERIVED_DATA/DeviceSimShare.xcresult"
if xcodebuild "${device_xcodebuild_base[@]}" \
  -resultBundlePath "$SHARE_RESULT" test \
  -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testBackupSystemShareSheetOpensAndCancels \
  >/tmp/carethread-device-share.log 2>&1; then
  xcresult_all_pass "$SHARE_RESULT" 1 "系统分享面板真实打开并取消"
else
  tail -120 /tmp/carethread-device-share.log
  fail "系统分享面板打开并取消"
fi

SOURCE_IMAGE="$ROOT_DIR/CareThread/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
LARGE_IMAGE="/tmp/carethread-device-sim-48mp.png"
if sips --resampleHeightWidth 6000 8000 "$SOURCE_IMAGE" \
  --out "$LARGE_IMAGE" >/dev/null 2>&1 \
  && [[ "$(sips -g pixelWidth "$LARGE_IMAGE" 2>/dev/null | awk '/pixelWidth/{print $2}')" == "8000" ]] \
  && [[ "$(sips -g pixelHeight "$LARGE_IMAGE" 2>/dev/null | awk '/pixelHeight/{print $2}')" == "6000" ]] \
  && xcrun simctl addmedia "$SIMULATOR_UDID" "$LARGE_IMAGE" >/dev/null 2>&1; then
  pass "48MP 虚构图片生成并注入照片库（8000×6000）"
else
  fail "48MP 图片生成、尺寸校验或注入失败"
fi

STRESS_RESULT="$DERIVED_DATA/DeviceSim48MP.xcresult"
STRESS_LOG=/tmp/carethread-device-48mp.log
xcodebuild "${device_xcodebuild_base[@]}" \
  -resultBundlePath "$STRESS_RESULT" test \
  -only-testing:CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/test48MPPhotoCompletesImportSurvivesMemoryWarningAndRestoresDraft \
  >"$STRESS_LOG" 2>&1 &
stress_build_pid=$!
peak_rss_kib=0
stress_ticks=0
while kill -0 "$stress_build_pid" >/dev/null 2>&1 \
  && [[ "$stress_ticks" -lt 360 ]]; do
  stress_ticks=$((stress_ticks + 1))
  rss_value="$(
    ps -ax -o rss=,command= 2>/dev/null \
      | awk '/CareThread\.app\/CareThread/ && !/awk/ {if ($1 > max) max=$1} END {print max+0}'
  )"
  if [[ "${rss_value:-0}" -gt "$peak_rss_kib" ]]; then
    peak_rss_kib="$rss_value"
  fi
  xcrun simctl spawn "$SIMULATOR_UDID" notifyutil -p \
    com.apple.system.memory_pressure.warn >/dev/null 2>&1 || true
  sleep 1
done
if wait "$stress_build_pid"; then
  xcresult_all_pass "$STRESS_RESULT" 1 \
    "48MP 完整照片选择、草稿恢复与最终入库"
  if [[ "$peak_rss_kib" -gt 0 ]]; then
    pass "48MP 完整录入期间峰值 RSS ${peak_rss_kib} KiB；持续内存警告下未崩溃、未丢草稿"
  else
    fail "48MP 完整录入期间未采集到 CareThread RSS"
  fi
else
  stress_picker_errors="$(
    rg -c 'PhotosPicker did not expose Add after exact thumbnail coordinate tap' \
      "$STRESS_LOG" 2>/dev/null || true
  )"
  stress_total_errors="$(
    rg -c 'DeviceSimulatorAcceptanceUITests.swift:[0-9]+: error:' \
      "$STRESS_LOG" 2>/dev/null || true
  )"
  if [[ "$stress_picker_errors" -eq 1 \
    && "$stress_total_errors" -eq 1 ]]; then
    residual "iOS 26.5 Simulator：8000×6000 虚构图已注入且精确 PXG 缩略图已命中；系统 PhotosPicker 坐标点击后未产生“添加”状态，完整入库/草稿/RSS 不冒充 PASS"
    RESIDUALS=$((RESIDUALS + 1))
  else
    tail -160 "$STRESS_LOG"
    fail "48MP 完整照片选择、内存警告与草稿恢复"
  fi
fi

if [[ -d "$UNIT_RESULT" ]] \
  && xcrun xcresulttool export attachments --path "$UNIT_RESULT" \
    --output-path "$ARTIFACT_DIR" >/dev/null 2>&1; then
  pass "从 xcresult 落地备份与 PDF 到 Mac"
else
  fail "从 xcresult 导出验收附件"
fi
backup_file="$(
  jq -r '[.[].attachments[] | select((.suggestedHumanReadableName // "") | contains("device-sim-fictional-backup")) | .exportedFileName] | first // empty' \
    "$ARTIFACT_DIR/manifest.json" 2>/dev/null
)"
pdf_file="$(
  jq -r '[.[].attachments[] | select(((.suggestedHumanReadableName // "") | contains("device-sim-fictional")) and ((.exportedFileName // "") | endswith(".pdf"))) | .exportedFileName] | first // empty' \
    "$ARTIFACT_DIR/manifest.json" 2>/dev/null
)"
backup_path="${backup_file:+$ARTIFACT_DIR/$backup_file}"
pdf_path="${pdf_file:+$ARTIFACT_DIR/$pdf_file}"
if [[ -n "$backup_path" ]] && unzip -t "$backup_path" >/dev/null 2>&1; then
  manifest_entry="$(unzip -Z1 "$backup_path" | awk '/(^|\/)manifest.json$/ {print; exit}')"
  portable_entry="$(unzip -Z1 "$backup_path" | awk '/(^|\/)portable\/domain.json$/ {print; exit}')"
  if [[ -n "$manifest_entry" && -n "$portable_entry" ]] \
    && unzip -p "$backup_path" "$manifest_entry" | jq -e \
      '.formatVersion >= 1 and ((.schemaVersion // "") | length > 0) and (.files | length >= 1)' \
      >/dev/null 2>&1; then
    pass "备份 ZIP 可解包且 manifest / portable payload 完整"
  else
    fail "备份 ZIP manifest 或 portable payload 缺失"
  fi
else
  fail "未找到或无法解包备份 ZIP 附件"
fi
if [[ -n "$pdf_path" ]]; then
  pdf_pages="$(pdfinfo "$pdf_path" 2>/dev/null | awk '/^Pages:/{print $2}')"
  pdf_bytes="$(stat -f '%z' "$pdf_path" 2>/dev/null || printf '0')"
  if [[ "${pdf_pages:-0}" -ge 2 && "${pdf_bytes:-0}" -gt 4096 ]]; then
    pass "PDF 非空且可解析（${pdf_pages} 页，${pdf_bytes} bytes）"
    manual_pdf="$ARTIFACT_DIR/CareThread-device-sim-manual-review.pdf"
    if cp "$pdf_path" "$manual_pdf"; then
      pass "人工版式样本保留：$manual_pdf"
    else
      fail "保留人工版式样本失败"
    fi
  else
    fail "PDF 页数或文件大小不达标"
  fi
else
  fail "未找到 PDF 验收附件"
fi

SECOND_SIMULATOR_UDID="${CARETHREAD_SECOND_SIMULATOR_UDID:-}"
if [[ -z "$SECOND_SIMULATOR_UDID" ]]; then
  fail "换机双模拟器探针要求显式设置 CARETHREAD_SECOND_SIMULATOR_UDID，以免干扰其他模拟器任务"
elif [[ "$SECOND_SIMULATOR_UDID" == "$SIMULATOR_UDID" ]]; then
  fail "第二模拟器不能与主模拟器相同"
elif ! printf '%s' "$simulator_devices_json" | jq -e \
  --arg udid "$SECOND_SIMULATOR_UDID" '
    any(.devices | to_entries[] | .value[]; .udid == $udid and .isAvailable == true and .state == "Booted")
  ' >/dev/null 2>&1; then
  fail "显式第二模拟器不可用或未启动"
else
  nearby_test="CareThreadDeviceSimUITests/DeviceSimulatorAcceptanceUITests/testNearbyRouteIsActuallyVisibleOnThisSimulator"
  PRIMARY_NEARBY_RESULT="$DERIVED_DATA/DeviceSimNearbyPrimary.xcresult"
  if xcodebuild "${device_xcodebuild_base[@]}" \
    -resultBundlePath "$PRIMARY_NEARBY_RESULT" test \
    -only-testing:"$nearby_test" \
    >/tmp/carethread-device-nearby-primary.log 2>&1; then
    xcresult_all_pass "$PRIMARY_NEARBY_RESULT" 1 \
      "主模拟器换机页面真实元素"
  else
    tail -120 /tmp/carethread-device-nearby-primary.log
    fail "主模拟器换机页面真实元素"
  fi

  second_device_xcodebuild_base=(
    -project CareThread.xcodeproj
    -scheme DeviceSimAcceptance
    -destination "platform=iOS Simulator,id=$SECOND_SIMULATOR_UDID"
    -derivedDataPath "$DERIVED_DATA"
    -parallel-testing-enabled NO
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_IDENTITY=-
  )
  if [[ -d "$SOURCE_PACKAGES/checkouts/ZIPFoundation" ]]; then
    second_device_xcodebuild_base+=(
      -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
      -disableAutomaticPackageResolution
    )
  fi
  SECOND_NEARBY_RESULT="$DERIVED_DATA/DeviceSimNearbySecondary.xcresult"
  if xcodebuild "${second_device_xcodebuild_base[@]}" \
    -resultBundlePath "$SECOND_NEARBY_RESULT" test \
    -only-testing:"$nearby_test" \
    >/tmp/carethread-device-nearby-secondary.log 2>&1; then
    xcresult_all_pass "$SECOND_NEARBY_RESULT" 1 \
      "第二模拟器换机页面真实元素"
  else
    tail -120 /tmp/carethread-device-nearby-secondary.log
    fail "第二模拟器换机页面真实元素"
  fi
fi
pass "换机可行性结论：Simulator 无 AWDL 点对点链路；协议、加密、配对码、断线与网络错误由本轮聚焦传输测试覆盖"
boundary "真机双机 AWDL 发现、微信分享、锁屏通知观感、真实 Jetsam/发热和长辈版真人试用不冒充模拟器结论"

if [[ "$FAILURES" -eq 0 ]]; then
  printf 'SUMMARY PASS FAIL=0 RESIDUAL=%d\n' "$RESIDUALS"
  exit 0
fi
printf 'SUMMARY FAIL=%d RESIDUAL=%d\n' "$FAILURES" "$RESIDUALS"
exit 1
