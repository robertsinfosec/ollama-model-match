# Local LLM Model Evaluator

You are an LLM with access to the local filesystem. This workflow has three
phases with explicit handoffs. By default, execute **Phase A only**, then stop.
Do not launch long-running inference or downloads from the agent harness.

## Working directory

All commands in this manual run from the directory containing this README and
`00-prereqs.sh`. In a Git checkout, change to `src/` first. In an extracted release
ZIP, this is the extraction directory; there is no enclosing `src/` directory.

## Phase boundaries

### Phase A — LLM research (Steps 00–02)

Run `bash 00-prereqs.sh --yes`. Agents accept all
supported dependency offers, including optional Glow. If administrator
credentials or an unsupported installation method are needed, report the exact
command to the human; do not loop or attempt to bypass permissions.

Then assess hardware, research this week's model releases and
community experience, then run public-source discovery. Record exact pullable
references, artifact sizes where available, intended roles, and evidence URLs.
An MoE's active parameter count is not its total weight-memory requirement.

For weekly refreshes, include the model tags behind the currently selected role
aliases in `candidates:` with `retest: true`, even if already curated. Refresh
artifact-size evidence where possible. Reconsider rejected models only with an
explicit reason recorded in the research handoff. Without `retest: true`, known
curated/rejected tags retain the existing skip behavior. Update existing candidate
entries rather than duplicating tags.

Write `results/research.md` containing:
- research date, machine/hardware and VRAM budget;
- candidate tags, target roles, rationale and evidence URLs;
- any existing model deliberately reconsidered this week;
- uncertainties, unavailable sources, and any unresolved prerequisite problems.

Use **Mike Farah yq v4**, never Python yq. Scripts select the repo-local verified
binary automatically. Before invoking `yq` directly,
source the same helper so a different system `yq` cannot take precedence:

```bash
source lib/tools.sh
yq -e '.' specs.yaml >/dev/null
```
Hand the human this command, to run from
the script directory in a terminal outside the harness, **then stop**:

```bash
bash 10-run-unattended.sh > results/unattended.log 2>&1
```

The command runs in the foreground; leave the terminal open, or use a persistent
terminal session if disconnecting. There is no execution deadline. No agent
needs to poll, babysit, or wait on a shell tool while this command runs.

### Phase B — Human starts scripts (Steps 03–06)

The runner records progress in `results/unattended-status.txt`, uses a fresh
`results/runs/run.*` directory, and publishes `results/review.md` only when ready.
The run directory contains the research/specs snapshot, pre-run Ollama inventory,
pull status, benchmark outputs, evaluation responses, and managed-model ledger.
Previous runs are preserved; stale outputs are not reused as current evidence.
Use one run at a time per checkout; do not edit `specs.yaml` during Phase B.

On successful completion, hand the LLM this prompt:

> Read README.md and results/review.md. Perform Phase C for that run only.

On failure or cancellation, do not request scoring or cleanup. Give the agent the
status and log for diagnosis. A new invocation starts a fresh run, not a resume.

### Phase C — LLM review and finalization (Step 07)

Require `execution-complete` in the run named by `results/review.md`. Read only
that run's evidence, score the responses, and record scores/reasons in the run's
`scores.yaml`. Update `specs.yaml` as described in Step 07. Target **3–6 useful
convenience aliases**, allowing shared underlying models. Do not fabricate a
specialized capability or promote a failing model just to reach a count.
Upsert promoted entries by tag/alias; a retest updates the existing entry, not a
duplicate. Preserve its context/thinking configuration unless deliberately changed.

Use this structure for `scores.yaml` (one entry per evaluated model; scores are
integers from 1–5). Include a reason for each score and evidence for specialized
roles; do not infer them from a model's name alone:

```yaml
models:
  - tag: exact-candidate-tag
    reasoning_score: 4
    coding_score: 4
    instruction_score: 4
    measured_tok_per_sec: 25.0
    decision: promote # or reject
    reasons:
      reasoning: "Correct answer and working; eval/<safe-name>/reasoning.txt"
      coding: "Correct implementation; eval/<safe-name>/coding.txt"
      instruction: "Follows constraints; eval/<safe-name>/instruction.txt"
roles:
  default: selected-model-alias
  code: selected-model-alias
  fast: selected-model-alias
```

After selecting roles, run from the script directory (replace the run path with
the exact path in the review packet):

```bash
PIPELINE_RESULTS_DIR=/path/to/run bash 07-report.sh > /path/to/run/report.md
PIPELINE_RESULTS_DIR=/path/to/run bash 08-alias.sh
bash 11-cleanup.sh /path/to/run
```

Alias creation reuses evaluated local models where available. If it needs a
long-running pull, hand that command back to the human rather than imposing a
harness deadline. Cleanup requires a successful full alias rebuild against the
current specs, verifies the selected aliases, and removes only ledger-listed
models absent from the pre-run inventory. Pre-existing models are preserved.
If fewer than three roles can be supported, explain the shortfall and stop
before cleanup. Report final aliases, evidence, removals and retained artifacts.

Phase C validates scores, reasons, measured throughput and passing decisions
against the completed run before changing role aliases. All new role manifests
are staged first; publication failures restore the previous role set. If Ollama
also refuses restoration, the command fails and retains backups plus the printed
`transaction.*/recovery.txt` manifest for human recovery. Do not delete these
backups or proceed to cleanup after such a failure.

## Agent Operating Contract

You are the pipeline operator, not its maintainer. **Use the repository scripts
as-is. Do not edit, replace, bypass, or create alternate versions of pipeline
scripts, skills, workflows, or evaluation prompts while executing this workflow.**
You may edit `specs.yaml` only for documented research/promotion decisions, and
write the documented `results/research.md` and run-specific `scores.yaml`.
All other runtime artifacts are written by the scripts, not reconstructed by
the agent. Do not create completion markers or verification receipts yourself.

Continue automatically within the current phase. Stop at its documented
handoff. Never infer permission to run Phase B from a request for Phase A.

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

The LLM handles research and review; the human starts the deterministic runner.

## Execution duration

There are no fixed execution deadlines for network requests, pulls, warmup,
benchmarks or evaluation. Duration depends on hardware, network, model size and
source availability. Slow progress is not failure; explicit command errors are.
An actually stuck operation can wait indefinitely until explicitly cancelled.
If a harness cannot run an operation without a deadline, hand it to the human
to run outside the harness instead of guessing a larger deadline.

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
| `11-cleanup.sh` | Verify final roles and remove only this run's new artifacts |
| `lib/ollama.sh` | Shared native/Docker Ollama detection and command helpers |

## Steps

All commands use the script directory as the working directory. Steps 03–06 are reference only for the LLM;
the human-run Phase B runner executes them.

### STEP 00: Prerequisites

**Type:** Deterministic (bash)
**Script:** `00-prereqs.sh`

```bash
bash 00-prereqs.sh --yes
```

Checks required tools (Mike Farah `yq` v4, `jq`, `curl`), offers optional Glow,
and finds Ollama (native or Docker). Verifies Ollama is responsive.

Humans can omit `--yes` for explanations and individual installation prompts.
`--check` reports missing/unsupported dependencies without installing anything.
Without a terminal, the default mode does not wait for input; agents must pass
`--yes`. Declining Glow is allowed; declining a required tool prevents progress.

Glow uses Snap on Linux when available, otherwise the supported package manager.
Snap must have a responding daemon, not merely an installed client. Automatic
package installation supports apt on Linux and Homebrew on macOS; other package
managers receive manual installation guidance. Agent `--yes` mode never waits
for a sudo password, even if the harness provides a terminal.
`yq` uses a pinned, SHA256-verified upstream binary in `.tools/bin/` beside the
pipeline scripts (`src/.tools/bin/` in a checkout), without
Python, Snap confinement, or replacing the system executable. Automatic binary
installation supports Linux/macOS on x86-64 and ARM64. Other platforms get manual
installation guidance. Package installs may need administrator privileges; agents
use non-interactive sudo and stop for human help if credentials are unavailable.

Supported `yq` is v4.44.3 or newer within v4; the downloader pins v4.54.1. Runtime
selection affects only `yq`, not the process PATH or unrelated commands. This
build also requires Bash 4.4+ and compatible `grep -P` / `date -Iseconds` tools.
Stock macOS does not supply all of these; setup reports the requirements instead
of promising an untested native configuration.

**If this fails:** Report the error to the user. Do not continue.

**Output:** Status to stdout. Exit 0 = OK.

---

### STEP 01: Hardware Assessment

**Type:** Deterministic (bash)
**Script:** `01-assess.sh`

```bash
bash 01-assess.sh
```

Detects GPU, RAM, CPU and OS on the inference machine. Run assessment on that
machine; an explicitly remote `OLLAMA_HOST` is rejected before updating hardware.
On Linux, optional `vulkaninfo` provides a fallback for a single discrete GPU
when vendor tools are unavailable. This reads dedicated memory heaps, excluding
shared system memory and software renderers. Multiple discrete Vulkan GPUs are
not automatically combined or assigned to Ollama. Hardware visibility still
requires an actual Ollama load to confirm backend support.
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

1. "new small language model <current year> self-hosted ollama this week"
2. "mixture of experts breakthrough small model local"
3. "new open weight model 3b 4b coding reasoning"
4. "best small llm ollama <current year> this week"

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
- Within the total quantized-weight and context-memory budget, including all
  resident MoE experts rather than just active parameters
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
  retest: true # only when intentionally refreshing/reconsidering a known tag
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
These are preliminary estimates, not proof of placement. After warmup, the
benchmark/evaluation scripts require Ollama to report `100% GPU` for GPU-only
runs. Explicit CPU-only mode retains its existing behavior. An unrecognized
parameter count requires artifact-size metadata; `32b` must not match `2b`.

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

Pulls upstream models sequentially, without an execution deadline. Within the
same results directory, re-running skips successfully recorded pulls. Each new
runner invocation gets a fresh directory and refreshes its qualifying models.
Individual pull failures are recorded and removed from the qualifying list by
the script; alias creation/verification failures stop the runner before review.
Existing candidate/upstream manifests are snapshotted before pulling; failed
pulls or rebuilds restore those names. Backups are retained if restoration fails.

**Output:** `results/pull-status.txt`

Partial downloads resume through Ollama. Never treat elapsed time as rejection evidence.

### Unattended deterministic run (Steps 03–06)

These steps belong to Phase B, not the LLM's Phase A. Use the human-run command
and completion handoff above. The runner owns sequencing and durable status.
The per-step commands here are reference material for diagnosis/manual use.

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
1. Warmup: run "hello" (loads model into memory)
2. Verify actual GPU placement against the policy written by Step 03
3. Benchmark: run standardized prompt with `--verbose`
4. Capture output + tok/s to `results/bench/<alias>.txt`

Both warmup and benchmark wait for completion without execution deadlines.

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
    PIPELINE_RESULTS_DIR=/path/to/run bash 07-report.sh
    ```

    Save the Markdown report first. When Glow is installed, use `glow - < report.md`
    to display it nicely; otherwise read the saved file as plain text. A missing
    or failing optional renderer is not a pipeline failure.

5. **Create friendly aliases:**
   ```bash
    PIPELINE_RESULTS_DIR=/path/to/run bash 08-alias.sh
   ```

6. **Verify and clean up:** Run `bash 11-cleanup.sh /path/to/run` only after all
   selected aliases are verified. Never manually delete unrelated Ollama models.

**Output:** Updated `specs.yaml`, recorded scores, 3–6 verified convenience
aliases where supported, and inventory-bounded cleanup of new interim models.

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
- Target 3–6 useful friendly aliases; roles may share an underlying model
- Do not remove pre-existing aliases without a separate ownership/retirement decision
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
- `specs.yaml` is the configuration source of truth; only Phase A research and
  Phase C promotion/role decisions authorize LLM edits to model lists
- The LLM's judgment points are: Step 02 (web search), Step 06 (scoring evals 1-5), Step 07 (promote/reject)
- Everything else is deterministic bash
- `rejected:` only tracks models that were pulled and tested (not VRAM-filtered)
- Mutating execution/finalization phases share a per-directory lock. Concurrent
  phases are refused. After a crash, inspect the lock's PID and recovery files
  before a human removes a stale lock; never automatically steal it.
- For unsupported GPUs (Snapdragon), models will run on CPU only (very slow)
