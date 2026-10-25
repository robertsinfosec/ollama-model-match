---
name: Ollama Model Match
description: Discover, filter, benchmark, and evaluate Ollama models for your hardware. Use when the user wants to find the best local LLM for their GPU.
---

## Workflow

Full details and handoff contracts are in `src/README.md`. Default to **Phase A
only**, not an end-to-end agent-supervised run.

1. **Prereqs**: Run `src/00-prereqs.sh` — checks tools, finds Ollama (native/Docker).
2. **Assess**: Run `src/01-assess.sh` — detects GPU (NVIDIA/AMD/Intel/Apple/Snapdragon), RAM, CPU, OS. Creates `specs.yaml`.
3. **Discovery**: Use `websearch` for general and role-targeted OSINT recon, then run `src/02-discover.sh`. Search for VRAM-fitting candidates for `code`, `thinking`, `cyber`, and `uncensored` in addition to general/fast models; record supported roles in `target_roles`.
4. **Handoff A**: Write `src/results/research.md` with candidate evidence, exact references, hardware budget and uncertainties. Give the human `bash src/10-run-unattended.sh > src/results/unattended.log 2>&1` to run outside the harness, then STOP.
5. **Phase B (human/scripts)**: The runner executes Steps 03–06 without deadlines and produces `src/results/review.md`. Do not launch or supervise this phase from the agent harness.
6. **Phase C (on explicit return)**: Read the completed run's review packet and outputs only. Score responses 1–5 (pass: 12/15), record scores/reasons, promote/reject and select 3–6 useful convenience aliases where evidence supports them.
7. **Finalize**: Use that run's `PIPELINE_RESULTS_DIR` for `07-report.sh` and `08-alias.sh`, then run `11-cleanup.sh <run-directory>`. Never clean up before verification; pre-existing models are preserved.

## Agent Operating Rules

- Execute the pipeline scripts as-is. Never rewrite, patch, bypass, or create an
  alternate pipeline implementation while running a user assessment.
- Continue within the current phase, then stop at its handoff. Do not cross
  phase boundaries without the documented human handoff.
- On any unexpected script, pull, benchmark, evaluation, or verification failure,
  stop and give the HITL the step, exact command, exit code, relevant output,
  checkpoint files, expected versus actual behavior, and a recommended next step.
  Do not change repository code as a workaround.

## Key Rules

- Do not impose execution deadlines. If a harness cannot wait without a
  deadline, hand the operation to the human to run outside it.
- `04-pull.sh`, `05-benchmark.sh`, `06-evaluate.sh` support single-model mode.
- `rejected:` only tracks models that were pulled and tested (not VRAM-filtered).
- Models that fail to pull are removed from `candidates:` and `qualifying.txt`.
- CPU-only machines: all candidates pass filter, but warn user about slow speed.
- GPU support: NVIDIA ✅, AMD ✅, Apple Silicon ✅, Intel ⚠️ experimental, Snapdragon ❌ not supported.

## Duration

Runtime depends on compute, network and upstream availability. Slow is not a
failure. An actually stuck operation requires explicit cancellation.

## Guardrails

- `09-update.sh <alias>` rebuilds a single model with updated config from specs.yaml
- Validates context (positive integer), thinking (true/false), thinking_effort (low/medium/high/null)
- Warns if thinking requested (may not be supported by model)
- Warns if context > 131072 (may cause OOM)
