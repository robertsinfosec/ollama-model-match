"""Run with python3 -m unittest discover -s tests -p 'test_*.py' -v."""

import json
import unittest
from contextlib import nullcontext
from unittest.mock import patch

from compare_test_support import ROOT, compare

from lib.practical_eval import equivalent, grade, grade_python


class PracticalCompareTests(unittest.TestCase):
    def test_thinking_only_model_cannot_be_silently_disabled(self):
        show = {"thinking": {"values": [True], "default": True}}
        self.assertTrue(compare.choose_thinking(show, "auto"))
        with self.assertRaises(ValueError):
            compare.choose_thinking(show, "off")
        self.assertFalse(
            compare.choose_thinking(
                {"thinking": {"values": [False, True], "default": True}}, "auto"
            )
        )
        self.assertIsNone(compare.choose_thinking({}, "auto"))
        self.assertIsNone(compare.choose_thinking({"thinking": None}, "auto"))
        with self.assertRaises(ValueError):
            compare.choose_thinking({}, "on")

    def test_json_types_and_extra_fields(self):
        self.assertFalse(equivalent(True, 1))
        self.assertFalse(equivalent({"x": 1, "y": 2}, {"x": 1}))
        self.assertTrue(equivalent(77.76000000001, 77.76))
        self.assertFalse(equivalent(float("nan"), 77.76))
        self.assertFalse(equivalent(741, "00741"))

    def test_incomplete_correct_answer_never_passes(self):
        self.assertFalse(
            grade(
                {"kind": "json", "expected": {"x": 1}}, {"complete": False, "content": '{"x":1}'}
            )["passed"]
        )

    def test_stream_metrics_separate_thinking_prompt_and_generation(self):
        chunks = [
            {"message": {"thinking": "working"}},
            {"message": {"content": "answer"}},
            {
                "done": True,
                "done_reason": "stop",
                "eval_count": 200,
                "prompt_eval_count": 999,
                "eval_duration": 2_000_000_000,
            },
        ]
        lines = iter(json.dumps(c).encode() for c in chunks)
        with (
            patch.object(compare, "open_chat", return_value=nullcontext(lines)) as call,
            patch.object(compare.time, "monotonic", side_effect=[0, 0.1, 0.2, 0.3, 0.4]),
        ):
            result = compare.chat(
                "http://localhost",
                "test",
                "question",
                {},
                False,
                30,
                response_schema={"type": "object"},
            )
        self.assertEqual(result["first_token_seconds"], 0.1)
        self.assertEqual(result["first_answer_seconds"], 0.2)
        self.assertEqual(result["generation_tokens_per_second"], 100)
        self.assertTrue(result["complete"])
        self.assertEqual(json.loads(call.call_args.args[0].data)["format"], {"type": "object"})

    def test_token_limit_is_not_a_complete_answer(self):
        chunks = iter([b'{"done":true,"done_reason":"length","message":{"content":"partial"}}'])
        with patch.object(compare, "open_chat", return_value=nullcontext(chunks)):
            result = compare.chat("http://localhost", "test", "question", {}, None, 30)
        self.assertFalse(result["complete"])

    def test_array_task_sends_array_schema_instead_of_json_object_mode(self):
        chunks = iter([b'{"done":true,"done_reason":"stop","message":{"content":"[]"}}'])
        schema = {"type": "array", "items": {}}
        with patch.object(compare, "open_chat", return_value=nullcontext(chunks)) as call:
            result = compare.chat(
                "http://localhost", "test", "question", {}, None, 30, response_schema=schema
            )
        self.assertEqual(json.loads(call.call_args.args[0].data)["format"], schema)
        self.assertTrue(result["complete"])

    def test_strict_format_does_not_accept_explanation(self):
        task = {"kind": "json", "expected": {"x": 1}}
        self.assertFalse(grade(task, {"complete": True, "content": 'Here: {"x":1}'})["passed"])
        self.assertTrue(grade(task, {"complete": True, "content": '{"x":1}'})["passed"])
        fenced = grade(task, {"complete": True, "content": '```json\n{"x":1}\n```'})
        self.assertFalse(fenced["passed"])
        self.assertTrue(fenced["semantic_passed"])
        prose = grade(
            task, {"complete": True, "content": 'Here is the result:\n```json\n{"x":1}\n```'}
        )
        self.assertFalse(prose["passed"])
        self.assertTrue(prose["semantic_passed"])

    def test_known_solutions_pass_all_coding_checks(self):
        gold_source = (ROOT / "tests/fixtures/gold_solutions.py").read_text()
        suite = json.loads((ROOT / "src/evals/practical-v1.json").read_text())
        for task in suite["tasks"]:
            if task["kind"] == "python":
                with self.subTest(task=task["id"]):
                    result = grade_python(task, gold_source)
                    self.assertTrue(result["passed"], result)

    def test_input_mutation_is_a_failure(self):
        task = {"function": "f", "cases": [{"args": [[2, 1]], "expected": [1, 2]}]}
        result = grade_python(task, "def f(xs):\n xs.sort()\n return xs")
        self.assertFalse(result["passed"])
        self.assertTrue(result["cases"][0]["observed"]["mutated"])

    def test_tuple_is_not_accepted_as_requested_list(self):
        task = {"function": "f", "cases": [{"args": [], "expected": [[1, 2]]}]}
        result = grade_python(task, "def f():\n return [(1,2)]")
        self.assertFalse(result["passed"])

    def test_syntax_failure_counts_all_expected_checks_as_failed(self):
        task = {"kind": "python", "function": "f", "cases": [{"args": [], "expected": 1}]}
        result = grade(task, {"complete": True, "content": "def broken syntax"})
        self.assertFalse(result["passed"])
        self.assertEqual((result["cases_passed"], result["cases_total"]), (0, 1))

    def test_gold_holdout_coding_solutions(self):
        gold_source = (ROOT / "tests/fixtures/gold_solutions.py").read_text()
        suite = json.loads((ROOT / "src/evals/holdout-v1.json").read_text())
        for task in suite["tasks"]:
            if task["kind"] == "python":
                with self.subTest(task=task["id"]):
                    self.assertTrue(grade_python(task, gold_source)["passed"])

    def test_executor_has_no_home_or_network(self):
        task = {"function": "f", "cases": [{"args": [], "expected": [False, False]}]}
        code = """import os,socket
def f():
    home=os.path.exists('/home')
    try:
        socket.create_connection(('1.1.1.1',53),timeout=.1)
        network=True
    except OSError:
        network=False
    return [home,network]
"""
        self.assertTrue(grade_python(task, code)["passed"])

    def test_runaway_code_is_stopped(self):
        task = {"function": "f", "cases": [{"args": [], "expected": 1}]}
        self.assertFalse(grade_python(task, "def f():\n while True: pass")["passed"])

    def test_empty_summary_has_no_fake_latency(self):
        summary = compare.summarize({"tasks": []})
        self.assertIsNone(summary["median_seconds"])
        self.assertEqual(summary["total"], 0)

    def test_partial_run_cannot_be_recommended(self):
        model = {
            "model": "test",
            "full_gpu": True,
            "tasks": [
                {
                    "id": str(i),
                    "category": "coding",
                    "response": {"wall_seconds": 1, "complete": True},
                    "grade": {"passed": True},
                }
                for i in range(3)
            ],
        }
        model["summary"] = compare.summarize(model)
        self.assertEqual(compare.shortlists([model]), {"default": [], "coding": []})
        model["finished"] = True
        self.assertEqual(compare.shortlists([model])["coding"], ["test"])

    def test_repeating_one_problem_does_not_supply_task_coverage(self):
        model = {
            "model": "test",
            "full_gpu": True,
            "finished": True,
            "tasks": [
                {
                    "id": "same",
                    "category": "coding",
                    "seed": i,
                    "response": {"wall_seconds": 1, "complete": True},
                    "grade": {"passed": True},
                }
                for i in range(20)
            ],
        }
        model["summary"] = compare.summarize(model)
        self.assertEqual(compare.shortlists([model]), {"default": [], "coding": []})

    def test_json_with_duplicate_keys_or_nonfinite_numbers_is_rejected(self):
        task = {"kind": "json", "expected": {"status": "ok"}}
        for content in ['{"status":"wrong","status":"ok"}', '{"status":"ok","extra":NaN}']:
            with self.subTest(content=content):
                result = grade(task, {"complete": True, "content": content})
                self.assertFalse(result["passed"])
                self.assertFalse(result["format_valid"])

    def test_missing_or_invalid_generation_metrics_are_not_reported_as_zero(self):
        for metrics in [
            {},
            {"eval_count": 10, "eval_duration": -1},
            {"eval_count": True, "eval_duration": 100},
        ]:
            chunk = {"done": True, "done_reason": "stop", "message": {"content": "ok"}, **metrics}
            with (
                self.subTest(metrics=metrics),
                patch.object(
                    compare,
                    "open_chat",
                    return_value=nullcontext(iter([json.dumps(chunk).encode()])),
                ),
            ):
                result = compare.chat("http://localhost", "test", "prompt", {}, None, 1)
                self.assertTrue(result["complete"])
                self.assertIsNone(result["generation_tokens_per_second"])


if __name__ == "__main__":
    unittest.main()
