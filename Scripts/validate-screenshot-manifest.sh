#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${1:-$ROOT_DIR/docs/SCREENSHOT_MANIFEST.json}"
EXPECTED_DEVICE="iPhone 16"
EXPECTED_OS_VERSION="26.5"
EXPECTED_BUNDLE="me.multiego.carethread"
source "$ROOT_DIR/Scripts/screenshot-routes.sh"
routes=("${CARETHREAD_SCREENSHOT_ROUTES[@]}")

fail() {
  printf '[screenshot-manifest] FAIL %s\n' "$1" >&2
  exit 1
}

cd "$ROOT_DIR"
command -v jq >/dev/null || fail "缺少 jq"
[[ -s "$MANIFEST" ]] || fail "缺少清单 $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "清单不是有效 JSON"

jq -e \
  --arg device "$EXPECTED_DEVICE" \
  --arg osVersion "$EXPECTED_OS_VERSION" \
  --arg bundle "$EXPECTED_BUNDLE" \
  --argjson routes "$CARETHREAD_SCREENSHOT_ROUTE_COUNT" \
  --argjson screenshots "$CARETHREAD_SCREENSHOT_COUNT" \
  --argjson standard "$CARETHREAD_SCREENSHOT_STANDARD_COUNT" \
  --argjson elder "$CARETHREAD_SCREENSHOT_ELDER_COUNT" '
    .schemaVersion == 2
    and .generator == "Scripts/screenshots.sh"
    and .deviceName == $device
    and .osVersion == $osVersion
    and (
      .runtimeIdentifier
      == (
        "com.apple.CoreSimulator.SimRuntime.iOS-"
        + (.osVersion | gsub("[.]"; "-"))
      )
    )
    and .bundleID == $bundle
    and .configuration == "Debug"
    and .language == "zh-Hans"
    and .locale == "zh_CN"
    and .sourceTreeDirty == false
    and (.generatedAtUTC | type == "string" and length > 0)
    and (.sourceCommit | type == "string" and test("^[0-9a-f]{40}$"))
    and (.sourceFingerprint | type == "string" and test("^[0-9a-f]{64}$"))
    and (.screenshotScriptSHA256 | type == "string" and test("^[0-9a-f]{64}$"))
    and .expectedCounts == {
      routes: $routes,
      screenshots: $screenshots,
      standard: $standard,
      elder: $elder,
      light: $routes,
      dark: $routes
    }
    and (.screenshots | type == "array" and length == $screenshots)
  ' "$MANIFEST" >/dev/null ||
  fail "元数据、动态 runtime、干净源码状态或截图数量不符合终验口径"

if [[ -n "$(
  git status --porcelain --untracked-files=all -- \
    CareThread CareThreadTests CareThreadUITests Scripts project.yml
)" ]]; then
  fail "当前源码树非干净状态，不能验证截图来源"
fi

source_commit="$(jq -r '.sourceCommit' "$MANIFEST")"
git cat-file -e "$source_commit^{commit}" 2>/dev/null ||
  fail "sourceCommit 不是本仓库提交"
git merge-base --is-ancestor "$source_commit" HEAD ||
  fail "sourceCommit 不是当前 HEAD 的祖先"

expected_fingerprint="$(Scripts/source-fingerprint.sh)"
manifest_fingerprint="$(jq -r '.sourceFingerprint' "$MANIFEST")"
[[ "$manifest_fingerprint" == "$expected_fingerprint" ]] ||
  fail "清单源码指纹与当前源码不一致"

expected_script_hash="$(shasum -a 256 Scripts/screenshots.sh | awk '{print $1}')"
manifest_script_hash="$(jq -r '.screenshotScriptSHA256' "$MANIFEST")"
[[ "$manifest_script_hash" == "$expected_script_hash" ]] ||
  fail "截图脚本哈希不一致"

unique_files="$(jq '[.screenshots[].file] | unique | length' "$MANIFEST")"
unique_hashes="$(jq '[.screenshots[].sha256] | unique | length' "$MANIFEST")"
[[ "$unique_files" == "$CARETHREAD_SCREENSHOT_COUNT" ]] ||
  fail "截图路径不唯一"
[[ "$unique_hashes" == "$CARETHREAD_SCREENSHOT_COUNT" ]] ||
  fail "截图内容哈希不唯一"

actual_standard="$(jq '[.screenshots[] | select(.mode == "standard")] | length' "$MANIFEST")"
actual_elder="$(jq '[.screenshots[] | select(.mode == "elder")] | length' "$MANIFEST")"
actual_light="$(jq '[.screenshots[] | select(.appearance == "light")] | length' "$MANIFEST")"
actual_dark="$(jq '[.screenshots[] | select(.appearance == "dark")] | length' "$MANIFEST")"
[[ "$actual_standard" == "$CARETHREAD_SCREENSHOT_STANDARD_COUNT" ]] ||
  fail "标准版清单数量不正确"
[[ "$actual_elder" == "$CARETHREAD_SCREENSHOT_ELDER_COUNT" ]] ||
  fail "大字版清单数量不正确"
[[ "$actual_light" == "$CARETHREAD_SCREENSHOT_ROUTE_COUNT" ]] ||
  fail "浅色清单数量不正确"
[[ "$actual_dark" == "$CARETHREAD_SCREENSHOT_ROUTE_COUNT" ]] ||
  fail "深色清单数量不正确"

for entry in "${routes[@]}"; do
  IFS='|' read -r number slug route mode shell presentation selected_tab \
    tab_bar_expected feature_marker <<<"$entry"
  for appearance in light dark; do
    file="docs/screenshots/$number-$slug-$appearance.png"
    marker="screenshot.route.$route"
    count="$(jq \
      --arg file "$file" \
      --arg route "$route" \
      --arg mode "$mode" \
      --arg appearance "$appearance" \
      --arg marker "$marker" \
      --arg shell "$shell" \
      --arg presentation "$presentation" \
      --argjson selectedTab "${selected_tab:-null}" \
      --argjson tabBarExpected "$tab_bar_expected" \
      --arg featureMarker "$feature_marker" '
        [
          .screenshots[]
          | select(
              .file == $file
              and .route == $route
              and .mode == $mode
              and .appearance == $appearance
              and .readyMarker == $marker
              and .shell == $shell
              and .presentation == $presentation
              and .selectedTab == $selectedTab
              and .tabBarExpected == $tabBarExpected
              and .featureMarker == $featureMarker
              and .resolvedAppearance == $appearance
            )
        ] | length
      ' "$MANIFEST")"
    [[ "$count" == "1" ]] ||
      fail "$file 的生产导航壳、路由、外观或目标标识不匹配"
    [[ -s "$file" ]] || fail "截图缺失或为空：$file"

    actual_hash="$(shasum -a 256 "$file" | awk '{print $1}')"
    manifest_hash="$(jq -r --arg file "$file" \
      '.screenshots[] | select(.file == $file) | .sha256' "$MANIFEST")"
    [[ "$actual_hash" == "$manifest_hash" ]] ||
      fail "$file SHA-256 不一致"

    actual_width="$(sips -g pixelWidth "$file" 2>/dev/null |
      awk '/pixelWidth/{print $2}')"
    actual_height="$(sips -g pixelHeight "$file" 2>/dev/null |
      awk '/pixelHeight/{print $2}')"
    manifest_width="$(jq -r --arg file "$file" \
      '.screenshots[] | select(.file == $file) | .width' "$MANIFEST")"
    manifest_height="$(jq -r --arg file "$file" \
      '.screenshots[] | select(.file == $file) | .height' "$MANIFEST")"
    [[ "$actual_width" == "$manifest_width" &&
      "$actual_height" == "$manifest_height" ]] ||
      fail "$file 尺寸元数据不一致"
  done
done

printf '[screenshot-manifest] PASS %s 张截图均绑定生产 Root/Tab 导航壳、动态 runtime、外观、尺寸与 SHA-256\n' \
  "$CARETHREAD_SCREENSHOT_COUNT"
