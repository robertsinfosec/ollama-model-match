#!/usr/bin/env python3
"""Opt-in, non-promoting practical model comparison (stdlib only)."""

import argparse
import hashlib
import http.client
import json
import math
import socket
import statistics
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from lib.practical_eval import grade

HERE = Path(__file__).resolve().parent
MIN_DISTINCT_TASKS = {"coding": 3, "instructions": 3, "reasoning": 3}


def canonical_model_name(name):
    """Ollama displays an omitted model tag as :latest."""
    return name if ":" in name.rsplit("/", 1)[-1] else name + ":latest"


def request_json(url, payload=None, timeout=30):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "ollama-model-match-experiment/1",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


@contextmanager
def open_chat(request, timeout):
    """Bound the entire local request, including stalled headers or partial lines."""
    url = urllib.parse.urlsplit(request.full_url)
    connection_type = (
        http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    )
    connection = connection_type(url.hostname, url.port, timeout=timeout)
    expired = threading.Event()
    connected_socket = []

    def interrupt():
        expired.set()
        sock = connected_socket[0] if connected_socket else connection.sock
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    watchdog = threading.Timer(timeout, interrupt)
    watchdog.daemon = True
    watchdog.start()
    try:
        connection.connect()
        connected_socket.append(connection.sock)
        if expired.is_set():
            raise TimeoutError("Response deadline exceeded")
        path = urllib.parse.urlunsplit(("", "", url.path, url.query, "")) or "/"
        connection.request("POST", path, body=request.data, headers=dict(request.header_items()))
        response = connection.getresponse()
        if response.status >= 400:
            raise urllib.error.HTTPError(
                request.full_url, response.status, response.reason, response.headers, None
            )
        yield response
        if expired.is_set():
            raise TimeoutError("Response deadline exceeded")
    except (OSError, http.client.HTTPException):
        if expired.is_set():
            raise TimeoutError("Response deadline exceeded") from None
        raise
    finally:
        watchdog.cancel()
        connection.close()


def chat(host, model, prompt, options, think, deadline_seconds, response_schema=None):
    start = time.monotonic()
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "options": options,
        "keep_alive": "5m",
    }
    if think is not None:
        payload["think"] = think
    if response_schema is not None:
        if not isinstance(response_schema, dict):
            raise ValueError("Structured output needs an explicit schema")
        payload["format"] = response_schema
    req = urllib.request.Request(
        host + "/api/chat",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    result = {
        "content": "",
        "thinking": "",
        "complete": False,
        "first_answer_seconds": None,
        "first_token_seconds": None,
    }
    try:
        with open_chat(req, timeout=deadline_seconds) as response:
            for line in response:
                elapsed = time.monotonic() - start
                if elapsed > deadline_seconds:
                    raise TimeoutError("Per-request response deadline exceeded")
                chunk = json.loads(line)
                if "error" in chunk:
                    raise ValueError(chunk["error"])
                message = chunk.get("message", {})
                if (message.get("content") or message.get("thinking")) and result[
                    "first_token_seconds"
                ] is None:
                    result["first_token_seconds"] = elapsed
                if message.get("content", "").strip() and result["first_answer_seconds"] is None:
                    result["first_answer_seconds"] = elapsed
                result["content"] += message.get("content", "")
                result["thinking"] += message.get("thinking", "")
                if chunk.get("done"):
                    result["metrics"] = {k: v for k, v in chunk.items() if k != "message"}
                    result["complete"] = chunk.get("done_reason") == "stop"
                    break
    except TimeoutError as exc:
        result["failure_kind"] = "budget"
        result["error"] = str(exc)
    except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError) as exc:
        result["failure_kind"] = "transport"
        result["error"] = str(exc)
    result["wall_seconds"] = time.monotonic() - start
    metrics = result.get("metrics", {})
    if not result["complete"] and "failure_kind" not in result:
        result["failure_kind"] = "budget" if metrics.get("done_reason") == "length" else "transport"
        result.setdefault(
            "error",
            "Generation budget reached" if metrics else "Stream ended without a terminal response",
        )
    duration = metrics.get("eval_duration")
    count = metrics.get("eval_count")
    valid_metrics = type(duration) is int and duration > 0 and type(count) is int and count >= 0
    result["generation_tokens_per_second"] = count / (duration / 1e9) if valid_metrics else None
    return result


def choose_thinking(show, requested):
    values = (show.get("thinking") or {}).get("values", [])
    if not values:
        if requested == "on":
            raise ValueError("The model does not advertise a supported thinking control")
        return None
    if requested == "auto":
        return False if False in values else show["thinking"].get("default")
    value = requested == "on"
    if value not in values:
        raise ValueError(f"Thinking={value} is unsupported; supported values: {values}")
    return value


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, int(len(ordered) * fraction + 0.999999) - 1))]


def summarize(model_result):
    rows = model_result.get("tasks", [])
    category = {}
    for name in ("coding", "instructions", "reasoning"):
        subset = [r for r in rows if r["category"] == name]
        category[name] = {
            "passed": sum(r["grade"]["passed"] for r in subset),
            "total": len(subset),
            "median_seconds": statistics.median([r["response"]["wall_seconds"] for r in subset])
            if subset
            else None,
        }
    latencies = [r["response"]["wall_seconds"] for r in rows]
    rates = [
        r["response"]["generation_tokens_per_second"]
        for r in rows
        if r["response"].get("generation_tokens_per_second") is not None
    ]
    return {
        "passed": sum(r["grade"]["passed"] for r in rows),
        "total": len(rows),
        "categories": category,
        "errors": sum(
            r["grade"].get("failure_kind") in ("transport", "infrastructure") for r in rows
        ),
        "semantic_passed": sum(
            r["grade"].get("semantic_passed", r["grade"]["passed"]) for r in rows
        ),
        "median_seconds": statistics.median(latencies) if latencies else None,
        "p95_seconds": percentile(latencies, 0.95),
        "median_generation_tokens_per_second": statistics.median(rates) if rates else None,
        "incomplete": sum(not r["response"]["complete"] for r in rows),
    }


def shortlists(models):
    defaults, coding = [], []
    for model in models:
        s = model.get("summary")
        if (
            not s
            or not s["total"]
            or s.get("errors")
            or not model.get("full_gpu")
            or not model.get("finished")
        ):
            continue
        rates = {
            k: v["passed"] / v["total"] if v["total"] else 0 for k, v in s["categories"].items()
        }
        coverage = {
            k: len({r.get("id") for r in model["tasks"] if r["category"] == k})
            for k in MIN_DISTINCT_TASKS
        }
        covers_categories = all(coverage[k] >= minimum for k, minimum in MIN_DISTINCT_TASKS.items())
        meets_default_quality = (
            s["passed"] / s["total"] >= 0.75
            and rates["coding"] >= 0.6
            and rates["instructions"] >= 0.75
            and rates["reasoning"] >= 2 / 3
        )
        if covers_categories and meets_default_quality and s["p95_seconds"] < 30:
            defaults.append(model)
        if (
            coverage["coding"] >= MIN_DISTINCT_TASKS["coding"]
            and rates["coding"] >= 0.8
            and s["categories"]["coding"]["median_seconds"] < 20
        ):
            coding.append(model)
    defaults.sort(
        key=lambda m: (
            -m["summary"]["passed"] / m["summary"]["total"],
            m["summary"]["median_seconds"],
        )
    )
    coding.sort(
        key=lambda m: (
            -m["summary"]["categories"]["coding"]["passed"]
            / m["summary"]["categories"]["coding"]["total"],
            m["summary"]["median_seconds"],
        )
    )
    return {"default": [m["model"] for m in defaults], "coding": [m["model"] for m in coding]}


def atomic_write(path, text):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text)
    temporary.replace(path)


def write_report(output, run):
    run["selection_policy"] = {
        "version": "coverage-v2",
        "minimum_distinct_tasks": MIN_DISTINCT_TASKS,
        "requires_complete_run": True,
        "requires_full_gpu": True,
        "infrastructure_errors_allowed": 0,
    }
    run["shortlists"] = shortlists(run["models"])
    atomic_write(output / "comparison.json", json.dumps(run, indent=2, default=str))
    lines = [
        "# Practical model comparison",
        "",
        f"Suite: {run['suite_version']}. Every task must meet all its checks to pass.",
        "Generated Python executes in a network-isolated, read-only bubblewrap sandbox. No aliases are changed.",
        "",
        "| Model | Thinking | Strict passed | Content correct | Code | Instructions | Reasoning | Median sec | P95 sec | GPU |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    ranked = sorted(
        run["models"],
        key=lambda m: (
            -m.get("summary", {}).get("passed", 0),
            m.get("summary", {}).get("median_seconds") or float("inf"),
        ),
    )
    for model in ranked:
        s = model.get("summary")
        if not s:
            cells = [model["model"], str(model.get("think")), model.get("error", "not run")] + [
                ""
            ] * 7
            lines.append("| " + " | ".join(cells) + " |")
            continue
        counts = [
            f"{s['categories'][k]['passed']}/{s['categories'][k]['total']}"
            for k in ("coding", "instructions", "reasoning")
        ]
        lines.append(
            f"| {model['model']} | {model.get('think')} | {s['passed']}/{s['total']} | {s.get('semantic_passed', s['passed'])}/{s['total']} | {' | '.join(counts)} | {s['median_seconds']:.2f} | {s['p95_seconds']:.2f} | {model['full_gpu']} |"
        )
    lines += ["", "## Run validity", ""]
    for model in ranked:
        if (
            model.get("error")
            or not model.get("finished")
            or model.get("summary", {}).get("errors")
        ):
            lines.append(
                f"- {model['model']}: incomplete or excluded; {model.get('error', 'not all requested tasks completed')}. No recommendation is issued from this evidence."
            )
    lines += [
        "",
        "## Selection policy",
        "",
        "This small suite supports a shortlist, not a general intelligence claim. A default candidate needs at least 75% overall, 60% coding, 75% instructions, 67% reasoning, and P95 below 30 seconds. A coding candidate needs at least 80% of coding tasks and median below 20 seconds. Both require verified full-GPU placement. These thresholds are fixed before the run.",
        "",
    ]
    lines += [
        "Coverage gate: at least three distinct tasks in each category for a default recommendation, or three distinct coding tasks for a coding recommendation. Repeating a task does not increase coverage. Service/executor errors invalidate recommendations.",
        "",
    ]
    lines += [
        "Default shortlist: "
        + (", ".join(run["shortlists"]["default"]) or "No candidate met all thresholds."),
        "Coding shortlist: "
        + (", ".join(run["shortlists"]["coding"]) or "No candidate met all thresholds."),
        "",
    ]
    for model in ranked:
        if not model.get("summary"):
            continue
        lines += ["## " + model["model"], ""]
        for row in model["tasks"]:
            if not row["grade"]["passed"]:
                g = row["grade"]
                reason = g.get("error") or (
                    f"{g.get('cases_passed', 0)}/{g.get('cases_total', 0)} execution checks"
                    if row["kind"] == "python"
                    else "Expected output mismatch"
                )
                lines.append(f"- {row['id']} (seed {row['seed']}): {reason}")
        lines.append("")
    atomic_write(output / "comparison.md", "\n".join(lines))


def regrade(args):
    source = Path(args.input)
    output = Path(args.output)
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use a fresh output directory")
    run = json.loads((source / "comparison.json").read_text())
    suite_bytes = (source / "suite.json").read_bytes()
    if hashlib.sha256(suite_bytes).hexdigest() != run["suite_sha256"]:
        raise ValueError("Suite fingerprint differs from the recorded run")
    suite = json.loads(suite_bytes)
    tasks = {task["id"]: task for task in suite["tasks"]}
    run["regraded_from"] = str(source.resolve())
    run["grader_sha256"] = hashlib.sha256((HERE / "lib/practical_eval.py").read_bytes()).hexdigest()
    for model in run["models"]:
        for row in model["tasks"]:
            row["grade"] = grade(tasks[row["id"]], row["response"])
        if model["tasks"]:
            model["summary"] = summarize(model)
        expected = {
            (task["id"], seed) for task in suite["tasks"] for seed in run["settings"]["seeds"]
        }
        recorded = [(row["id"], row["seed"]) for row in model["tasks"]]
        model["finished"] = set(recorded) == expected and len(recorded) == len(expected)
    output.mkdir(parents=True, exist_ok=True)
    (output / "suite.json").write_bytes(suite_bytes)
    write_report(output, run)


def validate_suite(suite, structured=False):
    if (
        not isinstance(suite, dict)
        or not isinstance(suite.get("version"), str)
        or not isinstance(suite.get("tasks"), list)
        or not suite["tasks"]
    ):
        raise ValueError("Suite needs a version and a nonempty task list")
    ids = set()
    for task in suite["tasks"]:
        if (
            not isinstance(task, dict)
            or not isinstance(task.get("id"), str)
            or not task["id"]
            or task["id"] in ids
        ):
            raise ValueError("Task IDs must be nonempty and unique")
        ids.add(task["id"])
        if task.get("category") not in ("coding", "instructions", "reasoning") or task.get(
            "kind"
        ) not in ("python", "json", "exact"):
            raise ValueError("Unsupported task category or kind: " + task["id"])
        if not isinstance(task.get("prompt"), str) or not task["prompt"].strip():
            raise ValueError("Task prompt is missing: " + task["id"])
        if task["kind"] == "python":
            if (
                not isinstance(task.get("function"), str)
                or not task["function"].isidentifier()
                or not isinstance(task.get("cases"), list)
                or not task["cases"]
            ):
                raise ValueError("Python task needs a function and test cases: " + task["id"])
            for case in task["cases"]:
                if (
                    not isinstance(case, dict)
                    or not isinstance(case.get("args"), list)
                    or ("expected" in case) == ("raises" in case)
                ):
                    raise ValueError(
                        "Case needs arguments and exactly one expected value/exception: "
                        + task["id"]
                    )
        elif "expected" not in task or (
            task["kind"] == "exact" and not isinstance(task["expected"], str)
        ):
            raise ValueError("Task needs a valid expected value: " + task["id"])
        if structured and task["kind"] == "json":
            schema = task.get("response_schema")
            if not isinstance(schema, dict) or schema.get("type") not in ("object", "array"):
                raise ValueError("JSON task needs a declared root-type schema: " + task["id"])
            expected_type = (
                "array"
                if isinstance(task["expected"], list)
                else ("object" if isinstance(task["expected"], dict) else None)
            )
            if schema["type"] != expected_type:
                raise ValueError("Declared schema conflicts with expected root type: " + task["id"])


def evaluate(args):
    output = Path(args.output)
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use a fresh output directory; existing run evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    suite_bytes = Path(args.suite).read_bytes()
    suite = json.loads(suite_bytes)
    validate_suite(suite, args.json_mode)
    health = grade(
        {"kind": "python", "function": "identity", "cases": [{"args": [1], "expected": 1}]},
        {"complete": True, "content": "def identity(x):\n return x"},
    )
    (output / "executor-health.json").write_text(json.dumps(health, indent=2))
    if not health["passed"]:
        raise ValueError(
            "Isolated Python executor health check failed; no models were evaluated: " + str(health)
        )
    tags = request_json(args.host + "/api/tags")["models"]
    initial_running = request_json(args.host + "/api/ps")["models"]
    initial_names = {canonical_model_name(m["name"]) for m in initial_running}
    run = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "suite_version": suite["version"],
        "suite_sha256": hashlib.sha256(suite_bytes).hexdigest(),
        "grader_sha256": hashlib.sha256((HERE / "lib/practical_eval.py").read_bytes()).hexdigest(),
        "client_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "initial_running_models": initial_running,
        "settings": vars(args),
        "ollama_version": request_json(args.host + "/api/version"),
        "models": [],
    }
    (output / "suite.json").write_bytes(suite_bytes)
    for model in args.models:
        result = {"model": model, "tasks": []}
        run["models"].append(result)
        try:
            show = request_json(args.host + "/api/show", {"model": model})
            result["show"] = show
            result["inventory"] = next(
                (t for t in tags if t["name"] in (model, model + ":latest")), None
            )
            result["think"] = choose_thinking(show, args.thinking)
            options = {
                "temperature": args.temperature,
                "seed": args.seeds[0],
                "num_ctx": args.context,
                "num_predict": args.max_tokens,
            }
            result["warmup"] = chat(
                args.host,
                model,
                "Reply only READY.",
                dict(options, num_predict=16),
                result["think"],
                args.deadline,
            )
            if result["warmup"].get("failure_kind") == "transport":
                result.update(error=result["warmup"]["error"], error_kind="transport")
                raise ValueError("Warmup could not contact a working inference service")
            placement = request_json(args.host + "/api/ps")["models"]
            result["placement"] = next(
                (p for p in placement if p["name"] in (model, model + ":latest")), None
            )
            p = result["placement"] or {}
            result["full_gpu"] = bool(p.get("size") and p.get("size_vram", 0) >= p["size"])
            print(
                f"MODEL {model}: think={result['think']} full_gpu={result['full_gpu']}", flush=True
            )
            if not result["full_gpu"] and not args.allow_cpu_offload:
                result["error"] = (
                    "Full GPU placement was not verified; excluded from this GPU comparison"
                )
                write_report(output, run)
                continue
            for seed in args.seeds:
                for task in suite["tasks"]:
                    schema = (
                        task.get("response_schema")
                        if args.json_mode and task["kind"] == "json"
                        else None
                    )
                    response = chat(
                        args.host,
                        model,
                        task["prompt"],
                        dict(options, seed=seed),
                        result["think"],
                        args.deadline,
                        schema,
                    )
                    row = {
                        "id": task["id"],
                        "category": task["category"],
                        "kind": task["kind"],
                        "seed": seed,
                        "response": response,
                        "grade": grade(task, response),
                    }
                    result["tasks"].append(row)
                    result["summary"] = summarize(result)
                    write_report(output, run)
                    if row["grade"].get("failure_kind") in ("infrastructure", "transport"):
                        result.update(error_kind=row["grade"]["failure_kind"])
                        raise ValueError(
                            "Comparison invalidated by executor or inference-service failure"
                        )
                    print(
                        f"  {task['id']} seed={seed}: {'PASS' if row['grade']['passed'] else 'FAIL'} {response['wall_seconds']:.2f}s",
                        flush=True,
                    )
            result["finished"] = True
        except (urllib.error.URLError, ValueError) as exc:
            result["error"] = str(exc)
        finally:
            if canonical_model_name(model) in initial_names:
                result["cleanup"] = "Preserved model that was running before this comparison"
            elif "warmup" in result:
                try:
                    request_json(
                        args.host + "/api/generate",
                        {"model": model, "keep_alive": 0, "stream": False},
                    )
                    result["cleanup"] = "Unloaded model started by this comparison"
                except (urllib.error.URLError, OSError) as exc:
                    result["cleanup"] = "Unload failed: " + str(exc)
        write_report(output, run)
    print(f"Saved comparison to {output}", flush=True)
    if any(m.get("error_kind") in ("infrastructure", "transport") for m in run["models"]):
        raise ValueError("Run contains infrastructure errors; no affected model was recommended")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    evaluate_parser = sub.add_parser(
        "evaluate", help="Run explicitly selected installed models; never promote or delete them"
    )
    evaluate_parser.add_argument("--models", nargs="+", required=True)
    evaluate_parser.add_argument("--host", default="http://127.0.0.1:11434")
    evaluate_parser.add_argument("--suite", default=str(HERE / "evals/practical-v1.json"))
    evaluate_parser.add_argument(
        "--thinking",
        choices=["auto", "on", "off"],
        default="auto",
        help="auto selects off only when the model advertises support",
    )
    evaluate_parser.add_argument("--context", type=int, default=8192)
    evaluate_parser.add_argument("--max-tokens", type=int, default=1024)
    evaluate_parser.add_argument("--deadline", type=float, default=30)
    evaluate_parser.add_argument("--temperature", type=float, default=0)
    evaluate_parser.add_argument("--seeds", nargs="+", type=int, default=[42])
    evaluate_parser.add_argument("--allow-cpu-offload", action="store_true")
    evaluate_parser.add_argument(
        "--json-mode",
        action="store_true",
        help="Use each JSON task's declared schema; expected answers are never sent",
    )
    evaluate_parser.add_argument("--output", required=True)
    report_parser = sub.add_parser(
        "regrade", help="Grade recorded responses offline into a fresh directory"
    )
    report_parser.add_argument("--input", required=True)
    report_parser.add_argument("--output", required=True)
    args = parser.parse_args()
    if hasattr(args, "host"):
        args.host = args.host.rstrip("/")
        if urllib.parse.urlparse(args.host).hostname not in ("127.0.0.1", "localhost", "::1"):
            parser.error("This experimental evaluator currently requires a local Ollama server")
        if min(args.context, args.max_tokens, args.deadline) <= 0 or not math.isfinite(
            args.deadline
        ):
            parser.error("Context, token cap and deadline must be positive")
        if (
            not math.isfinite(args.temperature)
            or args.temperature < 0
            or len(set(args.seeds)) != len(args.seeds)
        ):
            parser.error("Use a finite nonnegative temperature and distinct seeds")
    try:
        {"evaluate": evaluate, "regrade": regrade}[args.command](args)
    except (ValueError, OSError) as exc:
        parser.exit(1, str(exc) + "\n")


if __name__ == "__main__":
    main()
