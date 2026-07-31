#!/usr/bin/env python3
"""Score a private real-photo OCR set without persisting readable health data."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import unicodedata
from pathlib import Path


PROTOCOL = "carethread-ocr-real-v2"
MINIMUM_RELATIVE_CER_IMPROVEMENT = 0.50
MINIMUM_FIELD_HIT_IMPROVEMENT = 0.05


def normalize(value: str) -> str:
    return "".join(
        character
        for character in unicodedata.normalize("NFKC", value)
        if not character.isspace()
    )


def edit_distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for row_index, left_character in enumerate(left, start=1):
        current = [row_index]
        for column_index, right_character in enumerate(right, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column_index] + 1,
                    previous[column_index - 1]
                    + (left_character != right_character),
                )
            )
        previous = current
    return previous[-1]


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def percentile_95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def confined_file(testset: Path, relative: str) -> Path:
    root = testset.resolve()
    value = (root / relative).resolve()
    if value == root or root not in value.parents or not value.is_file():
        raise ValueError("manifest contains a missing or out-of-directory file")
    return value


def load_private_samples(testset: Path, manifest: dict) -> tuple[list[dict], dict[str, dict]]:
    samples: list[dict] = []
    by_id: dict[str, dict] = {}
    for raw in manifest.get("samples", []):
        identifier = raw.get("id")
        if (
            not isinstance(identifier, str)
            or not identifier
            or identifier in by_id
            or raw.get("group") != "R"
            or raw.get("subgroup") != "real"
            or raw.get("scored") is not True
        ):
            raise ValueError("real manifest contains an invalid sample")
        image_path = confined_file(testset, raw["image"])
        if isinstance(raw.get("reference_normalized"), str):
            reference = normalize(raw["reference_normalized"])
        else:
            reference_path = confined_file(testset, raw["reference"])
            reference = normalize(reference_path.read_text(encoding="utf-8"))
        if not reference:
            raise ValueError("real manifest contains an empty reference")
        sample = {
            "id": identifier,
            "image_sha256": sha256_file(image_path),
            "reference_sha256": sha256_bytes(reference.encode("utf-8")),
            "reference": reference,
        }
        samples.append(sample)
        by_id[identifier] = sample
    if not samples:
        raise ValueError("real manifest contains no scored R samples")
    return samples, by_id


def score_engine(engine: dict, samples: list[dict], by_id: dict[str, dict]) -> dict:
    rows = engine.get("rows", [])
    row_by_id = {
        row.get("id"): row
        for row in rows
        if isinstance(row, dict) and isinstance(row.get("id"), str)
    }
    if set(row_by_id) != set(by_id):
        raise ValueError("engine output does not match the private manifest")

    total_characters = 0
    total_edits = 0
    total_field_hits = 0
    total_field_count = 0
    latency_values: list[float] = []
    page_scores: list[dict] = []
    for sample in samples:
        row = row_by_id[sample["id"]]
        recognized = normalize(str(row.get("text", "")))
        reference = sample["reference"]
        errors = edit_distance(reference, recognized)
        field_hits = int(row.get("field_hit_count", 0))
        field_total = int(row.get("field_total_count", 0))
        if field_total < 0 or field_hits < 0 or field_hits > field_total:
            raise ValueError("engine output contains invalid field counts")
        latencies = [float(value) for value in row.get("latency_ms", [])]
        if not latencies:
            raise ValueError("engine output contains no latency samples")
        latency_values.extend(latencies)
        total_characters += len(reference)
        total_edits += errors
        total_field_hits += field_hits
        total_field_count += field_total
        page_scores.append(
            {
                "image_sha256": sample["image_sha256"],
                "reference_sha256": sample["reference_sha256"],
                "reference_characters": len(reference),
                "edit_distance": errors,
                "cer": errors / len(reference),
                "field_hits": field_hits,
                "field_total": field_total,
            }
        )

    return {
        "engine_identifier": str(engine.get("engine_identifier", "unknown")),
        "cer": total_edits / total_characters,
        "reference_characters": total_characters,
        "edit_distance": total_edits,
        "field_hits": total_field_hits,
        "field_total": total_field_count,
        "field_hit_rate": (
            total_field_hits / total_field_count
            if total_field_count
            else 0.0
        ),
        "p95_latency_ms": percentile_95(latency_values),
        "page_scores": page_scores,
    }


def decide(metrics: list[dict]) -> dict:
    vision = next(
        (
            metric
            for metric in metrics
            if metric["engine_identifier"] == "apple-vision"
        ),
        None,
    )
    if vision is None:
        raise ValueError("Apple Vision baseline is required")
    evaluations = []
    for candidate in metrics:
        if candidate is vision:
            continue
        relative_improvement = (
            (vision["cer"] - candidate["cer"]) / vision["cer"]
            if vision["cer"] > 0
            else 0.0
        )
        field_improvement = (
            candidate["field_hit_rate"] - vision["field_hit_rate"]
        )
        passed = (
            relative_improvement >= MINIMUM_RELATIVE_CER_IMPROVEMENT
            and field_improvement >= MINIMUM_FIELD_HIT_IMPROVEMENT
        )
        evaluations.append(
            {
                "engine_identifier": candidate["engine_identifier"],
                "relative_cer_improvement": relative_improvement,
                "field_hit_rate_improvement": field_improvement,
                "thresholds_passed": passed,
            }
        )
    eligible_ids = {
        evaluation["engine_identifier"]
        for evaluation in evaluations
        if evaluation["thresholds_passed"]
    }
    eligible = [
        metric
        for metric in metrics
        if metric["engine_identifier"] in eligible_ids
    ]
    eligible.sort(
        key=lambda metric: (
            metric["cer"],
            -metric["field_hit_rate"],
            metric["p95_latency_ms"],
            metric["engine_identifier"],
        )
    )
    selected = eligible[0] if eligible else vision
    return {
        "selected_engine_identifier": selected["engine_identifier"],
        "switch_engine": selected is not vision,
        "relative_cer_improvement_required": MINIMUM_RELATIVE_CER_IMPROVEMENT,
        "field_hit_rate_improvement_required": MINIMUM_FIELD_HIT_IMPROVEMENT,
        "candidate_evaluations": evaluations,
    }


def calculate(testset: Path, manifest: dict, engines: list[dict]) -> dict:
    samples, by_id = load_private_samples(testset, manifest)
    metrics = [
        score_engine(engine, samples, by_id)
        for engine in engines
    ]
    return {
        "schema_version": 2,
        "protocol": PROTOCOL,
        "sample_count": len(samples),
        "sample_hashes": [
            {
                "image_sha256": sample["image_sha256"],
                "reference_sha256": sample["reference_sha256"],
            }
            for sample in samples
        ],
        "metrics": metrics,
        "decision": decide(metrics),
    }


def render_markdown(payload: dict) -> str:
    lines = [
        "# CareThread OCR 真实照片回归（R 组）",
        "",
        f"- 协议：`{payload['protocol']}`",
        f"- 样本页数：{payload['sample_count']}",
        "- 隐私：仅保留不可逆 SHA-256 与评分，不含文件名、路径、OCR 原文或字段原值。",
        "",
        "| 引擎 | CER | 字段命中 | P95 |",
        "| --- | ---: | ---: | ---: |",
    ]
    for metric in payload["metrics"]:
        lines.append(
            f"| `{metric['engine_identifier']}` | {metric['cer']:.2%} | "
            f"{metric['field_hits']}/{metric['field_total']} "
            f"({metric['field_hit_rate']:.2%}) | "
            f"{metric['p95_latency_ms']:.0f} ms |"
        )
    decision = payload["decision"]
    lines += [
        "",
        "## 重启条件 v2",
        "",
        "- 挑战者相对 Vision 的 CER 改善率必须 ≥50%。",
        "- 挑战者字段命中率必须比 Vision 提升 ≥5 个百分点。",
        "- 两项必须同时通过；无人通过时继续使用 Apple Vision。",
        "",
        f"**唯一结论：`{decision['selected_engine_identifier']}`。**",
        "",
        "## 样本哈希",
        "",
        "| 图片 SHA-256 | 参考文本 SHA-256 |",
        "| --- | --- |",
    ]
    for item in payload["sample_hashes"]:
        lines.append(
            f"| `{item['image_sha256']}` | `{item['reference_sha256']}` |"
        )
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("testset", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output_json", type=Path)
    parser.add_argument("output_markdown", type=Path)
    parser.add_argument("engine_json", nargs="+", type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    engines = [
        json.loads(path.read_text(encoding="utf-8"))
        for path in args.engine_json
    ]
    payload = calculate(args.testset, manifest, engines)
    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    args.output_markdown.write_text(
        render_markdown(payload),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
