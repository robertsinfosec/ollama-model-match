# ollama-model-match

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/robertsinfosec/ollama-model-match/badge)](https://scorecard.dev/viewer/?uri=github.com%2Frobertsinfosec%2Follama-model-match)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/15862/badge)](https://www.bestpractices.dev/projects/15862)
[![ShellCheck](https://img.shields.io/github/actions/workflow/status/robertsinfosec/ollama-model-match/shellcheck.yml?label=shellcheck)](https://github.com/robertsinfosec/ollama-model-match/actions/workflows/shellcheck.yml)
[![License](https://img.shields.io/github/license/robertsinfosec/ollama-model-match)](https://github.com/robertsinfosec/ollama-model-match/blob/main/LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/robertsinfosec/ollama-model-match)](https://github.com/robertsinfosec/ollama-model-match/releases)
[![GitHub Stars](https://img.shields.io/github/stars/robertsinfosec/ollama-model-match)](https://github.com/robertsinfosec/ollama-model-match/stargazers)

**Find the best Ollama models for your hardware.** An agentic pipeline that discovers, filters, benchmarks, and evaluates local LLMs — automatically.

## The Problem

You have a GPU. You want to run local LLMs. But which ones fit? Which are fast enough? Which are actually smart? Finding out manually takes hours of downloading, testing, and evaluating — and you have to repeat it every time a new model drops.

## The Solution

`ollama-model-match` is a self-contained pipeline that an LLM (running in OpenCode, Claude Code, or GitHub Copilot) executes for you:

1. **Detects your hardware** (NVIDIA, AMD, Intel, Apple Silicon, or CPU-only)
2. **Discovers** new models from multiple sources (Ollama library, HuggingFace, OSINT)
3. **Filters** by what actually fits in your VRAM (100% GPU, no CPU offload)
4. **Pulls and benchmarks** each model (tok/s, context limits)
5. **Evaluates** quality with standardized prompts (reasoning, coding, instruction following)
6. **Scores and promotes** winners to friendly aliases (`default`, `fast`, `code`, `thinking`, etc.)
7. **Generates a report** with results

The LLM does research and judgment. Scripts do the long-running work, with
explicit handoffs rather than hours of agent-tool supervision.

## Quick Start

1. Clone this repo:
   ```bash
   git clone https://github.com/robertsinfosec/ollama-model-match.git
   cd ollama-model-match
   ```

2. Open OpenCode (or Claude Code, or VS Code with Copilot) in this folder.

3. Tell the LLM:
   > "Read src/README.md. Complete Phase A research through Step 02, then hand it back to me."

4. Run the command provided by the LLM in a terminal outside the harness:
   ```bash
   bash src/10-run-unattended.sh > src/results/unattended.log 2>&1
   ```
   Leave the terminal open or use a persistent terminal session. The scripts
   handle filtering, pulls, benchmarking and evaluation without execution deadlines.

5. When the command succeeds, tell the LLM:
   > "Read src/README.md and src/results/review.md. Perform Phase C analysis and cleanup for that run."

The target is 3–6 verified convenience aliases, with newly created interim models
removed only after successful verification. Models present before the run are
preserved. If execution fails, provide the log/status for diagnosis instead of
proceeding to scoring or cleanup.

### Dependency setup

```bash
bash src/00-prereqs.sh         # Explain missing tools and offer installation
bash src/00-prereqs.sh --yes   # Accept supported installs, including optional Glow
bash src/00-prereqs.sh --check # Check only; never install
```

Agents use `--yes`. Required tools are **Mike Farah yq v4.44.3+ (within v4)**, `jq`, `curl`, and a
working Ollama installation. Python `yq` is a different, unsupported product.
The installer downloads a pinned, SHA256-verified `yq` into `src/.tools/bin/`; scripts
select it specifically without changing PATH or replacing a system installation. For direct
`yq` commands, first run `source src/lib/tools.sh` from this repository's root.

Glow is offered because it makes Markdown reports nicer to read. You can decline
it without breaking the workflow. On Linux, setup uses Snap when available;
otherwise it uses a supported package manager (apt on Linux, Homebrew on macOS).
An installed but unavailable Snap daemon falls back to the package manager.
Administrator permission may be
needed for package installation; an agent cannot supply your sudo password.

The scripts require Bash 4.4+ and `grep -P` / `date -Iseconds` capabilities. macOS
needs additional GNU tools/current Bash; its stock shell/tools are insufficient.
For weekly refreshes, Phase A explicitly marks existing role models `retest: true`;
known models remain excluded otherwise. GPU-only runs verify actual Ollama
placement after warmup, rather than relying solely on memory estimates.

## Supported Hardware

| GPU Vendor | Status | VRAM Detection |
|------------|--------|----------------|
| NVIDIA (CUDA) | ✅ Supported | nvidia-smi |
| AMD (ROCm) | ✅ Supported | amd-smi / rocm-smi |
| Apple Silicon | ✅ Supported | sysctl (unified memory) |
| Intel (Arc) | ⚠️ Experimental | /dev/dri (requires SYCL) |
| Qualcomm (Snapdragon) | ❌ Not supported | CPU-only mode |
| CPU only | ⚠️ Slow | Candidates screened against measured RAM |

## Supported LLM Ecosystems

This repo includes a **Skill** that is auto-discovered by multiple coding agents:

| Ecosystem | Skill Path | How It Works |
|-----------|-----------|--------------|
| OpenCode | `.opencode/skills/ollama-model-match/SKILL.md` | Auto-discovered, loaded via `skill` tool |
| Claude Code | `.claude/skills/ollama-model-match/SKILL.md` | Auto-discovered via compatibility path |
| GitHub Copilot | `.github/skills/ollama-model-match/SKILL.md` | Auto-discovered in VS Code / Copilot CLI |

When you open any of these tools in this folder, the skill is advertised to the LLM automatically. The LLM loads it when you ask about finding models for your hardware.

## How It Works

```
Step 00: Prerequisites  → Check tools, find Ollama
Step 01: Assess         → Detect hardware, create specs.yaml
Step 02: Discovery      → OSINT recon + poll public sources
Step 03: Filter         → VRAM budget filter
Step 04: Pull           → Pull qualifying models (one at a time)
Step 05: Benchmark      → Warmup + measure tok/s
Step 06: Evaluate       → 3 standardized prompts (reasoning, coding, instruction)
Step 07: Score & Promote → LLM scores 1-5, promotes winners, rejects losers
Step 08: Role aliases    → Create and verify selected convenience aliases
Step 09: (Utility)       → Rebuild single model alias with updated config
Step 10: Runner          → Human launches deterministic Steps 03–06
Step 11: Cleanup         → Remove only this run's new interim models
```

The LLM's judgment points are Step 02 (web search), Step 06 (scoring), and Step 07 (promote/reject). Everything else is deterministic bash.

## Long-running execution

Network requests, downloads, warmup and inference have no fixed execution
deadlines. Their duration depends on the machine, connection and upstream
availability. A genuinely stuck operation waits until explicitly cancelled.
Progress is recorded in `src/results/unattended-status.txt`; completed runs get
isolated review packets under `src/results/runs/`. The LLM does not need to
supervise the running command. Each runner invocation starts a fresh run.

## Project Structure

```
ollama-model-match/
├── README.md                    # This file
├── src/
│   ├── README.md                # Full instruction manual for LLMs
│   ├── specs.yaml               # Single source of truth (generated)
│   ├── 00-prereqs.sh ... 11-cleanup.sh  # Pipeline scripts
│   ├── lib/ollama.sh             # Shared Ollama backend helpers
│   └── results/                 # Generated at runtime (gitignored)
├── tests/run.sh                  # Behavioral test harness
├── .opencode/skills/...         # OpenCode skill
├── .claude/skills/...           # Claude Code skill
├── .github/skills/...           # GitHub Copilot skill
├── .github/ISSUE_TEMPLATE/      # Issue templates
├── .github/PULL_REQUEST_TEMPLATE.md
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── SECURITY.md
├── STYLE_GUIDE.md
└── LICENSE
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT — see [LICENSE](LICENSE).
