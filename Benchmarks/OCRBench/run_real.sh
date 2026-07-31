#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BENCH="$ROOT/Benchmarks/OCRBench"
REAL_TESTSET="$BENCH/testset/real"
MANIFEST="$REAL_TESTSET/manifest.json"
VENV="${OCR_BENCH_VENV:-/tmp/carethread-ocr-venv}"
PRIVATE_BUILD=$(/usr/bin/mktemp -d /tmp/carethread-ocr-real.XXXXXX)

cleanup() {
  chmod -R u+w "$PRIVATE_BUILD" 2>/dev/null || true
  rm -rf -- "$PRIVATE_BUILD"
}
trap cleanup EXIT HUP INT TERM

if [ ! -f "$MANIFEST" ]; then
  printf '%s\n' \
    "未找到 OCR 真实集清单：$MANIFEST" \
    "请按 testset/real/README.md 在本机准备无语义文件名、图片与人工校对文本；这些文件会被 Git 忽略。"
  exit 2
fi

for tracked in $(git -C "$ROOT" ls-files -- "Benchmarks/OCRBench/testset/real/*"); do
  case "$tracked" in
    */.gitignore|*/README.md) ;;
    *)
      printf '%s\n' "拒绝运行：真实集文件已被 Git 跟踪：$tracked"
      exit 3
      ;;
  esac
done

if [ ! -x "$VENV/bin/python" ]; then
  "$BENCH/setup_candidate.sh"
fi

MODULE_CACHE="$PRIVATE_BUILD/module-cache"
RAW="$PRIVATE_BUILD/raw"
mkdir -p "$MODULE_CACHE" "$RAW" "$BENCH/results/real"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$BENCH/vision_bench.swift" \
  -framework AppKit \
  -framework Vision \
  -framework ImageIO \
  -o "$PRIVATE_BUILD/vision_bench"

"$PRIVATE_BUILD/vision_bench" \
  "$REAL_TESTSET" \
  "$RAW/vision.json" \
  3

MODEL_DIR=$(
  "$VENV/bin/python" -c \
    'import pathlib,rapidocr; print(pathlib.Path(rapidocr.__file__).resolve().parent/"models")'
)
"$VENV/bin/python" "$BENCH/run_rapidocr.py" \
  "$REAL_TESTSET" \
  "$RAW/rapidocr.json" \
  --iterations 3 \
  --model-dir "$MODEL_DIR"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/CareThread/Core/Models/DomainTypes.swift" \
  "$ROOT/CareThread/Core/Services/DateProvider.swift" \
  "$ROOT/CareThread/Core/Services/AppLog.swift" \
  "$ROOT/CareThread/Core/Services/ExtractionEngine/ExtractionEngine.swift" \
  "$BENCH/extraction_score.swift" \
  -o "$PRIVATE_BUILD/extraction_score"

for engine in vision rapidocr; do
  "$PRIVATE_BUILD/extraction_score" \
    "$MANIFEST" \
    "$RAW/$engine.json" \
    "$RAW/${engine}_scored.json"
done

"$VENV/bin/python" "$BENCH/score_real.py" \
  "$REAL_TESTSET" \
  "$MANIFEST" \
  "$BENCH/results/real/results.json" \
  "$BENCH/results/real/RESULTS.md" \
  "$RAW/vision_scored.json" \
  "$RAW/rapidocr_scored.json"

printf '%s\n' \
  "OCR 真实集 v2 回归完成。" \
  "隐私安全结果：$BENCH/results/real/RESULTS.md" \
  "含 OCR 原文的临时结果将在命令退出时清理。"
