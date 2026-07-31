#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("score_real.py")
SPEC = importlib.util.spec_from_file_location("score_real", MODULE_PATH)
score_real = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(score_real)


class RealScoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.testset = Path(self.temporary.name)
        (self.testset / "images").mkdir()
        (self.testset / "references").mkdir()
        for identifier in ("r001", "r002"):
            (self.testset / f"images/{identifier}.txt").write_bytes(b"fictional-image")
        (self.testset / "references/r001.txt").write_text("印" * 100, encoding="utf-8")
        (self.testset / "references/r002.txt").write_text("手" * 20, encoding="utf-8")
        self.manifest = {
            "schema_version": 2,
            "samples": [
                {
                    "id": "r001",
                    "group": "R",
                    "subgroup": "real",
                    "document_style": "print",
                    "image": "images/r001.txt",
                    "reference": "references/r001.txt",
                    "scored": True,
                    "expected": {"type": "lab", "date": "2026-07-31"},
                },
                {
                    "id": "r002",
                    "group": "R",
                    "subgroup": "real",
                    "document_style": "handwriting",
                    "image": "images/r002.txt",
                    "reference": "references/r002.txt",
                    "scored": True,
                    "expected": {"hospital": "虚构医院", "indicator": "1.0"},
                }
            ],
        }

    def tearDown(self):
        self.temporary.cleanup()

    def engine(self, identifier, printed, handwritten, field_hits):
        return {
            "engine_identifier": identifier,
            "rows": [
                {
                    "id": "r001",
                    "text": printed,
                    "field_hit_count": field_hits,
                    "field_total_count": 2,
                    "latency_ms": [100.0, 120.0, 110.0],
                },
                {
                    "id": "r002",
                    "text": handwritten,
                    "field_hit_count": field_hits,
                    "field_total_count": 2,
                    "latency_ms": [130.0, 150.0, 140.0],
                }
            ],
        }

    def decision(
        self,
        vision_print,
        vision_handwriting,
        candidate_print,
        candidate_handwriting,
        vision_fields=1,
        candidate_fields=2,
    ):
        payload = score_real.calculate(
            self.testset,
            self.manifest,
            [
                self.engine(
                    "apple-vision", vision_print, vision_handwriting, vision_fields
                ),
                self.engine(
                    "candidate", candidate_print, candidate_handwriting, candidate_fields
                ),
            ],
        )
        return payload["decision"], payload

    def test_exact_thresholds_pass(self):
        self.manifest["samples"][1]["reference_normalized"] = "手" * 30
        decision, _ = self.decision(
            "印" * 100,
            "手" * 21,  # 30% CER
            "印" * 99,  # exactly 1 percentage point print degradation
            "手" * 24,  # 20% CER; 0.3 - 0.2 has binary float representation error
        )
        self.assertTrue(decision["switch_engine"])
        self.assertEqual(decision["selected_engine_identifier"], "candidate")

    def test_print_degradation_over_one_point_does_not_pass(self):
        decision, _ = self.decision(
            "印" * 100,
            "手" * 16,
            "印" * 98,
            "手" * 18,
        )
        self.assertFalse(decision["switch_engine"])

    def test_handwriting_improvement_under_ten_points_does_not_pass(self):
        decision, _ = self.decision(
            "印" * 100,
            "手" * 16,
            "印" * 100,
            "手" * 17,
        )
        self.assertFalse(decision["switch_engine"])

    def test_field_improvement_does_not_replace_fixed_cer_gates(self):
        decision, _ = self.decision(
            "印" * 100,
            "手" * 20,
            "印" * 100,
            "手" * 20,
            vision_fields=0,
            candidate_fields=2,
        )
        self.assertFalse(decision["switch_engine"])

    def test_sanitized_payload_contains_no_readable_fixture_or_local_paths(self):
        _, payload = self.decision(
            "印" * 100,
            "手" * 16,
            "印" * 99,
            "手" * 18,
        )
        serialized = json.dumps(payload, ensure_ascii=False)
        self.assertNotIn("印印印", serialized)
        self.assertNotIn("手手手", serialized)
        self.assertNotIn(str(self.testset), serialized)
        self.assertNotIn('"text"', serialized)
        self.assertNotIn('"extraction"', serialized)
        self.assertNotIn('"id": "r001"', serialized)
        self.assertIn('"image_sha256"', serialized)
        self.assertIn('"reference_sha256"', serialized)

    def test_missing_optional_fields_use_the_scored_row_denominator(self):
        _, payload = self.decision(
            "印" * 100,
            "手" * 16,
            "印" * 99,
            "手" * 18,
        )
        vision = payload["metrics"][0]
        self.assertEqual(vision["field_total"], 4)
        self.assertEqual(vision["field_hits"], 2)
        self.assertEqual(vision["style_metrics"]["print"]["field_total"], 2)
        self.assertEqual(vision["style_metrics"]["handwriting"]["field_total"], 2)

    def test_manifest_requires_both_document_styles(self):
        self.manifest["samples"] = self.manifest["samples"][:1]
        with self.assertRaisesRegex(ValueError, "handwriting"):
            score_real.calculate(
                self.testset,
                self.manifest,
                [
                    {
                        "engine_identifier": "apple-vision",
                        "rows": [
                            {
                                "id": "r001",
                                "text": "印" * 100,
                                "field_hit_count": 2,
                                "field_total_count": 2,
                                "latency_ms": [100.0],
                            }
                        ],
                    }
                ],
            )

    def test_cross_engine_field_denominator_must_match_manifest(self):
        baseline = self.engine("apple-vision", "印" * 100, "手" * 20, 2)
        corrupt = self.engine("candidate", "印" * 100, "手" * 20, 2)
        corrupt["rows"][1]["field_total_count"] = 3
        with self.assertRaisesRegex(ValueError, "denominator"):
            score_real.calculate(self.testset, self.manifest, [baseline, corrupt])

    def test_zero_field_page_and_variable_denominators_are_aggregated(self):
        self.manifest["samples"][0]["expected"] = {}
        engine = self.engine("apple-vision", "印" * 100, "手" * 20, 1)
        engine["rows"][0]["field_hit_count"] = 0
        engine["rows"][0]["field_total_count"] = 0
        payload = score_real.calculate(self.testset, self.manifest, [engine])
        metric = payload["metrics"][0]
        self.assertEqual(metric["field_hits"], 1)
        self.assertEqual(metric["field_total"], 2)
        self.assertEqual(metric["style_metrics"]["print"]["field_total"], 0)
        self.assertEqual(metric["style_metrics"]["print"]["field_hit_rate"], 0.0)
        self.assertEqual(metric["style_metrics"]["handwriting"]["field_total"], 2)

    def test_duplicate_engine_row_id_is_rejected(self):
        engine = self.engine("apple-vision", "印" * 100, "手" * 20, 2)
        engine["rows"].append(dict(engine["rows"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            score_real.calculate(self.testset, self.manifest, [engine])

    def test_duplicate_engine_identifier_is_rejected(self):
        first = self.engine("apple-vision", "印" * 100, "手" * 20, 2)
        second = self.engine("apple-vision", "印" * 100, "手" * 20, 2)
        with self.assertRaisesRegex(ValueError, "unique"):
            score_real.calculate(self.testset, self.manifest, [first, second])


if __name__ == "__main__":
    unittest.main()
