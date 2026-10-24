# ollama-model-match

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/robertsinfosec/ollama-model-match/badge)](https://scorecard.dev/viewer/?uri=github.com%2Frobertsinfosec%2Follama-model-match)
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

The LLM does the judgment. The scripts do the work. You just say "go."

## Quick Start

1. Clone this repo:
   ```bash
   git clone https://github.com/robertsinfosec/ollama-model-match.git
   cd ollama-model-match
   ```

2. Open OpenCode (or Claude Code, or VS Code with Copilot) in this folder.

3. Tell the LLM:
   > "Read src/README.md and follow all instructions."

4. The LLM runs the pipeline automatically. You just monitor progress.

## Supported Hardware

| GPU Vendor | Status | VRAM Detection |
|------------|--------|----------------|
| NVIDIA (CUDA) | ✅ Supported | nvidia-smi |
| AMD (ROCm) | ✅ Supported | amd-smi / rocm-smi |
| Apple Silicon | ✅ Supported | sysctl (unified memory) |
| Intel (Arc) | ⚠️ Experimental | /dev/dri (requires SYCL) |
| Qualcomm (Snapdragon) | ❌ Not supported | CPU-only mode |
| CPU only | ⚠️ Slow | All candidates pass filter |

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
Step 08: (Utility)      → Rebuild single model alias with updated config
```

The LLM's judgment points are Step 02 (web search), Step 06 (scoring), and Step 07 (promote/reject). Everything else is deterministic bash.

## Timing Expectations

| Step | Duration | Notes |
|------|----------|-------|
| 00-01 | ~10 sec | Tool checks + hardware detection |
| 02 | ~30-60 sec | Web search + API calls |
| 03 | ~1 sec | Local filtering |
| 04 | 1-3 min per model | Downloads 1-3GB per model |
| 05 | 1-2 min per model | Warmup + benchmark |
| 06 | 3-5 min per model | 3 prompts, thinking models are slow |
| 07 | ~1 sec | Local aggregation |

## Project Structure

```
ollama-model-match/
├── README.md                    # This file
├── src/
│   ├── README.md                # Full instruction manual for LLMs
│   ├── specs.yaml               # Single source of truth (generated)
│   ├── 00-prereqs.sh ... 08-update.sh  # Pipeline scripts
│   └── results/                 # Generated at runtime (gitignored)
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

Unlicense — public domain. Do whatever you want with it. See [LICENSE](LICENSE).