#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="${1:-$ROOT_DIR/docs/MANUAL_WALKTHROUGH_EVIDENCE.json}"
EXPECTED_IDS='["B16","B17","B18","B23","B9","DESIGN-01","DESIGN-02","DESIGN-03","DESIGN-04","DESIGN-05","DESIGN-06","DESIGN-07","DESIGN-08"]'

fail() {
  printf '[walkthrough] FAIL %s\n' "$1" >&2
  exit 1
}

cd "$ROOT_DIR"
command -v jq >/dev/null || fail "缺少 jq"
[[ -s "$EVIDENCE" ]] || fail "缺少人工走查证据 docs/MANUAL_WALKTHROUGH_EVIDENCE.json"
jq -e . "$EVIDENCE" >/dev/null || fail "走查证据不是有效 JSON"

jq -e --argjson expected "$EXPECTED_IDS" '
  .schemaVersion == 1
  and (.sourceCommit | type == "string" and test("^[0-9a-f]{40}$"))
  and (.reviewedAtUTC | type == "string" and length > 0)
  and (.reviewer | type == "string" and length > 0)
  and (.simulator.deviceName | type == "string" and length > 0)
  and (.simulator.osVersion | type == "string" and length > 0)
  and (.checks | type == "array" and length == 13)
  and ([.checks[].id] | sort == $expected)
  and all(
    .checks[];
    .status == "passed"
    and (.notes | type == "string" and length > 0)
    and (.evidence | type == "array" and length > 0)
    and all(
      .evidence[];
      (.path | type == "string" and startswith("docs/walkthrough/"))
      and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    )
  )
' "$EVIDENCE" >/dev/null ||
  fail "必须完整记录设计 §14 八项及 B9/B16/B17/B18/B23，且全部 passed 并附证据"

source_commit="$(jq -r '.sourceCommit' "$EVIDENCE")"
git cat-file -e "$source_commit^{commit}" 2>/dev/null ||
  fail "sourceCommit 不是本仓库提交"
git merge-base --is-ancestor "$source_commit" HEAD ||
  fail "sourceCommit 不是当前 HEAD 的祖先"

while IFS=$'\t' read -r path expected_hash; do
  case "$path" in
    docs/walkthrough/*) ;;
    *) fail "证据路径越界：$path" ;;
  esac
  [[ -s "$path" ]] || fail "证据文件缺失或为空：$path"
  actual_hash="$(shasum -a 256 "$path" | awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] ||
    fail "证据哈希不一致：$path"
done < <(
  jq -r '.checks[].evidence[] | [.path, .sha256] | @tsv' "$EVIDENCE" |
    LC_ALL=C sort -u
)

rg -q 'MANUAL_WALKTHROUGH_EVIDENCE\.json' docs/PROGRESS.md ||
  fail "PROGRESS.md 未登记人工走查证据"

printf '[walkthrough] PASS 设计 §14 与 B9/B16/B17/B18/B23 人工走查证据可复查\n'
