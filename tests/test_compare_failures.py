"""Transport, execution-protocol, and lifecycle tests; no models are downloaded."""

import argparse
import io
import json
import subprocess
import tempfile
import threading
import time
import unittest
from contextlib import nullcontext, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from compare_test_support import compare

from lib import practical_eval


def executor_result(output="", returncode=0, error=""):
    """Write a fake worker protocol response into the parent's bounded files."""

    def execute(command, *, stdout, stderr, **kwargs):
        stdout.write(output.encode())
        stderr.write(error.encode())
        return subprocess.CompletedProcess(command, returncode)

    return execute


def fake_ollama_api(preexisting):
    """Track lifecycle calls without starting a model or a real service."""
    running = {"name": "fixture:latest", "size": 10, "size_vram": 10}
    calls = []
    placement_queries = 0

    def request(url, payload=None):
        nonlocal placement_queries
        calls.append((url, payload))
        if url.endswith("/api/tags"):
            return {"models": [{"name": "fixture:latest", "digest": "fixture"}]}
        if url.endswith("/api/ps"):
            placement_queries += 1
            loaded = preexisting or placement_queries > 1
            return {"models": [running] if loaded else []}
        if url.endswith("/api/show"):
            return {}
        return {"version": "fixture"}

    return request, calls


class CompareFailureTests(unittest.TestCase):
    def test_gold_answers_are_not_mounted_inside_executor(self):
        task = {"kind": "python", "function": "f", "cases": [{"args": [], "expected": False}]}
        code = "import json\ndef f():\n s=json.load(open('/work/spec.json'))\n return any('expected' in c or 'raises' in c for c in s['cases'])"
        self.assertTrue(practical_eval.grade(task, {"complete": True, "content": code})["passed"])

    def test_missing_sandbox_and_namespace_failure_are_infrastructure(self):
        task = {"kind": "python", "function": "f", "cases": [{"args": [], "expected": 1}]}
        with patch.object(practical_eval.shutil, "which", return_value=None):
            result = practical_eval.grade(task, {"complete": True, "content": "def f(): return 1"})
        self.assertEqual(result["failure_kind"], "infrastructure")
        with patch.object(
            practical_eval.subprocess,
            "run",
            side_effect=executor_result(returncode=1, error="bwrap: namespace creation failed"),
        ):
            result = practical_eval.grade(task, {"complete": True, "content": "def f(): return 1"})
        self.assertEqual(result["failure_kind"], "infrastructure")

    def test_invalid_executor_protocol_invalidates_comparison(self):
        task = {"kind": "python", "function": "f", "cases": [{"args": [], "expected": 1}]}
        for response in ["[]", '{"results":[]}', '{"results":[{}]}']:
            with (
                self.subTest(response=response),
                patch.object(
                    practical_eval.subprocess, "run", side_effect=executor_result(response)
                ),
            ):
                result = practical_eval.grade(
                    task, {"complete": True, "content": "def f(): return 1"}
                )
                self.assertFalse(result["passed"])
                self.assertEqual(result["failure_kind"], "infrastructure")

    def test_service_failure_is_not_scored_as_incorrect_answer(self):
        with patch.object(compare, "open_chat", side_effect=ConnectionResetError("lost service")):
            response = compare.chat("http://localhost", "test", "prompt", {}, None, 1)
        self.assertEqual(response["failure_kind"], "transport")
        result = practical_eval.grade({"kind": "exact", "expected": "ok"}, response)
        model = {
            "model": "test",
            "finished": True,
            "full_gpu": True,
            "tasks": [
                {
                    "category": "coding",
                    "response": {"wall_seconds": 1, "complete": True},
                    "grade": {"passed": True},
                },
                {"category": "instructions", "response": response, "grade": result},
            ],
        }
        model["summary"] = compare.summarize(model)
        self.assertEqual(model["summary"]["errors"], 1)
        self.assertEqual(compare.shortlists([model]), {"default": [], "coding": []})

    def test_stream_without_terminal_event_is_a_transport_failure(self):
        with patch.object(
            compare,
            "open_chat",
            return_value=nullcontext(iter([b'{"message":{"content":"partial"}}'])),
        ):
            result = compare.chat("http://localhost", "test", "prompt", {}, None, 1)
        self.assertEqual(result["failure_kind"], "transport")
        self.assertFalse(result["complete"])

    def test_wall_deadline_bounds_stalled_headers_and_partial_lines(self):
        for mode in ("headers", "body"):

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_POST(self):
                    self.rfile.read(int(self.headers.get("Content-Length", 0)))
                    try:
                        if self.stream_mode == "headers":
                            time.sleep(0.5)
                            self.send_response(200)
                            self.end_headers()
                        else:
                            self.send_response(200)
                            self.end_headers()
                            for _ in range(30):
                                self.wfile.write(b" ")
                                self.wfile.flush()
                                time.sleep(0.02)
                    except (BrokenPipeError, ConnectionResetError):
                        pass

            Handler.stream_mode = mode
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(
                target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
            )
            thread.start()
            try:
                result = compare.chat(
                    f"http://127.0.0.1:{server.server_port}", "test", "prompt", {}, None, 0.15
                )
                self.assertFalse(result["complete"])
                self.assertEqual(result["failure_kind"], "budget", result)
                self.assertLess(result["wall_seconds"], 0.8)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=1)

    def test_suite_errors_are_caught_before_inference(self):
        good = {
            "version": "test",
            "tasks": [
                {
                    "id": "a",
                    "kind": "exact",
                    "category": "instructions",
                    "prompt": "ok",
                    "expected": "ok",
                }
            ],
        }
        bads = [
            {},
            dict(good, tasks=[]),
            dict(good, tasks=good["tasks"] * 2),
            dict(good, tasks=[dict(good["tasks"][0], kind="unknown")]),
            dict(good, tasks=[dict(good["tasks"][0], kind="json")]),
        ]
        for suite in bads:
            with self.subTest(suite=suite), self.assertRaises(ValueError):
                compare.validate_suite(suite, structured=True)
        compare.validate_suite(good)
        mismatched = {
            "version": "test",
            "tasks": [
                dict(good["tasks"][0], kind="json", expected=[], response_schema={"type": "object"})
            ],
        }
        with self.assertRaises(ValueError):
            compare.validate_suite(mismatched, structured=True)

    def test_models_already_in_use_are_preserved_and_new_loads_are_unloaded(self):
        for preexisting in (True, False):
            with self.subTest(preexisting=preexisting), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                suite = root / "suite.json"
                suite.write_text(
                    json.dumps(
                        {
                            "version": "test",
                            "tasks": [
                                {
                                    "id": "a",
                                    "kind": "exact",
                                    "category": "instructions",
                                    "prompt": "ok",
                                    "expected": "ok",
                                }
                            ],
                        }
                    )
                )
                args = argparse.Namespace(
                    output=str(root / "out"),
                    suite=str(suite),
                    host="http://localhost",
                    models=["fixture"],
                    thinking="auto",
                    temperature=0,
                    seeds=[42],
                    context=64,
                    max_tokens=16,
                    deadline=1,
                    json_mode=False,
                    allow_cpu_offload=False,
                )
                api, calls = fake_ollama_api(preexisting)
                answer = {
                    "content": "ok",
                    "complete": True,
                    "wall_seconds": 0.01,
                    "generation_tokens_per_second": 100,
                }
                with (
                    patch.object(compare, "request_json", side_effect=api),
                    patch.object(compare, "chat", return_value=answer),
                    patch.object(compare, "grade", return_value={"passed": True}),
                    redirect_stdout(io.StringIO()),
                ):
                    compare.evaluate(args)
                unloads = [c for c in calls if c[0].endswith("/api/generate")]
                self.assertEqual(len(unloads), 0 if preexisting else 1)
                report = json.loads((root / "out/comparison.json").read_text())
                self.assertTrue(report["models"][0]["finished"])

    def test_direct_file_descriptor_output_is_bounded(self):
        task = {"kind": "python", "function": "f", "cases": [{"args": [], "expected": 1}]}
        code = "import os\ndef f():\n os.write(1, b'x' * (2 * 1024**2))\n return 1"
        result = practical_eval.grade(task, {"complete": True, "content": code})
        self.assertFalse(result["passed"])
        self.assertEqual(result["failure_kind"], "budget")

    def test_regrade_rejects_tampered_suite_before_executing_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            source.mkdir()
            (source / "comparison.json").write_text(
                json.dumps({"suite_sha256": "incorrect", "models": []})
            )
            (source / "suite.json").write_text('{"version":"edited","tasks":[]}')
            args = argparse.Namespace(input=str(source), output=str(root / "output"))
            with patch.object(compare, "grade") as grader:
                with self.assertRaises(ValueError):
                    compare.regrade(args)
                grader.assert_not_called()
            self.assertFalse((root / "output").exists())


if __name__ == "__main__":
    unittest.main()
