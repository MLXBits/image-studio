"""Tests for scripts/comfy_dry_run.py. Stdlib only: python3 -m unittest discover -s scripts/tests"""

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import comfy_dry_run as cdr  # noqa: E402


def make_template() -> dict:
    return {
        "1": {"class_type": "KSampler", "inputs": {"steps": 20, "cfg": 7.0, "cond": ["2", 0]}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "old prompt"}},
    }


class InjectTests(unittest.TestCase):
    def test_fills_mapped_inputs(self):
        param_map = {
            "prompt": {"node": "2", "input": "text"},
            "steps": {"node": "1", "input": "steps"},
            "cfg": {"node": "1", "input": "cfg"},
        }
        params = {"prompt": "a cat", "steps": 30, "cfg": 5.0}
        graph = cdr.inject(make_template(), param_map, params)
        self.assertEqual(graph["2"]["inputs"]["text"], "a cat")
        self.assertEqual(graph["1"]["inputs"]["steps"], 30)
        self.assertEqual(graph["1"]["inputs"]["cfg"], 5.0)
        self.assertEqual(graph["1"]["inputs"]["cond"], ["2", 0])  # ref input untouched

    def test_throws_on_missing_node(self):
        with self.assertRaises(cdr.ParamMapError):
            cdr.inject(make_template(), {"steps": {"node": "99", "input": "steps"}}, {"steps": 30})

    def test_throws_on_missing_input(self):
        with self.assertRaises(cdr.ParamMapError):
            cdr.inject(make_template(), {"steps": {"node": "1", "input": "nope"}}, {"steps": 30})

    def test_leaves_optional_params(self):
        # 'cfg' is in the param map but absent from params -> template value preserved
        param_map = {"prompt": {"node": "2", "input": "text"}, "cfg": {"node": "1", "input": "cfg"}}
        graph = cdr.inject(make_template(), param_map, {"prompt": "a cat"})
        self.assertEqual(graph["2"]["inputs"]["text"], "a cat")
        self.assertEqual(graph["1"]["inputs"]["cfg"], 7.0)

    def test_does_not_mutate_template(self):
        template = make_template()
        original = copy.deepcopy(template)
        cdr.inject(template, {"prompt": {"node": "2", "input": "text"}}, {"prompt": "a cat"})
        self.assertEqual(template, original)


if __name__ == "__main__":
    unittest.main()
