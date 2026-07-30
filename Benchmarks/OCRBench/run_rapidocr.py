#!/usr/bin/env python3
"""Run bundled PP-OCRv5 mobile ONNX weights through RapidOCR without networking."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import socket
import threading
import time
from pathlib import Path

import psutil
from rapidocr import RapidOCR
from rapidocr.utils.typings import OCRVersion


MODEL_SPECS = {
    "det": (
        "ch_PP-OCRv5_det_mobile.onnx",
        "4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae",
    ),
    "cls": (
        "ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx",
        "54379ae5174d026780215fc748a7f31910dee36818e63d49e17dc598ecc82df7",
    ),
    "rec": (
        "ch_PP-OCRv5_rec_mobile.onnx",
        "5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5",
    ),
}


class NetworkDisabledError(RuntimeError):
    pass


class NetworkDisabledSocket:
    def __init__(self, *_args, **_kwargs):
        raise NetworkDisabledError("network is disabled during the OCR benchmark")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_models(model_dir: Path) -> dict[str, Path]:
    output: dict[str, Path] = {}
    for role, (name, expected_hash) in MODEL_SPECS.items():
        path = model_dir / name
        if not path.exists():
            raise FileNotFoundError(
                f"{path} is missing; run setup_candidate.sh before benchmarking"
            )
        actual_hash = sha256(path)
        if actual_hash != expected_hash:
            raise RuntimeError(f"SHA-256 mismatch for {path}: {actual_hash}")
        output[role] = path
    return output


def reading_order(output) -> list[tuple[str, float]]:
    if output.txts is None or output.boxes is None:
        return []
    rows = []
    scores = output.scores or [0.0] * len(output.txts)
    for text, score, box in zip(output.txts, scores, output.boxes):
        center_y = sum(float(point[1]) for point in box) / 4
        center_x = sum(float(point[0]) for point in box) / 4
        rows.append((center_y, center_x, str(text), float(score)))
    rows.sort(key=lambda item: (round(item[0] / 18), item[1]))
    return [(item[2], item[3]) for item in rows]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("testset", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--model-dir", type=Path, required=True)
    args = parser.parse_args()

    models = resolve_models(args.model_dir.resolve())
    original_socket = socket.socket
    socket.socket = NetworkDisabledSocket
    try:
        engine = RapidOCR(
            params={
                "Global.log_level": "warning",
                "Global.model_root_dir": str(args.model_dir.resolve()),
                "Det.ocr_version": OCRVersion.PPOCRV5,
                "Det.model_path": str(models["det"]),
                "Cls.ocr_version": OCRVersion.PPOCRV5,
                "Cls.model_path": str(models["cls"]),
                "Rec.ocr_version": OCRVersion.PPOCRV5,
                "Rec.model_path": str(models["rec"]),
            }
        )

        manifest = json.loads((args.testset / "manifest.json").read_text(encoding="utf-8"))
        samples = manifest["samples"]
        engine(args.testset / samples[0]["image"])

        process = psutil.Process()
        baseline_rss = process.memory_info().rss
        peak_rss = baseline_rss
        keep_sampling = True

        def sample_memory() -> None:
            nonlocal peak_rss
            while keep_sampling:
                peak_rss = max(peak_rss, process.memory_info().rss)
                time.sleep(0.01)

        sampler = threading.Thread(target=sample_memory, daemon=True)
        sampler.start()

        result_rows = []
        for sample in samples:
            timings = []
            ordered = []
            for _ in range(max(1, args.iterations)):
                started = time.perf_counter()
                output = engine(args.testset / sample["image"])
                timings.append((time.perf_counter() - started) * 1_000)
                ordered = reading_order(output)
            result_rows.append(
                {
                    "id": sample["id"],
                    "group": sample["group"],
                    "subgroup": sample["subgroup"],
                    "scored": sample["scored"],
                    "text": "\n".join(text for text, _ in ordered),
                    "average_confidence": (
                        sum(score for _, score in ordered) / len(ordered) if ordered else 0
                    ),
                    "latency_ms": timings,
                }
            )
            print(f"rapidocr-v5: {sample['id']}", flush=True)

        keep_sampling = False
        sampler.join(timeout=1)
        model_bytes = sum(path.stat().st_size for path in models.values())
        ort_library = Path(importlib.util.find_spec("onnxruntime").origin).parent / "capi"
        ort_dylibs = list(ort_library.glob("libonnxruntime*.dylib"))
        runtime_bytes = sum(path.stat().st_size for path in ort_dylibs)
        result = {
            "engine": "RapidOCR PP-OCRv5 mobile / ONNX Runtime",
            "engine_identifier": "rapidocr-ppocrv5-mobile",
            "platform": "macOS Apple Silicon",
            "iterations_per_page": max(1, args.iterations),
            "rapidocr_version": importlib.metadata.version("rapidocr"),
            "onnxruntime_version": importlib.metadata.version("onnxruntime"),
            "network_socket_disabled": True,
            "model_sha256": {
                role: sha256(path) for role, path in models.items()
            },
            "model_bytes": model_bytes,
            "runtime_arm64_dylib_bytes": runtime_bytes,
            "estimated_arm64_increment_bytes": model_bytes + runtime_bytes,
            "baseline_rss_bytes": baseline_rss,
            "peak_rss_bytes": peak_rss,
            "peak_rss_increment_bytes": max(0, peak_rss - baseline_rss),
            "rows": result_rows,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    finally:
        socket.socket = original_socket


if __name__ == "__main__":
    main()
