#!/usr/bin/env bash
set -Eeuo pipefail

# 10-run-unattended.sh — Run deterministic long-running pipeline stages.
# Run only after the LLM has completed Step 02 OSINT review. This script records
# durable progress in results/unattended-status.txt for an agent to inspect.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
STATUS_FILE="${RESULTS_DIR}/unattended-status.txt"

mkdir -p "$RESULTS_DIR"

write_status() {
    printf '%s | %s\n' "$(date -Iseconds)" "$*" > "$STATUS_FILE"
}

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
run_step "03" "03-filter.sh"
run_step "04" "04-pull.sh"
run_step "05" "05-benchmark.sh"
run_step "06" "06-evaluate.sh"
write_status "COMPLETE | deterministic pipeline | Step 07 scoring and promotion required"
