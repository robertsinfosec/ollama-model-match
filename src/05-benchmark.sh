#!/usr/bin/env bash
set -Eeuo pipefail

# 05-benchmark.sh — Warmup + benchmark one or all qualifying models.
# Usage:
#   bash 05-benchmark.sh              # Benchmark ALL qualifying models
#   bash 05-benchmark.sh <alias>      # Benchmark just one model
# Reads: results/qualifying.txt
# Outputs: results/bench/<alias>.txt (output + tok/s metrics)
#
# Internal timeout: 280s per model (under 300s tool timeout).
# Warmup timeout: 60s.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"
RESULTS_DIR="${SCRIPT_DIR}/results"
QUALIFYING="${RESULTS_DIR}/qualifying.txt"
BENCH_DIR="${RESULTS_DIR}/bench"

mkdir -p "$BENCH_DIR"

# --- Colors ---
if [[ -t 1 ]]; then
    CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
    CYAN='' GREEN='' YELLOW='' RED='' NC=''
fi
log_info()  { printf "${CYAN}[*]${NC} %s\n" "$*"; }
log_ok()    { printf "${GREEN}[+]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
log_err()   { printf "${RED}[-]${NC} %s\n" "$*" >&2; }
die() { log_err "$*"; exit 1; }

[[ -f "$SPEC_FILE" ]] || die "specs.yaml not found."
[[ -f "$QUALIFYING" ]] || die "Run 03-filter.sh first."

# --- Ollama backend detection ---
OLLAMA_BACKEND=""
OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-}"
detect_ollama() {
    if command -v docker >/dev/null 2>&1; then
        local containers id name image service
        if containers="$(docker ps --no-trunc --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.service"}}' 2>/dev/null)"; then
            while IFS='|' read -r id name image service; do
                [[ -n "$id" ]] || continue
                if [[ -n "$OLLAMA_CONTAINER" ]]; then
                    [[ "$name" == "$OLLAMA_CONTAINER" || "$id" == "$OLLAMA_CONTAINER" ]] || continue
                elif [[ "${name,,}" != *ollama* && "${service,,}" != *ollama* ]] && [[ ! "$image" =~ (^|/)ollama/ollama([:@]|$) ]]; then
                    continue
                fi
                docker exec "$id" sh -c 'command -v ollama >/dev/null 2>&1' >/dev/null 2>&1 || continue
                OLLAMA_BACKEND=docker; OLLAMA_CONTAINER="$id"
                return 0
            done <<<"$containers"
        fi
    fi
    if [[ -n "$(type -P ollama)" ]]; then
        OLLAMA_BACKEND=native
    else
        die "No Ollama found."
    fi
}

ollama() {
    if [[ "$OLLAMA_BACKEND" == "docker" ]]; then
        docker exec "$OLLAMA_CONTAINER" ollama "$@"
    else
        command ollama "$@"
    fi
}

detect_ollama
ollama ls >/dev/null || die "Cannot connect to Ollama."

# --- Standardized benchmark prompt ---
BENCH_PROMPT="Write a Python function to reverse a linked list. Include docstring and type hints."

# --- Determine which models to benchmark ---
TARGET_ALIAS="${1:-}"

if [[ -n "$TARGET_ALIAS" ]]; then
    line=$(grep "^${TARGET_ALIAS}|" "$QUALIFYING" 2>/dev/null || true)
    if [[ -z "$line" ]]; then
        die "Model '$TARGET_ALIAS' not found in qualifying.txt"
    fi
    models_to_bench=("$line")
    log_info "Benchmarking single model: $TARGET_ALIAS"
else
    mapfile -t models_to_bench < "$QUALIFYING"
    log_info "Benchmarking all ${#models_to_bench[@]} qualifying models"
fi

log_info "Prompt: $BENCH_PROMPT"
log_info "Internal timeout: 280s per model"
log_info ""

# --- Benchmark each model ---
for line in "${models_to_bench[@]}"; do
    tag=$(echo "$line" | cut -d'|' -f1)
    priority=$(echo "$line" | cut -d'|' -f2)
    safe_name=$(echo "$tag" | tr '/' '_')
    outfile="${BENCH_DIR}/${safe_name}.txt"

    log_info "==> Benchmarking: $tag (priority: $priority)"

    # Warmup (60s timeout)
    log_info "    Warming up..."
    timeout 60 bash -c "echo hello | ollama run \"$tag\"" >/dev/null 2>&1 || true

    # Benchmark (280s timeout)
    log_info "    Running benchmark (timeout: 280s)..."
    {
        echo "=== BENCHMARK: $tag ==="
        echo "Priority: $priority"
        echo "Prompt: $BENCH_PROMPT"
        echo "Date: $(date -Iseconds)"
        echo ""
        echo "--- OUTPUT ---"
        echo "$BENCH_PROMPT" | timeout 280 ollama run "$tag" --verbose 2>&1
        echo ""
        echo "--- END ---"
    } > "$outfile" 2>&1

    # Check if timed out
    if grep -q "Timed out" "$outfile" 2>/dev/null || [[ $? -eq 124 ]]; then
        log_warn "    Timed out after 280s"
    fi

    # Extract metrics
    eval_rate=$(grep -oP 'eval rate:\s*\K[0-9.]+' "$outfile" 2>/dev/null | head -1 || echo "N/A")
    prompt_rate=$(grep -oP 'prompt eval rate:\s*\K[0-9.]+' "$outfile" 2>/dev/null | head -1 || echo "N/A")
    eval_count=$(grep -oP '^eval count:\s*\K[0-9]+' "$outfile" 2>/dev/null | head -1 || echo "N/A")
    total_dur=$(grep -oP 'total duration:\s*\K[0-9a-z.]+' "$outfile" 2>/dev/null | head -1 || echo "N/A")

    if [[ "$eval_rate" != "N/A" ]]; then
        if awk -v r="$eval_rate" 'BEGIN { exit !(r >= 15) }'; then
            log_ok "    eval rate: ${eval_rate} tok/s | prompt: ${prompt_rate} tok/s | tokens: ${eval_count} | duration: ${total_dur}"
        else
            log_warn "    eval rate: ${eval_rate} tok/s (below 15 threshold) | prompt: ${prompt_rate} tok/s | tokens: ${eval_count}"
        fi
    else
        log_err "    Could not parse metrics from output (model may have failed to load)"
    fi
    log_info "    Output saved: $outfile"
    log_info ""

done

log_info "Benchmark complete. Results in: $BENCH_DIR/"