"""Objective graders and an isolated executor for the opt-in comparison tool."""

import json
import math
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from .code_worker import MAX_OUTPUT_BYTES, type_shape


def equivalent(actual, expected):
    """Compare JSON-shaped values without confusing booleans with numbers."""
    if isinstance(expected, bool) or expected is None or isinstance(expected, str):
        return type(actual) is type(expected) and actual == expected
    if isinstance(expected, (int, float)):
        return type(actual) in (int, float) and math.isclose(
            actual, expected, rel_tol=1e-9, abs_tol=1e-9
        )
    if isinstance(expected, list):
        return (
            isinstance(actual, list)
            and len(actual) == len(expected)
            and all(equivalent(a, e) for a, e in zip(actual, expected, strict=True))
        )
    if isinstance(expected, dict):
        return (
            isinstance(actual, dict)
            and actual.keys() == expected.keys()
            and all(equivalent(actual[k], expected[k]) for k in expected)
        )
    return False


def strict_json(text):
    """Reject ambiguous keys and non-JSON numeric constants in model output."""

    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON key: " + key)
            result[key] = value
        return result

    def reject_constant(value):
        raise ValueError("Non-JSON numeric constant: " + value)

    return json.loads(text, object_pairs_hook=unique_keys, parse_constant=reject_constant)


def python_code(text):
    """Accept a single Markdown code block or a plain Python response."""
    blocks = re.findall(r"```(?:python|py)?\s*\n(.*?)```", text, re.S)
    if len(blocks) == 1:
        return blocks[0]
    if len(blocks) > 1:
        raise ValueError("Multiple code blocks; expected one complete function")
    return text.strip()


def grade_python(task, text):
    if not shutil.which("bwrap"):
        return {
            "passed": False,
            "failure_kind": "infrastructure",
            "error": "bubblewrap is required; generated code was not executed",
        }
    try:
        code = python_code(text)
    except ValueError as exc:
        return {"passed": False, "error": str(exc)}
    with tempfile.TemporaryDirectory(prefix="model-match-code-") as tmp:
        root = Path(tmp)
        (root / "candidate.py").write_text(code)
        # Gold answers and expected exceptions remain in the parent process.
        inputs = {
            "function": task["function"],
            "cases": [{"args": c["args"]} for c in task["cases"]],
        }
        (root / "spec.json").write_text(json.dumps(inputs))
        shutil.copyfile(Path(__file__).with_name("code_worker.py"), root / "runner.py")
        cmd = [
            "bwrap",
            "--unshare-all",
            "--die-with-parent",
            "--new-session",
            "--cap-drop",
            "ALL",
            "--ro-bind",
            "/usr",
            "/usr",
            "--symlink",
            "usr/lib",
            "/lib",
            "--symlink",
            "usr/lib64",
            "/lib64",
            "--symlink",
            "usr/bin",
            "/bin",
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--tmpfs",
            "/tmp",
            "--ro-bind",
            str(root),
            "/work",
            "--chdir",
            "/tmp",
            "--clearenv",
            "--setenv",
            "PATH",
            "/usr/bin",
            "/usr/bin/python3",
            "-I",
            "-S",
            "/work/runner.py",
        ]
        try:
            # Regular files make the worker's file-size limit effective even for
            # os.write(1, ...), which bypasses Python's redirected stdout.
            with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
                result = subprocess.run(cmd, stdout=stdout, stderr=stderr, timeout=5, check=False)
                stdout.seek(0)
                output = stdout.read(MAX_OUTPUT_BYTES + 1)
                stderr.seek(0)
                error_text = stderr.read(MAX_OUTPUT_BYTES).decode("utf-8", errors="replace")
            if len(output) >= MAX_OUTPUT_BYTES:
                return {
                    "passed": False,
                    "failure_kind": "budget",
                    "error": "Generated code exceeded the output limit",
                }
            if result.returncode:
                return {
                    "passed": False,
                    "error": "Isolated executor failed",
                    "failure_kind": "infrastructure"
                    if error_text.startswith("bwrap:")
                    else ("budget" if result.returncode < 0 else "answer"),
                    "exit_code": result.returncode,
                    "stderr": error_text[:500],
                }
            data = json.loads(output)
        except subprocess.TimeoutExpired:
            return {
                "passed": False,
                "failure_kind": "budget",
                "error": "Generated code exceeded its execution deadline",
            }
        except (OSError, ValueError) as exc:
            return {
                "passed": False,
                "failure_kind": "infrastructure",
                "error": "Execution failed: " + str(exc)[:300],
            }
    if not isinstance(data, dict):
        return {
            "passed": False,
            "failure_kind": "infrastructure",
            "error": "Malformed executor response",
        }
    if "error" in data:
        return {"passed": False, "failure_kind": "answer", "error": data["error"]}
    if not isinstance(data.get("results"), list) or len(data["results"]) != len(task["cases"]):
        return {
            "passed": False,
            "failure_kind": "infrastructure",
            "error": "Incomplete executor response",
        }
    cases = []
    for case, observed in zip(task["cases"], data["results"], strict=True):
        if not isinstance(observed, dict) or type(observed.get("mutated")) is not bool:
            return {
                "passed": False,
                "failure_kind": "infrastructure",
                "error": "Malformed executor case response",
            }
        if "raises" in case:
            passed = observed.get("exception") == case["raises"]
        else:
            passed = (
                "exception" not in observed
                and observed.get("type_shape") == type_shape(case["expected"])
                and equivalent(observed.get("actual"), case["expected"])
            )
        cases.append(
            {
                "passed": passed and not observed["mutated"],
                "observed": observed,
                "expected": case.get("expected"),
                "raises": case.get("raises"),
            }
        )
    return {
        "passed": len(cases) == len(task["cases"]) and all(c["passed"] for c in cases),
        "cases_passed": sum(c["passed"] for c in cases),
        "cases_total": len(task["cases"]),
        "cases": cases,
    }


def grade(task, response):
    if not response.get("complete"):
        result = {
            "passed": False,
            "error": response.get("error") or "Response did not complete normally",
        }
        result["failure_kind"] = response.get("failure_kind", "budget")
        if task["kind"] == "python":
            result.update(cases_passed=0, cases_total=len(task["cases"]))
        return result
    text = response.get("content", "")
    if task["kind"] == "python":
        result = grade_python(task, text)
        result.setdefault("cases_passed", 0)
        result.setdefault("cases_total", len(task["cases"]))
        return result
    if task["kind"] == "json":
        try:
            actual = strict_json(text)
        except ValueError:
            fenced = re.findall(r"```(?:json)?\s*\n(.*?)\n```", text, re.S)
            if len(fenced) == 1:
                try:
                    actual = strict_json(fenced[0])
                    return {
                        "passed": False,
                        "format_valid": False,
                        "semantic_passed": equivalent(actual, task["expected"]),
                        "actual": actual,
                        "expected": task["expected"],
                        "error": "Extra Markdown or prose despite JSON-only request",
                    }
                except ValueError:
                    pass
            return {
                "passed": False,
                "semantic_passed": False,
                "format_valid": False,
                "error": "Expected only valid JSON",
            }
        passed = equivalent(actual, task["expected"])
        return {
            "passed": passed,
            "semantic_passed": passed,
            "format_valid": True,
            "actual": actual,
            "expected": task["expected"],
        }
    return {"passed": text.strip() == task["expected"], "expected": task["expected"]}
