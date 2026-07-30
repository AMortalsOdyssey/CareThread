#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; exit 1; }

Scripts/verify.sh >/tmp/carethread-verify.log 2>&1 || {
  tail -80 /tmp/carethread-verify.log
  fail "verify.sh"
}
pass "verify.sh"

if rg -n 'URLSession|NWConnection|Alamofire' CareThread CareThreadTests; then
  fail "零联网扫描"
fi
pass "零联网扫描"

if rg -n 'Color\(hex|#[0-9A-Fa-f]{6}' CareThread/Features 2>/dev/null; then
  fail "页面裸色值扫描"
fi
pass "页面裸色值扫描"

if rg -n 'TODO|FIXME|fatalError\(\"unimplemented' CareThread; then
  fail "未完成标记扫描"
fi
pass "未完成标记扫描"

pass "M0 骨架验收"

