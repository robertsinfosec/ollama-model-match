---
name: Ollama Model Match
description: Discover, filter, benchmark, and evaluate Ollama models for your hardware. Use when the user wants to find the best local LLM for their GPU.
---

## Workflow

Follow these steps in order. Full details are in `src/README.md`.

1. **Prereqs**: Run `src/00-prereqs.sh` — checks tools, finds Ollama (native/Docker).
2. **Assess**: Run `src/01-assess.sh` — detects GPU (NVIDIA/AMD/Intel/Apple/Snapdragon), RAM, CPU, OS. Creates `specs.yaml`.
3. **Discovery**: Use `websearch` for OSINT recon (new small models), then run `src/02-discover.sh`.
4. **Filter**: Run `src/03-filter.sh` — filters candidates by VRAM budget (100% GPU only).
5. **Pull**: Run `src/04-pull.sh` — pull qualifying models one at a time. Use `src/04-pull.sh <alias>` for single model.
6. **Benchmark**: Run `src/05-benchmark.sh` — warmup + benchmark each model. Use `src/05-benchmark.sh <alias>` for single model.
7. **Evaluate**: Run `src/06-evaluate.sh` — 3 standardized prompts per model. Use `src/06-evaluate.sh <alias>` for single model.
8. **Score & Promote**: Read benchmark + eval results. Score each model 1-5 (pass: 12/15). Promote winners to `models:` in `specs.yaml`, reject losers to `rejected:`.
9. **Report**: Run `src/07-report.sh | glow`.

## Key Rules

- Always set shell tool timeout (see `src/README.md` Tool Invocation Notes table).
- `04-pull.sh`, `05-benchmark.sh`, `06-evaluate.sh` support single-model mode.
- `rejected:` only tracks models that were pulled and tested (not VRAM-filtered).
- Models that fail to pull are removed from `candidates:` and `qualifying.txt`.
- CPU-only machines: all candidates pass filter, but warn user about slow speed.
- GPU support: NVIDIA ✅, AMD ✅, Apple Silicon ✅, Intel ⚠️ experimental, Snapdragon ❌ not supported.

## Timing

- Pulls: 1-3 min per model (set timeout 300000ms)
- Benchmarks: 1-2 min per model (set timeout 300000ms)
- Evaluations: 3-5 min per model (set timeout 600000ms)
- Do NOT use default 120000ms timeout for pulls or benchmarks.

## Guardrails

- `08-update.sh <alias>` rebuilds a single model with updated config from specs.yaml
- Validates context (positive integer), thinking (true/false), thinking_effort (low/medium/high/null)
- Warns if thinking requested (may not be supported by model)
- Warns if context > 131072 (may cause OOM)