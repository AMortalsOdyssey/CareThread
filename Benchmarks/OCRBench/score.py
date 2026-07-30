#!/usr/bin/env python3
"""Calculate fixed-protocol OCR metrics and the §5 weighted decision score."""

from __future__ import annotations

import argparse
import json
import math
import unicodedata
from pathlib import Path


ENGINE_FACTS = {
    "apple-vision": {
        "integration_risk_points": 10.0,
        "maintenance_points": 3.0,
        "integration_label": "Apple official iOS API",
    },
    "rapidocr-ppocrv5-mobile": {
        "integration_risk_points": 7.0,
        "maintenance_points": 3.0,
        "integration_label": "mature ONNX models + official ONNX Runtime iOS path",
    },
}


def normalize(text: str) -> str:
    return "".join(
        character
        for character in unicodedata.normalize("NFKC", text)
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
                    previous[column_index - 1] + (left_character != right_character),
                )
            )
        previous = current
    return previous[-1]


def percentile_95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def engine_metrics(engine: dict, manifest: dict) -> dict:
    samples = {sample["id"]: sample for sample in manifest["samples"]}
    page_metrics = []
    for row in engine["rows"]:
        sample = samples[row["id"]]
        reference = sample["reference_normalized"]
        recognized = normalize(row["text"])
        errors = edit_distance(reference, recognized)
        page_metrics.append(
            {
                "id": row["id"],
                "group": row["group"],
                "subgroup": row["subgroup"],
                "scored": row["scored"],
                "reference_characters": len(reference),
                "edit_distance": errors,
                "cer": errors / len(reference) if reference else 0.0,
                "field_hit_count": row.get("field_hit_count", 0),
                "field_hits": row.get("field_hits", {}),
                "latency_ms": row["latency_ms"],
            }
        )

    def aggregate_cer(subgroup: str) -> float:
        selected = [
            page
            for page in page_metrics
            if page["scored"] and page["subgroup"] == subgroup
        ]
        return sum(page["edit_distance"] for page in selected) / sum(
            page["reference_characters"] for page in selected
        )

    scored = [page for page in page_metrics if page["scored"]]
    latencies = [value for page in scored for value in page["latency_ms"]]
    field_hits = sum(page["field_hit_count"] for page in scored)
    field_total = len(scored) * 4
    return {
        "engine": engine["engine"],
        "engine_identifier": engine["engine_identifier"],
        "platform": engine["platform"],
        "print_cer": aggregate_cer("print"),
        "handwriting_cer": aggregate_cer("handwriting"),
        "field_hit_rate": field_hits / field_total,
        "field_hits": field_hits,
        "field_total": field_total,
        "p95_latency_ms": percentile_95(latencies),
        "mean_latency_ms": sum(latencies) / len(latencies),
        "package_increment_bytes": engine.get("estimated_arm64_increment_bytes", 0),
        "peak_memory_increment_bytes": engine.get("peak_rss_increment_bytes", 0),
        "page_metrics": page_metrics,
    }


def normalized_points(values: dict[str, float], weight: float, lower_is_better: bool) -> dict[str, float]:
    minimum = min(values.values())
    maximum = max(values.values())
    if math.isclose(minimum, maximum):
        return {key: weight for key in values}
    if lower_is_better:
        return {
            key: weight * (maximum - value) / (maximum - minimum)
            for key, value in values.items()
        }
    return {
        key: weight * (value - minimum) / (maximum - minimum)
        for key, value in values.items()
    }


def score(metrics: list[dict]) -> None:
    handwriting = normalized_points(
        {item["engine_identifier"]: item["handwriting_cer"] for item in metrics},
        35,
        True,
    )
    printing = normalized_points(
        {item["engine_identifier"]: item["print_cer"] for item in metrics},
        25,
        True,
    )
    fields = normalized_points(
        {item["engine_identifier"]: item["field_hit_rate"] for item in metrics},
        15,
        False,
    )
    for item in metrics:
        identifier = item["engine_identifier"]
        facts = ENGINE_FACTS[identifier]
        latency_seconds = item["p95_latency_ms"] / 1_000
        latency_points = max(0.0, 8.0 - max(0.0, latency_seconds - 2.0) * 2.0)
        package_mb = item["package_increment_bytes"] / 1_048_576
        package_points = max(0.0, 4.0 - max(0.0, package_mb - 15.0) / 15.0)
        components = {
            "handwriting_cer": handwriting[identifier],
            "print_cer": printing[identifier],
            "field_hit_rate": fields[identifier],
            "integration_risk": facts["integration_risk_points"],
            "p95_latency": latency_points,
            "package_increment": package_points,
            "maintenance": facts["maintenance_points"],
        }
        item["score_components"] = components
        item["total_score"] = sum(components.values())
        item["integration_label"] = facts["integration_label"]


def render_markdown(metrics: list[dict], decision: dict) -> str:
    lines = [
        "# CareThread OCR Benchmark Results",
        "",
        "Generated from 30 scored fictional samples (P=6, H=16, D=8) plus one",
        "observation-only fictional invoice. CER uses Unicode NFKC and ignores",
        "whitespace/line-break differences. Field hits are produced by the shipping",
        "`ExtractionEngine` for date, hospital, type, and one key indicator per page.",
        "",
        "## Raw metrics",
        "",
        "| Engine | Print CER | Handwriting CER | Field hits | P95 macOS | P95 simulator | Peak memory Δ | arm64 size Δ |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for item in metrics:
        simulator_value = (
            f"{item['simulator_p95_latency_ms']:.0f} ms"
            if "simulator_p95_latency_ms" in item
            else "not integrated"
        )
        lines.append(
            f"| {item['engine']} | {item['print_cer']:.2%} | "
            f"{item['handwriting_cer']:.2%} | "
            f"{item['field_hits']}/{item['field_total']} ({item['field_hit_rate']:.2%}) | "
            f"{item['p95_latency_ms']:.0f} ms | "
            f"{simulator_value} | "
            f"{item['peak_memory_increment_bytes'] / 1_048_576:.1f} MB | "
            f"{item['package_increment_bytes'] / 1_048_576:.1f} MB |"
        )
    lines += [
        "",
        "## §5 weighted score",
        "",
        "| Engine | H CER /35 | P CER /25 | Fields /15 | Risk /10 | Latency /8 | Size /4 | Active /3 | Total |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for item in sorted(metrics, key=lambda value: value["total_score"], reverse=True):
        component = item["score_components"]
        lines.append(
            f"| {item['engine']} | {component['handwriting_cer']:.2f} | "
            f"{component['print_cer']:.2f} | {component['field_hit_rate']:.2f} | "
            f"{component['integration_risk']:.2f} | {component['p95_latency']:.2f} | "
            f"{component['package_increment']:.2f} | {component['maintenance']:.2f} | "
            f"**{item['total_score']:.2f}** |"
        )
    lines += [
        "",
        "Min–max normalization is applied only to the three dimensions whose rule",
        "says “best = full points, linear decrease”; ties receive full points.",
        "",
        "## Fixed-rule decision",
        "",
        f"**{decision['conclusion']}**",
        "",
        f"- Weighted-score winner: {decision['score_winner']}.",
        f"- Handwriting CER improvement over Vision: {decision['handwriting_improvement_percentage_points']:.2f} percentage points (required ≥10.00).",
        f"- Print CER change versus Vision: {decision['print_cer_change_percentage_points']:+.2f} percentage points (must not be worse by >1.00).",
        f"- Switch thresholds passed: {'yes' if decision['switch_thresholds_passed'] else 'no'}.",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output_json", type=Path)
    parser.add_argument("output_markdown", type=Path)
    parser.add_argument("--simulator-json", type=Path)
    parser.add_argument("engine_json", nargs="+", type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    metrics = [
        engine_metrics(json.loads(path.read_text(encoding="utf-8")), manifest)
        for path in args.engine_json
    ]
    if args.simulator_json:
        simulator = json.loads(args.simulator_json.read_text(encoding="utf-8"))
        for item in metrics:
            if item["engine_identifier"] == simulator["engine_identifier"]:
                item["simulator_p95_latency_ms"] = simulator["p95_latency_ms"]
    score(metrics)
    ranked = sorted(metrics, key=lambda value: value["total_score"], reverse=True)
    winner = ranked[0]
    vision = next(item for item in metrics if item["engine_identifier"] == "apple-vision")
    handwriting_improvement = (
        vision["handwriting_cer"] - winner["handwriting_cer"]
    ) * 100
    print_change = (winner["print_cer"] - vision["print_cer"]) * 100
    thresholds_passed = (
        winner["engine_identifier"] == "apple-vision"
        or (handwriting_improvement >= 10.0 and print_change <= 1.0)
    )
    selected = winner if thresholds_passed else vision
    decision = {
        "score_winner": winner["engine"],
        "selected_engine": selected["engine"],
        "selected_engine_identifier": selected["engine_identifier"],
        "handwriting_improvement_percentage_points": handwriting_improvement,
        "print_cer_change_percentage_points": print_change,
        "switch_thresholds_passed": thresholds_passed,
        "conclusion": (
            "Maintain Apple Vision as the single shipping OCR engine."
            if selected["engine_identifier"] == "apple-vision"
            else f"Switch the shipping OCR engine to {selected['engine']}."
        ),
    }
    payload = {
        "schema_version": 1,
        "score_formula": "OCR task §5; min-max for comparative dimensions",
        "metrics": metrics,
        "decision": decision,
    }
    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    args.output_markdown.write_text(
        render_markdown(metrics, decision),
        encoding="utf-8",
    )
    print(args.output_markdown)


if __name__ == "__main__":
    main()
