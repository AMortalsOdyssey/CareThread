#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${1:-$ROOT_DIR/docs/SCREENSHOT_MANIFEST.json}"
EXPECTED_DEVICE="iPhone 16"
EXPECTED_OS="18.6"
EXPECTED_BUNDLE="me.multiego.carethread"

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
  --arg os "$EXPECTED_OS" \
  --arg bundle "$EXPECTED_BUNDLE" '
    .schemaVersion == 1
    and .generator == "Scripts/screenshots.sh"
    and .deviceName == $device
    and .osVersion == $os
    and (.runtimeIdentifier | type == "string" and contains("iOS-18-6"))
    and .bundleID == $bundle
    and .configuration == "Debug"
    and .language == "zh-Hans"
    and .locale == "zh_CN"
    and .sourceTreeDirty == false
    and (.generatedAtUTC | type == "string" and length > 0)
    and (.sourceCommit | type == "string" and test("^[0-9a-f]{40}$"))
    and (.sourceFingerprint | type == "string" and test("^[0-9a-f]{64}$"))
    and (.screenshotScriptSHA256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.screenshots | type == "array" and length == 36)
  ' "$MANIFEST" >/dev/null ||
  fail "元数据、干净源码状态或截图数量不符合终验口径"

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
[[ "$unique_files" == "36" ]] || fail "截图路径不唯一"
[[ "$unique_hashes" == "36" ]] || fail "截图内容哈希不唯一"

for entry in "${routes[@]}"; do
  IFS='|' read -r number slug route mode <<<"$entry"
  for appearance in light dark; do
    file="docs/screenshots/$number-$slug-$appearance.png"
    marker="screenshot.route.$route"
    [[ "$route" == "lock" ]] && marker="process-stable"
    count="$(jq \
      --arg file "$file" \
      --arg route "$route" \
      --arg mode "$mode" \
      --arg appearance "$appearance" \
      --arg marker "$marker" '
        [
          .screenshots[]
          | select(
              .file == $file
              and .route == $route
              and .mode == $mode
              and .appearance == $appearance
              and .readyMarker == $marker
            )
        ] | length
      ' "$MANIFEST")"
    [[ "$count" == "1" ]] || fail "$file 路由元数据不唯一或不匹配"
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

printf '[screenshot-manifest] PASS 36 张截图的提交、设备、路由、外观、尺寸与 SHA-256 均可复查\n'
