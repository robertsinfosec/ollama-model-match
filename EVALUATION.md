# Optional practical model comparison

The existing three evaluation prompts are useful smoke tests. This optional
comparison tool adds executable checks and measured response latency before an
operator selects model roles. It never changes `specs.yaml`, aliases, promotion
state, or model downloads. It also works independently of metadata discovery.

## Requirements

- Python 3.10+; no Python packages are required.
- A local Ollama HTTP endpoint, with the selected models already installed.
- Linux, bubblewrap and `/usr/bin/python3` for isolated Python execution.

The executor health check runs before inference. It fails closed when isolation
is unavailable, with no fallback to executing generated code on the host.
Discovery, installation and promotion remain in the existing operator workflow.
Run commands from the repository root and choose a fresh output directory.

```bash
python3 src/12-compare.py evaluate \
  --models phi4-mini gemma4:e2b \
  --thinking auto --context 8192 --temperature 0.2 --seeds 7 19 42 \
  --json-mode --max-tokens 1024 --deadline 30 \
  --output src/results/practical-comparison
```

## What is measured

The bundled suite has 12 tasks: five Python utilities with 27 execution checks,
four extraction/routing/format tasks, and three arithmetic/dependency tasks.
A separate six-task holdout is available through `--suite
src/evals/holdout-v1.json`. Expected answers and execution cases are never sent
to the model. Each task starts a fresh chat. Loads are warmed separately.

`comparison.json` retains exact model digests, Ollama version, suite/grader/client
fingerprints, generation settings, thinking configuration, reported GPU
placement, response content and separate thinking output, first-token and
first-visible-answer timing, completion latency, structured token metrics and
individual failed checks. `comparison.md` summarizes the evidence. Records are
replaced atomically after each task; existing runs cannot be overwritten.

`--thinking auto` disables thinking only when the model advertises that control;
otherwise it uses the advertised default. An explicitly unsupported mode is
rejected. `--thinking on` can improve reasoning but costs generation time and
tokens; use an explicit larger budget when comparing that configuration:

```bash
python3 src/12-compare.py evaluate \
  --models gemma4:e2b --thinking on --json-mode \
  --context 8192 --temperature 0.2 --seeds 42 \
  --max-tokens 2048 --deadline 30 \
  --output src/results/thinking-comparison
```

These deadlines and token caps define the optional interactive-use experiment;
they do not change the main pipeline's execution policy. They are configurable.
Truncated or timed-out outputs cannot pass. Streaming deadlines cover stalled
headers and partial lines, not just delays between complete chunks.

## Grading and isolation

Python tasks must pass every execution check, return the requested container
types, and preserve their inputs. The parent retains gold answers and expected
exceptions. The worker receives only function names and arguments. It runs with
isolated namespaces, read-only system/code mounts, no home directory or network,
CPU/memory/file/process limits and a five-second execution deadline. Output uses
bounded temporary files, including for writes that bypass Python's stdout.

JSON checks distinguish strict protocol compliance from recoverable content.
Duplicate keys, nonfinite constants, extra fields and wrong types are rejected.
A single Markdown JSON block can be decoded diagnostically without passing the
strict JSON-only instruction. `--json-mode` uses each task's declared root-type
schema; generic JSON-object mode would be wrong for array tasks. Schemas do not
contain answer values. Python answers may use one code fence for ordinary
coding-assistant convenience.

Service disconnections, broken isolation and malformed worker protocols
invalidate the affected comparison instead of becoming model-quality failures.
Explicit cleanup unloads only models started by the comparison. Ollama may
still reload or evict models to accommodate the requested context and capacity.

## Recommendations and limitations

The report can return an empty shortlist. Eligibility requires a completed run,
reported full-GPU placement and no service/executor errors. A coding shortlist
needs three distinct coding tasks, at least 80% task passes and median coding
latency below 20 seconds. A default shortlist needs three distinct tasks per
category, at least 75% overall, 60% coding, 75% instructions, two-thirds reasoning,
and P95 latency below 30 seconds. Repeated seeds do not supply distinct coverage.
Small smoke tests and holdouts therefore cannot establish a recommendation alone.

This authored suite is a screening tool, not a comprehensive benchmark. Record
configuration changes as separate experiments; thinking-on/off and raw/schema
output runs are different configurations. GPU placement is based on Ollama's
reporting, whose memory figures may differ from artifact sizes with speculative
models. Treat code as a draft requiring executable tests and human review.

Regrade recorded answers offline into a new evidence directory:

```bash
python3 src/12-compare.py regrade \
  --input src/results/practical-comparison \
  --output src/results/regraded-comparison
```

The suite fingerprint is checked before any code executes. Original responses
are preserved. This tool does not publish completion markers or review receipts
for the existing unattended pipeline; its outputs are independent research.

## Tests

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Twenty-nine offline/local-server tests cover measurement, schema handling,
strict grading, handwritten gold fixtures, mutation/type checks, isolation,
resource/output limits, service failures, stalled streams, lifecycle handling,
evidence tampering and coverage gates. Tests never download weights or contact
Ollama. The CI workflow installs bubblewrap and runs compilation and these tests.
