#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/docs/screenshots"
mkdir -p "$OUTPUT_DIR"

echo "截图脚本将在 M8 接入 18 个确定性场景；当前目录：$OUTPUT_DIR"

