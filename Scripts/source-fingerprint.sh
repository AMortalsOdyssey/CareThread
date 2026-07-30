#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HASH_ROWS="$(mktemp "${TMPDIR:-/tmp}/carethread-source-hashes.XXXXXX")"
trap 'rm -f "$HASH_ROWS"' EXIT

cd "$ROOT_DIR"

while IFS= read -r -d '' file_path; do
  [[ -f "$file_path" ]] || continue
  file_hash="$(shasum -a 256 "$file_path" | awk '{print $1}')"
  printf '%s  %s\n' "$file_hash" "$file_path"
done < <(
  git ls-files -co --exclude-standard -z -- \
    CareThread \
    CareThreadTests \
    CareThreadUITests \
    Scripts \
    project.yml |
    LC_ALL=C sort -z
) >"$HASH_ROWS"

[[ -s "$HASH_ROWS" ]] || {
  printf 'No source files found\n' >&2
  exit 1
}

shasum -a 256 "$HASH_ROWS" | awk '{print $1}'
