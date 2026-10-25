# Local LLM Model Evaluator

You are an LLM running in an OpenCode session with access to the local filesystem.
This README is your instruction manual. Follow the steps in order. Do not skip steps.

## Agent Operating Contract

You are the pipeline operator, not its maintainer. **Use the repository scripts
as-is. Do not edit, replace, bypass, or create alternate versions of pipeline
scripts, skills, workflows, or evaluation prompts while executing this workflow.**
The only runtime state you may update is `specs.yaml`, and only where a documented
pipeline step requires LLM judgment (OSINT candidates and Step 07 promotion).

Continue automatically through every successful step. Do not ask the user to
re-run commands, confirm normal progress, or re-initiate the workflow after an
expected long-running operation. The user's goal is end-to-end completion.

If a script, prerequisite, model pull, benchmark, evaluation, or verification
fails unexpectedly, stop the pipeline and give the human-in-the-loop (HITL) a
concise incident report containing:

- pipeline step and exact command;
- exit code and relevant error output;
- expected versus actual behavior;
- current checkpoint (`specs.yaml`, `results/unattended-status.txt`, and any
  relevant result file); and
- a recommended next action.

Do not modify repository code as a workaround. Wait for HITL direction.

## Prerequisites (User)

The user has:
- Cloned this repository
- Opened OpenCode in this folder
- Ollama installed (native or Docker)
- Internet connection

You (the LLM) handle everything else.

## Tool Invocation Notes (for the LLM)

The `shell` tool has a default timeout of 120000ms (2 minutes).
Long-running steps require explicit timeout. **Always set the timeout parameter.**

| Step | Timeout (ms) | Why |
|------|-------------|-----|
| 00-prereqs | 30000 | Tool checks only |
| 01-assess | 30000 | Hardware detection |
| 02-discover | 60000 | Web search + API calls |
| 03-filter | 10000 | Local filtering |
| 04-pull (single) | 300000 | 1 model, 1-3 min |
| 04-pull (all) | 600000 | 10+ models, 10-30 min |
| 05-benchmark | 300000 | 1-2 min per model |
| 06-evaluate | 600000 | 3 prompts per model, thinking models are slow |
| 07-report | 10000 | Local aggregation |
| 09-update | 300000 | Single model rebuild |

**Important:** Default 120000ms is too short for pulls and benchmarks. Partial downloads resume automatically if interrupted.

## Files

| File | Purpose |
|------|---------|
| `specs.yaml` | Single source of truth (hardware, thresholds, models, rejected, candidates) |
| `00-prereqs.sh` | Check tools and find Ollama |
| `01-assess.sh` | Detect hardware, create/update specs.yaml |
| `02-discover.sh` | Poll sources for new model candidates |
| `03-filter.sh` | Filter candidates by VRAM budget |
| `04-pull.sh` | Pull upstream models, create aliases, verify context |
| `05-benchmark.sh` | Warmup + benchmark, capture tok/s + output |
| `06-evaluate.sh` | Run standardized eval prompts, capture outputs |
| `07-report.sh` | Generate markdown report |
| `09-update.sh` | Rebuild single model alias with updated config |
| `10-run-unattended.sh` | Durable runner for deterministic Steps 03–06 |
| `lib/ollama.sh` | Shared native/Docker Ollama detection and command helpers |

## Steps

### STEP 00: Prerequisites

**Type:** Deterministic (bash)
**Script:** `00-prereqs.sh`

```bash
bash 00-prereqs.sh
```

Checks for required tools (`yq`, `jq`, `curl`) and finds Ollama (native or Docker).
Verifies Ollama is responsive.

**If this fails:** Report the error to the user. Do not continue.

**Output:** Status to stdout. Exit 0 = OK.

---

### STEP 01: Hardware Assessment

**Type:** Deterministic (bash)
**Script:** `01-assess.sh`

```bash
bash 01-assess.sh
```

Detects GPU (nvidia-smi/amd-smi/Apple Silicon), RAM, CPU, OS.
Creates `specs.yaml` if it doesn't exist, or updates the hardware section if it does.

**Output:** `specs.yaml` with detected hardware specs.

**LLM Action:** Review the detected specs. If they look wrong (e.g., 0GB VRAM), ask the user to verify.

---

### STEP 02: Discovery

**Type:** LLM judgment (Part 1) + Deterministic (Part 2)
**Script:** `02-discover.sh`

#### Part 1: OSINT Recon (LLM web search)

Use your `websearch` tool to find recent, self-hostable models **and ensure the
candidate pool covers the friendly roles assigned in Step 07**. Read the current
hardware and VRAM budget from `specs.yaml`; only retain role candidates that can
reasonably fit that budget with 100% GPU inference.

Run these general-discovery queries:

1. "new small language model 2026 self-hosted ollama"
2. "mixture of experts breakthrough small model local"
3. "new open weight model 3b 4b coding reasoning"
4. "best small llm ollama 2026"

Then run role-targeted queries for each applicable role. Do not assume a general
model can fill a specialized role: search specifically for `code`, `thinking`,
`cyber`, and `uncensored` models. Include the current VRAM budget in each query
and use the current year, for example:

1. "best small coding model GGUF Ollama <year> <VRAM>GB"
2. "best small reasoning thinking model GGUF Ollama <year> <VRAM>GB"
3. "best small cybersecurity cyber security model GGUF Ollama <year> <VRAM>GB"
4. "best small uncensored model GGUF Ollama <year> <VRAM>GB"

Also consider `fast`, `default`, and `frontier`: use small models for `fast`,
and, where the hardware permits, prefer stronger/larger models for `default` and
`frontier`. It is acceptable for roles to share a model on constrained hardware,
but discovery must give `cyber` and `uncensored` a deliberate opportunity to
qualify rather than leaving them `null` by default.

For each result, extract:
- Model name and organization
- Parameter count
- Key innovation
- Whether it's available on HuggingFace or Ollama

**Decision:** If you find a model that is:
- Within the parameter/quantization range that fits the current VRAM budget (or
  an MoE with similar active parameters)
- Available on HuggingFace or Ollama
- Not already in `specs.yaml` (check `models:`, `rejected:`, `candidates:`)

Then append it to `specs.yaml` under `candidates:` with:
```yaml
- tag: <model-tag>
  source: osint
  target_roles: [cyber] # one or more of: fast, default, code, thinking, frontier, cyber, uncensored
  estimated_vram_gb: <quantized model size in GB, excluding KV cache>
  priority: high
  discovered: <today>
  status: new
```

Set `target_roles` to the role(s) supported by the model's published purpose or
reliable community evidence. Do not label a model `cyber` or `uncensored` based
only on an unverified model name. When model metadata provides an artifact or
quantized-file size, record it as `estimated_vram_gb`. Candidates with neither
that value nor a recognizable parameter count are excluded rather than guessed
to fit.

#### Part 2: Public Source Discovery (bash)

```bash
bash 02-discover.sh
```

Polls Ollama library, HuggingFace orgs (DeepSeek, Qwen, THUDM, MiniMax, Mistral), and recent GGUF uploads.
Filters out vision/embedding/audio models and anything too large for the VRAM budget.
**Hardware-aware:** Size tiers scale with VRAM budget:
- 4GB VRAM → searches 2B-4B models
- 12GB VRAM → searches 3B-8B models
- 32GB VRAM → searches 7B-32B models
- 128GB VRAM → searches 32B-70B+ models
Always includes small models (1B-3B) for the "fast" role.
Scores each candidate with `priority` (high/medium/low).
Deduplicates against `models:`, `rejected:`, and existing `candidates:`.

**Output:** `specs.yaml` updated with new candidates.

**LLM Action:** Review candidate list. Remove any clearly irrelevant entries.
On large machines (32GB+ VRAM), prefer LARGER models for 'frontier' and 'default' roles.
Small models (1B-3B) should only be used for the 'fast' role.

---

### STEP 03: Filter

**Type:** Deterministic (bash)
**Script:** `03-filter.sh`

```bash
bash 03-filter.sh
```

Checks VRAM budget for each candidate (estimated from tag name).
Budget = `gpu_vram_gb - vram_headroom_gb` (default 4GB - 1GB = 3GB).
Only models that fit 100% in GPU pass (no CPU offload).

**Output:** `results/qualifying.txt`

**LLM Action:** Review qualifying list. If empty, consider adjusting thresholds.

---

### STEP 04: Pull

**Type:** Deterministic (bash)
**Script:** `04-pull.sh`

**Usage:**
```bash
bash 04-pull.sh              # Pull ALL qualifying models (sequential)
bash 04-pull.sh <alias>      # Pull just one model
```

Pulls upstream models one at a time (not concurrent) to avoid timeout issues.
Each model takes 1-3 minutes. Re-running skips already-pulled models.

**Timing:** Expect 1-3 minutes per model. 10 models = 10-30 minutes total.

**LLM Action:**
- If pulling all: run once, wait for completion. Set timeout to 300000ms (5 min) per invocation.
- If pulling one at a time: loop through qualifying models. Each invocation returns in 1-3 min.
- After each pull, check output for success/failure before continuing.
- If a pull fails, retry or remove from qualifying list.

**Output:** `results/pull-status.txt`

**Important:** Do NOT set timeout below 120000ms. Partial downloads resume automatically.

### Unattended deterministic run (Steps 03–06)

After completing the Step 02 OSINT review, prefer the unattended runner when
multiple models will be pulled, benchmarked, or evaluated:

```bash
nohup bash 10-run-unattended.sh > results/unattended.log 2>&1 &
echo $! > results/unattended.pid
```

Do not ask the user to monitor this job. Inspect `results/unattended-status.txt`
and `results/unattended.log` when the process completes. If the status is
`COMPLETE`, continue directly to Step 07. If it is `FAILED`, stop and provide the
HITL incident report described above; do not patch scripts or silently retry.

---

### STEP 05: Benchmark

**Type:** Deterministic (bash)
**Script:** `05-benchmark.sh`

**Usage:**
```bash
bash 05-benchmark.sh              # Benchmark ALL qualifying models
bash 05-benchmark.sh <alias>      # Benchmark just one model
```

For each model:
1. Warmup: run "hello" (loads model into memory, 60s timeout)
2. Benchmark: run standardized prompt with `--verbose` (280s timeout)
3. Capture output + tok/s to `results/bench/<alias>.txt`

**Internal timeouts:** 60s warmup, 280s benchmark per model.
**Estimated time:** 1-2 minutes per model.

**Output:** `results/bench/<alias>.txt` for each model.

**LLM Action:** Read each benchmark file. Extract eval rate (tok/s). Flag models below `min_tok_per_sec` (default 15).

**Tip:** Benchmark one model at a time for better visibility. Re-running skips nothing (overwrites).

---

### STEP 06: Evaluate

**Type:** Deterministic (bash) + LLM judgment
**Script:** `06-evaluate.sh`

**Usage:**
```bash
bash 06-evaluate.sh              # Evaluate ALL qualifying models
bash 06-evaluate.sh <alias>      # Evaluate just one model
```

For each model, runs 3 standardized prompts:

| Test | Prompt | Measures |
|------|--------|----------|
| reasoning | "If a train travels 120 miles in 2 hours, and a second train travels 180 miles in 3 hours, which is faster? Show your work." | Math/logic |
| coding | "Write a Python function to check if a string is a palindrome. Include type hints and docstring." | Code quality |
| instruction | "List 3 benefits of Python over Java, then 2 drawbacks. Be concise." | Following constraints |

**Output:** `results/eval/<alias>/{reasoning,coding,instruction}.txt`

**LLM Action:** Read each output file and score 1-5:

| Score | Meaning |
|-------|---------|
| 1 | Completely wrong or unhelpful |
| 2 | Partially correct but major issues |
| 3 | Correct but verbose or slightly off |
| 4 | Good — correct, clear, follows instructions |
| 5 | Excellent — correct, concise, well-structured |

**Pass threshold:** 12/15 total (sum of 3 scores).

---

### STEP 07: Score & Promote

**Type:** LLM judgment (manual)

Review all benchmark and evaluation results. For each qualifying model:

1. **If score >= 12/15 AND tok/s >= min_tok_per_sec:**
   - Promote to `models:` section in `specs.yaml`
    - Set `status: active`
    - Record `measured_tok_per_sec` and `tested_date`
    - Add notes about strengths/weaknesses
    - Assign roles (see Role Assignment Guidelines below). Treat a candidate's
      `target_roles` as discovery evidence, then confirm the assignment from
      benchmark and evaluation results before adding it to the model's `roles:`
      list and the top-level `roles:` mapping.

2. **If score < 12/15 OR tok/s < min_tok_per_sec:**
   - Move to `rejected:` section in `specs.yaml`
   - Record `reason`, `measured_tok_per_sec`, `tested_date`

3. **Clear `candidates:` section** (reset to `[]` for next run)

4. **Generate report:**
   ```bash
   bash 07-report.sh | glow
   ```

5. **Create friendly aliases:**
   ```bash
   bash 08-alias.sh
   ```

**Output:** Updated `specs.yaml` with promoted/rejected models. Friendly aliases created. Clean candidate list.

**Role Assignment Guidelines:**
- `default`: Highest coding_score among qualifying models
- `fast`: Highest tok/s (usually smallest model)
- `code`: Highest coding_score among coding-focused models (or default if none)
- `frontier`: Highest coding_score overall (may be slower than default)
- `thinking`: Best reasoning model (if available)
- `cyber`: Cybersecurity-focused model (if available)
- `uncensored`: Uncensored model (if available)
- On small machines (4GB), many roles collapse to the same model — that's OK
- On large machines (32GB+), prefer LARGER models for frontier/default
- Only create friendly aliases for roles that are meaningfully distinct
- Remove old aliases that are no longer relevant
- Assign `null` to roles that can't be filled

**Roles in specs.yaml:**
```yaml
roles:
  default: phi4-mini       # model alias
  fast: tinyllama
  code: phi4-mini          # same as default on 4GB
  thinking: null           # no thinking model qualified
  frontier: null           # same as default on 4GB
  cyber: null              # no cyber model qualified
  uncensored: null         # no uncensored model qualified
```

---

### Utility: Create Role Aliases

**Type:** Deterministic (bash)
**Script:** `08-alias.sh`

```bash
bash 08-alias.sh              # Create all role aliases
bash 08-alias.sh <role>       # Create just one (e.g., default)
```

Reads `roles:` from `specs.yaml` and creates friendly aliases.
Each alias gets `num_ctx` and thinking config from the model's entry.
Skips roles set to `null`.

### Utility: Update Single Model

**Type:** Deterministic (bash)
**Script:** `09-update.sh`

```bash
bash 09-update.sh <alias>
```

Rebuilds a single model alias with current `specs.yaml` config. Useful for:
- Changing context size (e.g., 8192 → 32768)
- Toggling thinking mode
- Changing thinking effort level
- Updating upstream tag

**Guardrails:** Validates all config values before attempting update:
- Context must be a positive integer
- Thinking must be true/false
- Thinking effort must be low/medium/high/null
- If thinking is false, thinking_effort must be null
- Warns if thinking requested (may not be supported by model)
- Warns if context > 131072 (may cause OOM)

**Example:**
```bash
# Edit specs.yaml: change code model num_ctx to 32768
bash 09-update.sh code
```

## GPU Support Matrix

| GPU Vendor | Detection Tool | Status | Notes |
|------------|---------------|--------|-------|
| NVIDIA | nvidia-smi | Supported | Full CUDA support via Ollama |
| AMD (ROCm) | amd-smi / rocm-smi | Supported | Unified memory (Strix Halo) auto-detected |
| Apple Silicon | sysctl | Supported | Unified memory = system RAM |
| Intel (Arc) | intel_gpu_top / /dev/dri | Experimental | Requires SYCL/oneAPI backend in Ollama |
| Qualcomm (Snapdragon) | /proc/cpuinfo | Not supported | Ollama does not yet support Snapdragon NPU/GPU |

## Notes

- All scripts are in the current directory
- All output goes to `results/` subdirectory
- `specs.yaml` is the single source of truth — never edit model lists manually, always through the pipeline
- The LLM's judgment points are: Step 02 (web search), Step 06 (scoring evals 1-5), Step 07 (promote/reject)
- Everything else is deterministic bash
- `rejected:` only tracks models that were pulled and tested (not VRAM-filtered)
- For unsupported GPUs (Snapdragon), models will run on CPU only (very slow)
