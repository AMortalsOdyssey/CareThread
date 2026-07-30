#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BENCH="$ROOT/Benchmarks/OCRBench"
BUILD="${OCR_BENCH_BUILD_DIR:-/tmp/carethread-ocr-bench}"
VENV="${OCR_BENCH_VENV:-/tmp/carethread-ocr-venv}"
MODULE_CACHE="$BUILD/module-cache"

mkdir -p "$BUILD" "$MODULE_CACHE" "$BENCH/results/raw"

if [ ! -x "$VENV/bin/python" ]; then
  "$BENCH/setup_candidate.sh"
fi

"$VENV/bin/python" "$BENCH/generate_testset.py"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$BENCH/vision_bench.swift" \
  -framework AppKit \
  -framework Vision \
  -framework ImageIO \
  -o "$BUILD/vision_bench"

"$BUILD/vision_bench" \
  "$BENCH/testset" \
  "$BENCH/results/raw/vision_macos.json" \
  3

MODEL_DIR=$(
  "$VENV/bin/python" -c \
    'import pathlib,rapidocr; print(pathlib.Path(rapidocr.__file__).resolve().parent/"models")'
)
"$VENV/bin/python" "$BENCH/run_rapidocr.py" \
  "$BENCH/testset" \
  "$BENCH/results/raw/rapidocr_v5_macos.json" \
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
  -o "$BUILD/extraction_score"

for engine in vision_macos rapidocr_v5_macos; do
  "$BUILD/extraction_score" \
    "$BENCH/testset/manifest.json" \
    "$BENCH/results/raw/$engine.json" \
    "$BENCH/results/raw/${engine}_scored.json"
done

"$VENV/bin/python" "$BENCH/score.py" \
  "$BENCH/testset/manifest.json" \
  "$BENCH/results/results.json" \
  "$BENCH/results/RESULTS.md" \
  --simulator-json "$BENCH/results/raw/vision_simulator.json" \
  "$BENCH/results/raw/vision_macos_scored.json" \
  "$BENCH/results/raw/rapidocr_v5_macos_scored.json"

printf '%s\n' "OCR benchmark complete: $BENCH/results/RESULTS.md"
