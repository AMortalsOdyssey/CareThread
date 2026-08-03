#!/bin/bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESULT_BUNDLE="$ROOT_DIR/DerivedData/Verify.xcresult"
TEST_TREE="/tmp/carethread-xcresult-tests-raw.json"
TEST_CASES="/tmp/carethread-xcresult-test-cases.json"
LEGACY_ROOT="/tmp/carethread-xcresult-root.json"
VERIFY_LOG="/tmp/carethread-verify.log"
FAILURES=0

cd "$ROOT_DIR"

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

require_command() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "工具 $1"
  else
    fail "缺少工具 $1"
  fi
}

test_case_passed() {
  local pattern="$1"
  jq -e --arg pattern "$pattern" '
    [
      .[]
      | select(.result == "Passed")
      | select(
          (((.nodeIdentifier // "") + " " + (.name // "")) | test($pattern))
        )
    ] | length > 0
  ' "$TEST_CASES" >/dev/null 2>&1
}

plist_equals() {
  local key="$1"
  local expected="$2"
  local actual
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" \
    CareThread/Resources/Info.plist 2>/dev/null || true)
  [[ "$actual" == "$expected" ]]
}

require_command jq
require_command rg
require_command xcrun
require_command sips
require_command git
require_command shasum

legal_source_integrity=1
check_sha256() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Legal source drift: %s\n' "$path"
    legal_source_integrity=0
  fi
}

# The App resource entries point directly at docs/legal, so there is no hidden
# fourth copy. The paired source/site hashes make any unilateral edit fail until
# all legal surfaces are deliberately reviewed and the contract is updated.
check_sha256 docs/legal/PRIVACY_POLICY.md \
  003a5bbbb35a617ce0f46253430418b231bfe8edbc7b849f86168b7a8c7f4c5f
check_sha256 docs/legal/TERMS_OF_SERVICE.md \
  e564992155a823371725ad37ad1eb08ac09f38a71caf99c27f2b5f4e13175bcf
check_sha256 website/privacy/index.html \
  1a65c4f2afc064a9f23af01009f205f000fccab4611d94ca4b132a718a71eeab
check_sha256 website/terms/index.html \
  79460909b2994c9bd9d16a7fa168e143163a529fac2d3f7d3ee7340ec693d841
if [[ "$legal_source_integrity" -eq 1 ]] &&
  rg -q 'path: docs/legal/PRIVACY_POLICY\.md' project.yml &&
  rg -q 'path: docs/legal/TERMS_OF_SERVICE\.md' project.yml &&
  rg -q '最后更新：2026-08-03' docs/legal/PRIVACY_POLICY.md &&
  rg -q '最后更新：2026-08-03' docs/legal/TERMS_OF_SERVICE.md &&
  rg -q '最后更新：2026-08-03' website/privacy/index.html &&
  rg -q '最后更新：2026-08-03' website/terms/index.html &&
  rg -q 'currentTermsVersion = "2026-08-03"' \
    CareThread/Core/Legal/LegalDocuments.swift; then
  pass "协议源、官网副本与 App 本地资源分别锁定"
else
  fail "协议源、官网副本与 App 本地资源分别锁定"
fi

all_files_contain() {
  local pattern="$1"
  shift
  local path
  for path in "$@"; do
    rg -q -- "$pattern" "$path" || return 1
  done
}

# App resources are the Markdown source itself. The website repeats the same
# release-critical backup, recovery and contact commitments, while the two
# privacy surfaces also lock the production PhotosPicker access boundary.
legal_surfaces=(
  docs/legal/PRIVACY_POLICY.md
  docs/legal/TERMS_OF_SERVICE.md
  website/privacy/index.html
  website/terms/index.html
)
privacy_surfaces=(
  docs/legal/PRIVACY_POLICY.md
  website/privacy/index.html
)
if all_files_contain '导出存档默认不加密' "${legal_surfaces[@]}" &&
  all_files_contain '至少 12 位的口令' "${legal_surfaces[@]}" &&
  all_files_contain '口令丢失即无法解开该文件' "${legal_surfaces[@]}" &&
  all_files_contain 'founder@8xd\.io' "${legal_surfaces[@]}" &&
  all_files_contain '只读取你明确选择的项目，不请求整个照片库权限' \
    "${privacy_surfaces[@]}" &&
  all_files_contain '通过系统照片选择器读取你明确选中的报告截图' \
    project.yml CareThread/Resources/Info.plist; then
  pass "协议 Markdown、官网与 App 关键事实同源"
else
  fail "协议 Markdown、官网与 App 关键事实同源"
fi

product_namespace_files=(
  project.yml
  Scripts/device-sim-acceptance.sh
  Scripts/screenshots.sh
  Scripts/validate-screenshot-manifest.sh
  docs/SCREENSHOT_MANIFEST.json
  CareThread/Core/Services/AppLog.swift
  CareThread/Core/Services/Backup/BackupModels.swift
  CareThread/Core/Services/NearbyTransfer/NearbyNetworkTransport.swift
)
if all_files_contain 'io\.8xd\.carethread' "${product_namespace_files[@]}"; then
  if unexpected_namespace_hits="$(
    rg -n '\.carethread' "${product_namespace_files[@]}" |
      rg -v 'io\.8xd\.carethread'
  )"; then
    printf '%s\n' "$unexpected_namespace_hits"
    fail "产品技术命名空间不得残留非 8xd.io Bundle ID"
  else
    namespace_status=$?
    if [[ "$namespace_status" -eq 1 ]]; then
      pass "Bundle ID、备份格式、日志与验收脚本统一为 io.8xd.carethread"
    else
      fail "产品技术命名空间扫描执行失败（rg 状态 ${namespace_status}）"
    fi
  fi
else
  fail "产品技术命名空间未完整统一为 io.8xd.carethread"
fi

if rg -n -i --glob '*.{html,css}' \
  -e '<script' \
  -e '<(img|source)[^>]+src=["\x27]https?://' \
  -e '<link[^>]+(stylesheet|preconnect|font)[^>]+href=["\x27]https?://' \
  -e '@import[[:space:]]+url\(["\x27]?https?://' \
  website; then
  fail "官网不得加载第三方脚本、字体、分析或追踪资源"
else
  remote_runtime_status=$?
  if [[ "$remote_runtime_status" -eq 1 ]]; then
    pass "官网零第三方运行时资源"
  else
    fail "官网第三方运行时资源扫描执行失败（rg 状态 ${remote_runtime_status}）"
  fi
fi

# Cloudflare Email Address Obfuscation injects a runtime decoder unless every
# visible mailto fragment opts out. Pair counts lock the live zero-script
# contract without changing any visible copy or design.
mailto_count="$(rg -o 'href="mailto:' website --glob '*.html' | wc -l | tr -d ' ')"
email_off_start_count="$(rg -o '<!--email_off-->' website --glob '*.html' | wc -l | tr -d ' ')"
email_off_end_count="$(rg -o '<!--/email_off-->' website --glob '*.html' | wc -l | tr -d ' ')"
if [[ "$mailto_count" -gt 0 ]] &&
  [[ "$email_off_start_count" -eq "$mailto_count" ]] &&
  [[ "$email_off_end_count" -eq "$mailto_count" ]]; then
  pass "官网邮箱关闭 Cloudflare 脚本注入"
else
  fail "官网邮箱关闭 Cloudflare 脚本注入（mailto=${mailto_count} / start=${email_off_start_count} / end=${email_off_end_count}）"
fi

milestone_failures=0
for milestone in $(seq 0 9); do
  milestone_commits="$(
    git log --format='%H%x09%an%x09%s' |
      awk -F $'\t' -v prefix="M${milestone}" '
        index($3, prefix ":") == 1 ||
        index($3, prefix "：") == 1 ||
        index($3, prefix " - ") == 1 {
          print
        }
      '
  )"
  if [[ -z "$milestone_commits" ]]; then
    fail "Git 里程碑 M$milestone 提交缺失"
    milestone_failures=$((milestone_failures + 1))
  elif printf '%s\n' "$milestone_commits" |
    awk -F $'\t' '$2 != "AMortalsOdyssey" { found=1 } END { exit(found ? 0 : 1) }'
  then
    fail "Git 里程碑 M$milestone 存在非 AMortalsOdyssey 作者提交"
    milestone_failures=$((milestone_failures + 1))
  else
    pass "Git 里程碑 M$milestone 提交与作者"
  fi
done
if [[ "$milestone_failures" -eq 0 ]]; then
  pass "Git M0–M9 里程碑轨迹完整"
else
  fail "Git M0–M9 里程碑轨迹不完整（$milestone_failures 项）"
fi
if git log --format='%B' | rg -ni '^Co-authored-by:'; then
  fail "Git 历史不得包含 Co-Authored-By"
else
  pass "Git 历史无 Co-Authored-By"
fi
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  fail "Git 工作区必须干净后方可终验"
else
  pass "Git 工作区干净"
fi

if Scripts/verify.sh >"$VERIFY_LOG" 2>&1; then
  pass "verify.sh"
else
  tail -120 "$VERIFY_LOG"
  fail "verify.sh"
fi

if [[ -d "$RESULT_BUNDLE" ]] &&
  xcrun xcresulttool get test-results tests \
    --path "$RESULT_BUNDLE" --compact >"$TEST_TREE" 2>/dev/null &&
  jq '
    [
      .. | objects
      | select(
          .nodeType? == "Unit test bundle"
          or .nodeType? == "UI test bundle"
        ) as $bundle
      | $bundle
      | .. | objects
      | select(.nodeType? == "Test Case")
      | {
          bundle: ($bundle.name // ""),
          result: (.result // "Unknown"),
          nodeIdentifier: (.nodeIdentifier // ""),
          name: (.name // "")
        }
    ] | unique_by(.bundle, .nodeIdentifier, .name)
  ' "$TEST_TREE" >"$TEST_CASES" 2>/dev/null &&
  [[ "$(jq 'length' "$TEST_CASES" 2>/dev/null)" -gt 0 ]]; then
  pass "xcresult 测试树可解析（test-results）"
elif [[ -d "$RESULT_BUNDLE" ]] &&
  xcrun xcresulttool get object --legacy \
    --path "$RESULT_BUNDLE" --format json >"$LEGACY_ROOT" 2>/dev/null; then
  tests_id=$(jq -r '
    .actions._values[]
    | select(.actionResult.testsRef.id._value? != null)
    | .actionResult.testsRef.id._value
  ' "$LEGACY_ROOT" 2>/dev/null | head -1)
  if [[ -n "$tests_id" ]] &&
    xcrun xcresulttool get object --legacy \
      --path "$RESULT_BUNDLE" --id "$tests_id" --format json \
      >"$TEST_TREE" 2>/dev/null &&
    jq '
      [
        .summaries._values[]?.testableSummaries._values[]? as $bundle
        | $bundle
        | .. | objects
        | select(._type._name? == "ActionTestMetadata")
        | {
            bundle: ($bundle.targetName._value // ""),
            result: (
              if .testStatus._value == "Success" then "Passed"
              elif .testStatus._value == "Skipped" then "Skipped"
              else "Failed"
              end
            ),
            nodeIdentifier: (.identifier._value // ""),
            name: (.name._value // "")
          }
      ] | unique_by(.bundle, .nodeIdentifier, .name)
    ' "$TEST_TREE" >"$TEST_CASES" 2>/dev/null &&
    [[ "$(jq 'length' "$TEST_CASES" 2>/dev/null)" -gt 0 ]]; then
    pass "xcresult 测试树可解析（legacy fallback）"
  else
    fail "xcresult 测试树可解析"
    printf '[]\n' >"$TEST_CASES"
  fi
else
  fail "xcresult 测试树可解析"
  printf '[]\n' >"$TEST_CASES"
fi

unit_total=$(jq '
  [.[] | select(.bundle | startswith("CareThreadTests"))] | length
' "$TEST_CASES" 2>/dev/null || printf '0')
unit_passed=$(jq '
  [
    .[]
    | select(.bundle | startswith("CareThreadTests"))
    | select(.result == "Passed")
  ] | length
' "$TEST_CASES" 2>/dev/null || printf '0')
ui_total=$(jq '
  [.[] | select(.bundle | startswith("CareThreadUITests"))] | length
' "$TEST_CASES" 2>/dev/null || printf '0')
ui_passed=$(jq '
  [
    .[]
    | select(.bundle | startswith("CareThreadUITests"))
    | select(.result == "Passed")
  ] | length
' "$TEST_CASES" 2>/dev/null || printf '0')
failed_or_skipped=$(jq '
  [
    .[]
    | select(
        (.bundle | startswith("CareThreadTests"))
        or (.bundle | startswith("CareThreadUITests"))
      )
    | select(.result == "Failed" or .result == "Skipped")
  ] | length
' "$TEST_CASES" 2>/dev/null || printf '0')

if [[ "$unit_total" -ge 85 && "$unit_passed" -eq "$unit_total" ]]; then
  pass "单元测试 ${unit_passed}/${unit_total}（要求 ≥85，零非通过）"
else
  fail "单元测试 ${unit_passed}/${unit_total}（要求 ≥85，零非通过）"
fi
if [[ "$ui_total" -ge 16 && "$ui_passed" -eq "$ui_total" ]]; then
  pass "UI 测试 ${ui_passed}/${ui_total}（要求 ≥16，零非通过）"
else
  fail "UI 测试 ${ui_passed}/${ui_total}（要求 ≥16，零非通过）"
fi
if [[ "$failed_or_skipped" -eq 0 ]]; then
  pass "CareThreadTests/CareThreadUITests 失败 0、跳过 0"
else
  fail "CareThreadTests/CareThreadUITests 失败或跳过 $failed_or_skipped"
fi

network_api_matches="$(
  rg -n -i \
    'URLSession|NSURLSession|URLRequest|NSURLConnection|Alamofire|WebSocket|WKWebView|WebKit|CFNetwork|CloudKit|CKContainer|NSUbiquitous|socket[[:space:]]*\(|connect[[:space:]]*\(|getaddrinfo|\bcurl\b|\bwget\b' \
    CareThread CareThreadTests CareThreadUITests Scripts \
    --glob '*.{swift,m,mm,h,c,cc,cpp,js,jsx,ts,tsx,py,rb,go,rs,kt,kts,java,sh}' \
    --glob '!acceptance.sh' \
    2>/dev/null || true
)"
unsafe_network_api_matches="$(
  printf '%s\n' "$network_api_matches" |
    rg -v 'cloudKitDatabase:[[:space:]]*\.none' || true
)"
url_literal_matches="$(
  rg -n -i 'https?://|wss?://' \
    CareThread CareThreadTests CareThreadUITests Scripts \
    --glob '*.{swift,m,mm,h,c,cc,cpp,js,jsx,ts,tsx,py,rb,go,rs,kt,kts,java,sh}' \
    --glob '!acceptance.sh' \
    2>/dev/null || true
)"
unsafe_url_literal_matches="$(
  printf '%s\n' "$url_literal_matches" |
    rg -v \
      '^CareThread/Core/Services/Brief/CareThreadPDFBranding\.swift:[0-9]+:[[:space:]]*string: "https://carethread\.8xd\.io/"$' \
      || true
)"
if [[ -n "$unsafe_network_api_matches" ||
  -n "$unsafe_url_literal_matches" ]]; then
  printf '%s\n' "$unsafe_network_api_matches"
  printf '%s\n' "$unsafe_url_literal_matches"
  fail "多语言源码与脚本互联网 API 扫描"
else
  pass "多语言源码与脚本互联网 API 扫描"
fi
if rg -n 'import Network|NWConnection|NWBrowser|NWListener|NWParameters' \
  CareThread --glob '*.swift' \
  --glob '!CareThread/Core/Services/NearbyTransfer/**'; then
  fail "Network.framework 越界扫描"
else
  pass "Network.framework 仅位于 NearbyTransfer"
fi
if rg -n 'import Network|NWConnection|NWBrowser|NWListener|NWParameters' \
  CareThreadTests CareThreadUITests --glob '*.swift' \
  --glob '!NearbyTransfer*Tests.swift'; then
  fail "测试代码 Network.framework 越界扫描"
else
  pass "测试代码 Network.framework 仅覆盖 NearbyTransfer"
fi
if rg -n 'NWEndpoint\.hostPort|\.hostPort\(|https?://|wss?://' \
  CareThread/Core/Services/NearbyTransfer --glob '*.swift'; then
  fail "NearbyTransfer 非本地端点扫描"
elif ! rg -q 'includePeerToPeer = true' \
  CareThread/Core/Services/NearbyTransfer ||
  ! rg -q 'prohibitedInterfaceTypes = \[\.cellular\]' \
  CareThread/Core/Services/NearbyTransfer ||
  ! rg -q 'domain: "local\."' \
  CareThread/Core/Services/NearbyTransfer; then
  fail "NearbyTransfer 本地网络约束"
else
  pass "NearbyTransfer 仅 Bonjour local + peer-to-peer + 禁蜂窝"
fi
vendored_artifacts="$(
  find . \
    -path './.git' -prune -o \
    -path './DerivedData' -prune -o \
    -path './.build' -prune -o \
    \( \
      -type d \( -name '*.framework' -o -name '*.xcframework' \) -o \
      -type f \( -name '*.a' -o -name '*.dylib' \) \
    \) \
    -print
)"
if [[ -n "$vendored_artifacts" ]]; then
  printf '%s\n' "$vendored_artifacts"
  fail "仓库不得包含未审计 vendored 二进制依赖"
else
  pass "仓库无 framework/xcframework/a/dylib vendored 二进制"
fi
if rg -n 'PBXShellScriptBuildPhase|shellScript[[:space:]]*=' \
  CareThread.xcodeproj project.yml; then
  fail "工程不得包含未审计构建脚本 phase"
else
  pass "工程无 Shell Script Build Phase"
fi

if rg -n 'Color\(hex|#[0-9A-Fa-f]{6}' \
  CareThread/Features --glob '*.swift' 2>/dev/null; then
  fail "页面裸色值扫描"
else
  pass "页面裸色值扫描"
fi
if rg -n 'TODO|FIXME|fatalError\(\"unimplemented' \
  CareThread --glob '*.swift'; then
  fail "未完成标记扫描"
else
  pass "未完成标记扫描"
fi
if rg -n 'privacy:[[:space:]]*\.public' \
  CareThread --glob '*.swift'; then
  fail "生产日志不得公开插值字段"
else
  pass "生产日志无 public 插值字段"
fi
if rg -n \
  '\\\((relativePath|path),\s*privacy:\s*\.public' \
  CareThread/Core/Services/CaptureVault \
  CareThread/Core/Services/NearbyTransfer \
  --glob '*.swift'; then
  fail "Vault 路径日志隐私扫描"
else
  pass "Vault 相对路径日志均非 public"
fi
if rg -n --hidden -i \
  'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}' \
  . \
  --glob '!.git/**' \
  --glob '!DerivedData/**' \
  --glob '!.build/**' \
  --glob '!docs/screenshots/**' \
  --glob '!Benchmarks/OCRBench/results/**' \
  --glob '!Scripts/acceptance.sh'; then
  fail "仓库秘密与令牌扫描"
else
  pass "仓库无高置信秘密、令牌或私钥"
fi
if rg -n '/Users/[A-Za-z0-9._-]+' \
  . \
  --hidden \
  --glob '!.git/**' \
  --glob '!DerivedData/**' \
  --glob '!.build/**' \
  --glob '!docs/screenshots/**' \
  --glob '!Benchmarks/OCRBench/results/**' \
  --glob '!Scripts/acceptance.sh'; then
  fail "仓库不得记录开发机绝对用户路径"
else
  pass "仓库无开发机绝对用户路径"
fi
credential_files="$(
  find . \
    -path './.git' -prune -o \
    -path './DerivedData' -prune -o \
    -path './.build' -prune -o \
    -type f \
    \( -name '.env' -o -name '.env.*' -o -name '*.p12' -o \
      -name '*.mobileprovision' -o -name '*.cer' -o -name '*.key' -o \
      -name 'id_rsa*' \) \
    -print
)"
if [[ -n "$credential_files" ]]; then
  printf '%s\n' "$credential_files"
  fail "仓库不得包含凭据文件"
else
  pass "仓库无凭据、签名证书或私钥文件"
fi

if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity' \
  CareThread/Resources/Info.plist >/dev/null 2>&1; then
  fail "Info.plist 不含 NSAppTransportSecurity"
else
  pass "Info.plist 不含 NSAppTransportSecurity"
fi

permission_failures=0
plist_equals NSCameraUsageDescription \
  '拍摄纸质报告需要使用相机。照片只会保存在这台手机上。' ||
  permission_failures=$((permission_failures + 1))
plist_equals NSPhotoLibraryUsageDescription \
  '通过系统照片选择器读取你明确选中的报告截图。所选照片只会保存在这台手机上。' ||
  permission_failures=$((permission_failures + 1))
plist_equals NSFaceIDUsageDescription \
  '用面容 ID 保护你的健康资料。' ||
  permission_failures=$((permission_failures + 1))
plist_equals NSCalendarsFullAccessUsageDescription \
  '只有在你主动选择“加入系统日历”时，CareThread 才会把复查安排写入日历。' ||
  permission_failures=$((permission_failures + 1))
plist_equals NSLocalNetworkUsageDescription \
  '在你主动发起换机时，通过本地网络把所选家人的资料加密传到另一台 iPhone。' ||
  permission_failures=$((permission_failures + 1))
if [[ "$permission_failures" -eq 0 ]]; then
  pass "Info.plist 权限文案逐字一致（相机/照片/Face ID/日历/本地网络）"
else
  fail "Info.plist 有 $permission_failures 条权限文案不一致"
fi
bonjour_service=$(/usr/libexec/PlistBuddy \
  -c 'Print :NSBonjourServices:0' CareThread/Resources/Info.plist \
  2>/dev/null || true)
if [[ "$bonjour_service" == "_carethread._tcp" ]] &&
  rg -q 'serviceType = "_carethread\._tcp"' \
    CareThread/Core/Services/NearbyTransfer --glob '*.swift'; then
  pass "Info.plist Bonjour 服务与 NearbyTransfer 协议一致"
else
  fail "Info.plist Bonjour 服务与 NearbyTransfer 协议一致"
fi

privacy_manifest=CareThread/Resources/PrivacyInfo.xcprivacy
privacy_json=/tmp/carethread-privacy-manifest.json
if [[ -s "$privacy_manifest" ]] &&
  plutil -convert json -o "$privacy_json" "$privacy_manifest" 2>/dev/null &&
  jq -e '
    .NSPrivacyTracking == false
    and .NSPrivacyTrackingDomains == []
    and .NSPrivacyCollectedDataTypes == []
    and (
      [
        .NSPrivacyAccessedAPITypes[]
        | {
            category: .NSPrivacyAccessedAPIType,
            reasons: (.NSPrivacyAccessedAPITypeReasons | sort)
          }
      ] | sort_by(.category)
    ) == (
      [
        {
          category: "NSPrivacyAccessedAPICategoryUserDefaults",
          reasons: ["CA92.1"]
        },
        {
          category: "NSPrivacyAccessedAPICategoryDiskSpace",
          reasons: ["E174.1"]
        },
        {
          category: "NSPrivacyAccessedAPICategoryFileTimestamp",
          reasons: ["C617.1"]
        }
      ] | sort_by(.category)
    )
  ' "$privacy_json" >/dev/null; then
  pass "PrivacyInfo 跟踪、域名、收集类型与 Required Reason API 精确匹配"
else
  fail "PrivacyInfo 精确声明"
fi

package_resolved=$(find CareThread.xcodeproj -name Package.resolved \
  -type f -print -quit)
project_package_count="$(
  awk '
    /^packages:/ { inside=1; next }
    inside && /^[^[:space:]]/ { inside=0 }
    inside && /^  [A-Za-z0-9_-]+:/ { count++ }
    END { print count+0 }
  ' project.yml
)"
project_dependency_ok=0
if [[ "$project_package_count" == "1" ]] &&
  [[ "$(rg -c '^  ZIPFoundation:$' project.yml)" == "1" ]] &&
  [[ "$(rg -c '^[[:space:]]+url: https://github\.com/weichsel/ZIPFoundation\.git$' project.yml)" == "1" ]] &&
  [[ "$(rg -c '^[[:space:]]+exactVersion: 0\.9\.20$' project.yml)" == "1" ]] &&
  [[ "$(rg -c '^[[:space:]]+- package: ZIPFoundation$' project.yml)" == "1" ]]; then
  project_dependency_ok=1
fi
package_pin_ok=0
if [[ -n "$package_resolved" ]] &&
  [[ "$(jq '.pins | length' "$package_resolved" 2>/dev/null)" == "1" ]] &&
  [[ "$(jq -r '.pins[0].identity' "$package_resolved" 2>/dev/null)" == \
    "zipfoundation" ]] &&
  [[ "$(jq -r '.pins[0].kind' "$package_resolved" 2>/dev/null)" == \
    "remoteSourceControl" ]] &&
  [[ "$(jq -r '.pins[0].location' "$package_resolved" 2>/dev/null)" == \
    "https://github.com/weichsel/ZIPFoundation.git" ]] &&
  [[ "$(jq -r '.pins[0].state.version' "$package_resolved" 2>/dev/null)" == \
    "0.9.20" ]] &&
  [[ "$(jq -r '.pins[0].state.revision' "$package_resolved" 2>/dev/null)" == \
    "22787ffb59de99e5dc1fbfe80b19c97a904ad48d" ]]; then
  package_pin_ok=1
fi
zip_license=DerivedData/SourcePackages/checkouts/ZIPFoundation/LICENSE
license_ok=0
if [[ -s "$zip_license" ]] &&
  rg -q '^MIT License$' "$zip_license" &&
  ! rg -ni 'GNU (GENERAL PUBLIC LICENSE|AFFERO)|\bAGPL\b|\bGPL\b' \
    "$zip_license"; then
  license_ok=1
fi
if [[ "$project_dependency_ok" -eq 1 &&
  "$package_pin_ok" -eq 1 &&
  "$license_ok" -eq 1 ]]; then
  pass "依赖白名单：project/锁文件/commit/许可证仅 ZIPFoundation 0.9.20 MIT"
else
  fail "依赖白名单（project=${project_dependency_ok} / pin=${package_pin_ok} / license=${license_ok}）"
fi

shopt -s nullglob
source "$ROOT_DIR/Scripts/screenshot-routes.sh"
screenshots=(docs/screenshots/*.png)
standard_screenshots=()
elder_screenshots=()
missing_screenshots=0
for entry in "${CARETHREAD_SCREENSHOT_ROUTES[@]}"; do
  IFS='|' read -r number slug _ mode _ <<<"$entry"
  for appearance in light dark; do
    file="docs/screenshots/$number-$slug-$appearance.png"
    if [[ -s "$file" ]]; then
      if [[ "$mode" == "standard" ]]; then
        standard_screenshots+=("$file")
      else
        elder_screenshots+=("$file")
      fi
    else
      missing_screenshots=$((missing_screenshots + 1))
    fi
  done
done

dimension_count=0
dimension_rows=0
unique_hashes=0
if [[ "${#screenshots[@]}" -gt 0 ]]; then
  screenshot_dimensions=$(
    for file in "${screenshots[@]}"; do
      sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null |
        awk '/pixelWidth/{w=$2}/pixelHeight/{print w "x" $2}'
    done
  )
  dimension_count=$(printf '%s\n' "$screenshot_dimensions" |
    sed '/^$/d' | sort -u | wc -l | tr -d ' ')
  dimension_rows=$(printf '%s\n' "$screenshot_dimensions" |
    sed '/^$/d' | wc -l | tr -d ' ')
  unique_hashes=$(
    shasum -a 256 "${screenshots[@]}" |
      awk '{print $1}' | sort -u | wc -l | tr -d ' '
  )
fi
if [[ "${#screenshots[@]}" -eq "$CARETHREAD_SCREENSHOT_COUNT" &&
  "${#standard_screenshots[@]}" -eq "$CARETHREAD_SCREENSHOT_STANDARD_COUNT" &&
  "${#elder_screenshots[@]}" -eq "$CARETHREAD_SCREENSHOT_ELDER_COUNT" &&
  "$missing_screenshots" -eq 0 &&
  "$dimension_rows" -eq "$CARETHREAD_SCREENSHOT_COUNT" &&
  "$dimension_count" -eq 1 &&
  "$unique_hashes" -eq "$CARETHREAD_SCREENSHOT_COUNT" ]]; then
  pass "截图 ${CARETHREAD_SCREENSHOT_COUNT}（标准 ${CARETHREAD_SCREENSHOT_STANDARD_COUNT} / 长辈 ${CARETHREAD_SCREENSHOT_ELDER_COUNT}），命名/非空/尺寸/去重均通过"
else
  fail "截图验收（总 ${#screenshots[@]} / 标准 ${#standard_screenshots[@]} / 长辈 ${#elder_screenshots[@]} / 缺失 ${missing_screenshots} / 有效尺寸 ${dimension_rows} / 尺寸种类 ${dimension_count} / 唯一 ${unique_hashes}）"
fi
if Scripts/validate-screenshot-manifest.sh; then
  pass "截图 manifest 来源与内容可复查"
else
  fail "截图 manifest 来源与内容可复查"
fi
if Scripts/validate-walkthrough.sh; then
  pass "设计 §14 与高风险边界人工走查证据"
else
  fail "设计 §14 与高风险边界人工走查证据"
fi

app_icon=CareThread/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
icon_bytes=0
icon_width=0
icon_height=0
icon_alpha=yes
if [[ -f "$app_icon" ]]; then
  icon_bytes=$(stat -f '%z' "$app_icon" 2>/dev/null || printf '0')
  icon_width=$(sips -g pixelWidth "$app_icon" 2>/dev/null |
    awk '/pixelWidth/{print $2}')
  icon_height=$(sips -g pixelHeight "$app_icon" 2>/dev/null |
    awk '/pixelHeight/{print $2}')
  icon_alpha=$(sips -g hasAlpha "$app_icon" 2>/dev/null |
    awk '/hasAlpha/{print $2}')
fi
if [[ "$icon_bytes" -gt 20480 &&
  "$icon_width" == "1024" &&
  "$icon_height" == "1024" &&
  "$icon_alpha" == "no" ]]; then
  pass "AppIcon 1024×1024、>20KB、无透明通道"
else
  fail "AppIcon 非占位检查（${icon_width}×${icon_height}, ${icon_bytes}B, alpha=${icon_alpha}）"
fi

fixture_files=0
fixture_tests=0
for sample in 1 2 3 4 5 6; do
  [[ -s "CareThreadTests/Fixtures/f$sample.txt" ]] &&
    [[ -s "CareThreadTests/Fixtures/f$sample.expected.json" ]] &&
    fixture_files=$((fixture_files + 1))
  if test_case_passed "test_extract_whenF${sample}"; then
    fixture_tests=$((fixture_tests + 1))
  fi
done
if [[ "$fixture_files" -eq 6 && "$fixture_tests" -eq 6 ]]; then
  pass "F1–F6 虚构样张文本/期望 JSON 非空且 6 项断言全绿"
else
  fail "F1–F6 样张（文件 $fixture_files/6，测试 $fixture_tests/6）"
fi

elder_tests=0
for test_name in \
  testU13ElderModeShowsThreeTabsAndSettingsSwitch \
  testU14TodayShowsMedicationFollowUpAndDoctorBrief \
  testU15SimplifiedFixtureCaptureSavesPendingRecord \
  testU16PendingBannerAppearsAfterElderCapture; do
  test_case_passed "$test_name" && elder_tests=$((elder_tests + 1))
done
if [[ "$elder_tests" -eq 4 ]] &&
  rg -q 'enum Elder|struct Elder' CareThread/DesignSystem \
    CareThread/Features --glob '*.swift' &&
  [[ "${#elder_screenshots[@]}" -eq "$CARETHREAD_SCREENSHOT_ELDER_COUNT" ]]; then
  pass "长辈版文案命名空间、启动截图、U13–U16 全绿"
else
  fail "长辈版专项（U13–U16 $elder_tests/4）"
fi

boundary_total=0
boundary_check() {
  local id="$1"
  shift
  local pattern
  local ok=1
  for pattern in "$@"; do
    if ! test_case_passed "$pattern"; then
      ok=0
    fi
  done
  if [[ "$ok" -eq 1 ]]; then
    boundary_total=$((boundary_total + 1))
    pass "边界 $id 自动化证据"
  else
    fail "边界 $id 自动化证据"
  fi
}

boundary_check B1 'testB1EmptyDatabaseShowsEveryStandardTabEmptyState'
boundary_check B2 \
  'test_age_whenBirthdayMissing_returnsUnavailable' \
  'testB2MissingBirthdayShowsEditableAgeAndAllowsBoundaryValue'
boundary_check B3 'test_age_whenBirthdayAfterEvent_returnsChronologyWarning'
boundary_check B4 'test_age_whenLeapDayBirthdayInCommonYear_returnsValidAge'
boundary_check B5 \
  'test_vision_whenBlankImage_returnsEmptyBlocks' \
  'testB5BlankOCRShowsBannerAndAllowsManualCompletionAndSave'
boundary_check B6 \
  'test_date_whenFuture_keepsWithLowConfidence' \
  'testB6FutureEventDateWarnsButSaveRemainsAvailable'
boundary_check B7 'test_longText_whenTenThousandCharacters_completesQuickly'
boundary_check B8 \
  'test_specialCharacters_whenEmojiAndFullWidthParentheses_remainsStable' \
  'roundTripRestoresCountsAndSpecialCharacters'
boundary_check B9 'missingStagedOriginal_isRejected'
boundary_check B10 'importingSamePackageTwiceIsIdempotent'
boundary_check B11 \
  'truncatedArchiveIsRejected' \
  'tamperedTrackedFileFailsBeforeDatabaseMutation'
boundary_check B12 \
  'rollbackAfterVaultSwapLeavesCurrentDatabaseUntouched' \
  'rollbackAfterDatabaseSaveRestoresSnapshot'
boundary_check B13 'medicationEndBeforeStart'
boundary_check B14 'followUpOverdueGrouping'
boundary_check B15 'lateNightSchedulesNextMorning'
boundary_check B16 'largeDocument_requiresExplicitSoftLimitAcknowledgement'
boundary_check B17 'previewPolicy_downsamplesDimensionsWithoutTouchingOriginal'
boundary_check B18 \
  'deniedNotificationPermission' \
  'testDeniedNotificationPermissionShowsSettingsRecoveryWithoutCrash'
boundary_check B19 \
  'hidesEmptySectionsAndDisablesProfileOnlyExport' \
  'rejectsEmptyDocument' \
  'testB19EmptyBriefShowsGuidanceAndDisablesExport'
boundary_check B20 'deletedRecordBecomesStableTombstone'
boundary_check B21 'testB21AccessibilitySizeKeepsPrimaryActionsHittable'
boundary_check B22 'testB22EmptyLibraryShowsMedicationAndRecordsEmptyStates'
boundary_check B23 \
  'test_captureDraft_whenInserted_roundTripsState' \
  'elderHidesStandardDraftResume'

if [[ "$boundary_total" -eq 23 ]]; then
  pass "边界矩阵 23/23 自动化落点全绿"
else
  fail "边界矩阵 $boundary_total/23 自动化落点全绿"
fi

if [[ "$FAILURES" -eq 0 ]]; then
  printf 'PASS CareThread 最终验收（全部检查通过）\n'
  exit 0
fi

printf 'FAIL CareThread 最终验收（%d 项失败）\n' "$FAILURES"
exit 1
