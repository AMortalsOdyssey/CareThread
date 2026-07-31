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
        (self.testset / "images/r001.txt").write_bytes(b"fictional-image")
        (self.testset / "references/r001.txt").write_text(
            "虚构检查结果正常",
            encoding="utf-8",
        )
        self.manifest = {
            "schema_version": 2,
            "samples": [
                {
                    "id": "r001",
                    "group": "R",
                    "subgroup": "real",
                    "image": "images/r001.txt",
                    "reference": "references/r001.txt",
                    "scored": True,
                    "expected": {"type": "lab", "date": "2026-07-31"},
                }
            ],
        }

    def tearDown(self):
        self.temporary.cleanup()

    def engine(self, identifier, recognized, field_hits):
        return {
            "engine_identifier": identifier,
            "rows": [
                {
                    "id": "r001",
                    "text": recognized,
                    "field_hit_count": field_hits,
                    "field_total_count": 2,
                    "latency_ms": [100.0, 120.0, 110.0],
                }
            ],
        }

    def decision(self, vision_text, vision_fields, candidate_text, candidate_fields):
        payload = score_real.calculate(
            self.testset,
            self.manifest,
            [
                self.engine("apple-vision", vision_text, vision_fields),
                self.engine("candidate", candidate_text, candidate_fields),
            ],
        )
        return payload["decision"], payload

    def test_exact_thresholds_pass(self):
        decision, _ = self.decision(
            "虚构检查结果",  # two edits out of eight
            1,
            "虚构检查结果正",  # one edit: exactly 50% relative improvement
            2,  # +50 pp, safely above the 5 pp boundary
        )
        self.assertTrue(decision["switch_engine"])
        self.assertEqual(decision["selected_engine_identifier"], "candidate")

    def test_only_cer_threshold_does_not_pass(self):
        decision, _ = self.decision(
            "虚构检查结果",
            2,
            "虚构检查结果正",
            2,
        )
        self.assertFalse(decision["switch_engine"])

    def test_only_field_threshold_does_not_pass(self):
        decision, _ = self.decision(
            "虚构检查结果",
            1,
            "虚构检查",
            2,
        )
        self.assertFalse(decision["switch_engine"])

    def test_zero_vision_cer_does_not_divide_or_switch(self):
        decision, _ = self.decision(
            "虚构检查结果正常",
            1,
            "虚构检查结果正常",
            2,
        )
        self.assertFalse(decision["switch_engine"])
        self.assertEqual(
            decision["candidate_evaluations"][0]["relative_cer_improvement"],
            0.0,
        )

    def test_sanitized_payload_contains_no_readable_fixture_or_local_paths(self):
        _, payload = self.decision(
            "虚构检查结果",
            1,
            "虚构检查结果正",
            2,
        )
        serialized = json.dumps(payload, ensure_ascii=False)
        self.assertNotIn("虚构检查", serialized)
        self.assertNotIn(str(self.testset), serialized)
        self.assertNotIn('"text"', serialized)
        self.assertNotIn('"extraction"', serialized)
        self.assertNotIn('"id": "r001"', serialized)
        self.assertIn('"image_sha256"', serialized)
        self.assertIn('"reference_sha256"', serialized)

    def test_missing_optional_fields_use_the_scored_row_denominator(self):
        _, payload = self.decision(
            "虚构检查结果",
            1,
            "虚构检查结果正",
            2,
        )
        vision = payload["metrics"][0]
        self.assertEqual(vision["field_total"], 2)
        self.assertEqual(vision["field_hits"], 1)


if __name__ == "__main__":
    unittest.main()
