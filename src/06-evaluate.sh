#!/usr/bin/env bash
set -Eeuo pipefail

# 06-evaluate.sh — Run standardized eval prompts for one or all qualifying models.
# Usage:
#   bash 06-evaluate.sh              # Evaluate ALL qualifying models
#   bash 06-evaluate.sh <alias>      # Evaluate just one model
# Reads: results/qualifying.txt
# Outputs: results/eval/<alias>/{reasoning,coding,instruction}.txt
#
# Internal timeout: 120s per prompt (360s total per model).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"
RESULTS_DIR="${SCRIPT_DIR}/results"
QUALIFYING="${RESULTS_DIR}/qualifying.txt"
EVAL_DIR="${RESULTS_DIR}/eval"

mkdir -p "$EVAL_DIR"

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

# --- Standardized eval prompts ---
P1="If a train travels 120 miles in 2 hours, and a second train travels 180 miles in 3 hours, which is faster? Show your work."
P2="Write a Python function to check if a string is a palindrome. Include type hints and docstring."
P3="List 3 benefits of Python over Java, then 2 drawbacks. Be concise."

EVAL_NAMES=("reasoning" "coding" "instruction")
EVAL_PROMPTS=("$P1" "$P2" "$P3")

# --- Determine which models to evaluate ---
TARGET_ALIAS="${1:-}"

if [[ -n "$TARGET_ALIAS" ]]; then
    line=$(grep "^${TARGET_ALIAS}|" "$QUALIFYING" 2>/dev/null || true)
    if [[ -z "$line" ]]; then
        die "Model '$TARGET_ALIAS' not found in qualifying.txt"
    fi
    models_to_eval=("$line")
    log_info "Evaluating single model: $TARGET_ALIAS"
else
    mapfile -t models_to_eval < "$QUALIFYING"
    log_info "Evaluating all ${#models_to_eval[@]} qualifying models"
fi

log_info ""

# --- Evaluate each model ---
for line in "${models_to_eval[@]}"; do
    tag=$(echo "$line" | cut -d'|' -f1)
    priority=$(echo "$line" | cut -d'|' -f2)
    safe_name=$(echo "$tag" | tr '/' '_')
    model_eval_dir="${EVAL_DIR}/${safe_name}"
    mkdir -p "$model_eval_dir"

    log_info "==> Evaluating: $tag (priority: $priority)"

    # Warmup
    echo "hello" | ollama run "$tag" >/dev/null 2>&1 || true

    for i in 0 1 2; do
        name="${EVAL_NAMES[$i]}"
        prompt="${EVAL_PROMPTS[$i]}"
        outfile="${model_eval_dir}/${name}.txt"

        log_info "    Running: $name (timeout: 120s)"
        {
            echo "=== EVAL: $tag / $name ==="
            echo "Priority: $priority"
            echo "Prompt: $prompt"
            echo "Date: $(date -Iseconds)"
            echo ""
            echo "--- RESPONSE ---"
            echo "$prompt" | timeout 120 ollama run "$tag" 2>&1
            echo ""
            echo "--- END ---"
        } > "$outfile" 2>&1

        # Check for timeout
        if grep -q "Timed out" "$outfile" 2>/dev/null; then
            log_warn "    Timed out after 120s"
        fi
    done

    log_ok "    Outputs saved: $model_eval_dir/"
    log_info ""

done

log_info "Evaluation complete. Results in: $EVAL_DIR/"
log_info ""
log_info "Scoring guide (LLM scores each 1-5):"
log_info "  reasoning:   Correct math? Shows work? Final answer right?"
log_info "  coding:      Correct code? Type hints? Docstring? Edge cases?"
log_info "  instruction: Followed format? 3 benefits + 2 drawbacks? Concise?"
log_info "  Pass threshold: 12/15 total"