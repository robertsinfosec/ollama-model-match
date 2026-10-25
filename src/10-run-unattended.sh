#!/usr/bin/env bash
set -Eeuo pipefail

# 10-run-unattended.sh — Run deterministic long-running pipeline stages.
# Run only after the LLM has completed Step 02 OSINT review. This script records
# durable progress and an isolated review packet for an agent to inspect.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
STATUS_FILE="${RESULTS_DIR}/unattended-status.txt"

mkdir -p "$RESULTS_DIR"
[[ -s "${RESULTS_DIR}/research.md" ]] || {
    printf 'Complete Phase A first: results/research.md is required.\n' >&2
    exit 1
}
mkdir -p "${RESULTS_DIR}/runs"
PIPELINE_RESULTS_DIR=$(mktemp -d "${RESULTS_DIR}/runs/run.XXXXXXXX")
export PIPELINE_RESULTS_DIR
cp "${RESULTS_DIR}/research.md" "${PIPELINE_RESULTS_DIR}/research.md"
cp "${SCRIPT_DIR}/specs.yaml" "${PIPELINE_RESULTS_DIR}/specs-before.yaml"
printf '%s\n' "$PIPELINE_RESULTS_DIR" > "${RESULTS_DIR}/latest-run.txt"
printf 'NOT READY: execution in progress. Run directory: %s\n' "$PIPELINE_RESULTS_DIR" > "${RESULTS_DIR}/review.md"

# shellcheck source=lib/ollama.sh
source "${SCRIPT_DIR}/lib/ollama.sh"

write_status() {
    printf '%s | %s\n' "$(date -Iseconds)" "$*" > "$STATUS_FILE"
    cp "$STATUS_FILE" "${PIPELINE_RESULTS_DIR}/status.txt"
}

trap 'write_status "FAILED | execution interrupted"; exit 130' INT
trap 'write_status "FAILED | execution terminated"; exit 143' TERM

run_step() {
    local step="$1"
    local script="$2"
    write_status "RUNNING | ${step} | ${script}"
    if bash "${SCRIPT_DIR}/${script}"; then
        write_status "COMPLETE | ${step} | ${script}"
    else
        local exit_code=$?
        write_status "FAILED | ${step} | ${script} | exit=${exit_code}"
        return "$exit_code"
    fi
}

write_status "STARTED | deterministic pipeline"
if ! detect_ollama || ! ollama_model_names > "${PIPELINE_RESULTS_DIR}/models-before.txt"; then
    write_status "FAILED | Ollama inventory unavailable"
    exit 1
fi
printf '%s|%s|%s\n' "$OLLAMA_BACKEND" "$OLLAMA_CONTAINER" "${OLLAMA_HOST:-}" > "${PIPELINE_RESULTS_DIR}/backend.txt"
run_step "03" "03-filter.sh"
cp "${PIPELINE_RESULTS_DIR}/qualifying.txt" "${PIPELINE_RESULTS_DIR}/qualifying-before-pull.txt"
run_step "04" "04-pull.sh"
if [[ ! -s "${PIPELINE_RESULTS_DIR}/qualifying.txt" ]] || grep -q '^CREATE_FAIL|' "${PIPELINE_RESULTS_DIR}/pull-status.txt"; then
    write_status "FAILED | 04 | no usable candidates or alias verification failed"
    exit 1
fi
run_step "05" "05-benchmark.sh"
run_step "06" "06-evaluate.sh"
cat > "${PIPELINE_RESULTS_DIR}/review.md" <<EOF
# Phase B complete — Phase C review required

Run directory: ${PIPELINE_RESULTS_DIR}

Read this run's research.md, specs-before.yaml, qualifying.txt, pull-status.txt,
bench/ and eval/. Do not use results from another run. Score only complete
responses, record evidence and throughput, then follow Phase C in src/README.md.

Create and verify the selected convenience aliases before running cleanup.
models-before.txt and managed-models.txt bound cleanup to this run's new models.
No scoring, promotion, or cleanup has happened yet.
EOF
write_status "COMPLETE | deterministic pipeline | Phase C review required"
touch "${PIPELINE_RESULTS_DIR}/execution-complete"
cp "${PIPELINE_RESULTS_DIR}/review.md" "${RESULTS_DIR}/review.md"
printf '\nExecution complete. Give results/review.md to the LLM for Phase C.\n'
