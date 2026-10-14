# SPDX-License-Identifier: GPL-2.0-or-later
"""Regression cases for missing measurements and invalid corner coverage."""
import copy
import unittest
from timing_corner_gate import CHECKS, evaluate_corner_coverage

class CornerGateTests(unittest.TestCase):
    def setUp(self):
        self.rows = [{"corner": name, "model": "slow", "temperature": temp,
                      "voltage": "1100", "check": check, "worst_slack_ns": "0.170", "paths": "1"}
                     for name, temp in [("warm", "100"), ("cold", "-40")] for check in CHECKS]
        self.conditions = {"warm": 0.396, "cold": 0.396}
    def result(self, rows=None, conditions=None, count=2):
        return evaluate_corner_coverage(self.rows if rows is None else rows,
                                        self.conditions if conditions is None else conditions, count)
    def test_complete_positive(self):
        self.assertTrue(self.result()["all_applicable_corners_qualified"])
    def test_missing_single_check(self):
        result = self.result(self.rows[:-1])
        self.assertFalse(result["all_applicable_corners_qualified"])
        self.assertTrue(result["corner_coverage_errors"])
    def test_duplicate_check(self):
        self.assertFalse(self.result(self.rows + [self.rows[0]])["corner_collection_complete"])
    def test_negative_cold_corner(self):
        rows = copy.deepcopy(self.rows); rows[4]["worst_slack_ns"] = "-0.008"
        result = self.result(rows)
        self.assertTrue(result["corner_collection_complete"])
        self.assertFalse(result["all_applicable_corners_qualified"])
        self.assertEqual(result["all_corner_min_slack_ns"]["setup"], -0.008)
    def test_missing_pulse(self):
        self.assertFalse(self.result(conditions={"warm": 0.396, "cold": None})["corner_collection_complete"])
    def test_wrong_pulse_condition(self):
        self.assertFalse(self.result(conditions={"warm": 0.396, "other": 0.396})["corner_collection_complete"])
    def test_zero_paths_or_nonfinite(self):
        for value, paths in [("NA", "0"), ("nan", "1"), ("inf", "1"), ("0.170", "0")]:
            rows = copy.deepcopy(self.rows); rows[4].update(worst_slack_ns=value, paths=paths)
            self.assertFalse(self.result(rows)["all_applicable_corners_qualified"])
    def test_completion_count_missing_or_wrong(self):
        for count in [None, 0, 1, 3]:
            self.assertFalse(self.result(count=count)["corner_collection_complete"])
    def test_inconsistent_corner_identity(self):
        rows = copy.deepcopy(self.rows); rows[0]["temperature"] = "85"
        self.assertFalse(self.result(rows)["corner_collection_complete"])

if __name__ == "__main__":
    unittest.main()
