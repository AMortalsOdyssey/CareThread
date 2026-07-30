#!/bin/sh
set -eu

VENV="${OCR_BENCH_VENV:-/tmp/carethread-ocr-venv}"
PYTHON="${OCR_BENCH_BOOTSTRAP_PYTHON:-python3.12}"

if [ ! -x "$VENV/bin/python" ]; then
  "$PYTHON" -m venv "$VENV"
fi

"$VENV/bin/pip" install \
  "rapidocr==3.8.4" \
  "onnxruntime==1.26.0" \
  "pillow==12.3.0" \
  "numpy==2.5.1" \
  "psutil==7.2.2"

"$VENV/bin/python" - <<'PY'
from pathlib import Path
from rapidocr import RapidOCR
from rapidocr.utils.typings import OCRVersion

params = {
    "Global.log_level": "info",
    "Det.ocr_version": OCRVersion.PPOCRV5,
    "Rec.ocr_version": OCRVersion.PPOCRV5,
    "Cls.ocr_version": OCRVersion.PPOCRV5,
}
RapidOCR(params=params)
print(Path(__import__("rapidocr").__file__).resolve().parent / "models")
PY
