#!/usr/bin/env bash
set -Eeuo pipefail

# 04-pull.sh — Pull upstream models, create aliases, verify context.
# Usage:
#   bash 04-pull.sh              # Pull ALL qualifying models (sequential)
#   bash 04-pull.sh <alias>      # Pull just one model
# Reads: results/qualifying.txt
# Outputs: results/pull-status.txt
#
# Pulls are sequential (one at a time), without execution deadlines.
# Re-running in the same results directory skips already-pulled models.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"
RESULTS_DIR="${PIPELINE_RESULTS_DIR:-${SCRIPT_DIR}/results}"
QUALIFYING="${RESULTS_DIR}/qualifying.txt"
STATUS="${RESULTS_DIR}/pull-status.txt"

mkdir -p "$RESULTS_DIR"

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

# shellcheck source=lib/ollama.sh
source "${SCRIPT_DIR}/lib/ollama.sh"

detect_ollama || die "No Ollama found."
ollama ls >/dev/null || die "Cannot connect to Ollama."

# --- Helper: convert tag to pull target ---
pull_target() {
    local tag="$1"
    if [[ "$tag" == */* ]]; then
        echo "hf.co/$tag"
    else
        echo "$tag"
    fi
}

find_qualifying_model() {
    awk -F'|' -v tag="$1" '$1 == tag { print; exit }' "$QUALIFYING"
}

remove_failed_candidate() {
    local tag="$1"
    local tmp_qualifying
    tmp_qualifying=$(mktemp)
    awk -F'|' -v candidate="$tag" '$1 != candidate' "$QUALIFYING" > "$tmp_qualifying"
    mv "$tmp_qualifying" "$QUALIFYING"
    yq -iy --arg tag "$tag" 'del(.candidates[] | select(.tag == $tag))' "$SPEC_FILE"
}

# --- Determine which models to pull ---
TARGET_ALIAS="${1:-}"

if [[ -n "$TARGET_ALIAS" ]]; then
    # Single model mode
    line=$(find_qualifying_model "$TARGET_ALIAS")
    if [[ -z "$line" ]]; then
        die "Model '$TARGET_ALIAS' not found in qualifying.txt"
    fi
    models_to_pull=("$line")
    log_info "Pulling single model: $TARGET_ALIAS"
else
    # All models mode
    mapfile -t models_to_pull < "$QUALIFYING"
    log_info "Pulling all ${#models_to_pull[@]} qualifying models (sequential)"
fi

log_info ""

# --- Pull each model sequentially ---
for line in "${models_to_pull[@]}"; do
    tag=$(echo "$line" | cut -d'|' -f1)
    target=$(pull_target "$tag")

    # Check if already pulled
    if awk -F'|' -v candidate="$tag" '$1 == "OK" && $2 == candidate { found = 1 } END { exit !found }' "$STATUS" 2>/dev/null; then
        log_info "SKIP (already pulled): $tag"
        continue
    fi

    log_info "==> Pulling: $tag"
    log_info "    Target: $target"
    log_info "    Waiting for Ollama; download duration depends on network and model size."

    if ollama pull "$target" >/dev/null 2>&1; then
        ollama_model_name "$target" >> "${RESULTS_DIR}/managed-models.txt"
        log_ok "Pulled successfully."
    else
        echo "FAIL|$tag" >> "$STATUS"
        log_err "Failed to pull $target"
        remove_failed_candidate "$tag"
        continue
    fi

    # Create a temporary source alias so the configured alias can safely use the
    # same name as an upstream Ollama tag.
    default_context="8192"
    source_alias="omm-source-$(printf '%s' "$tag" | cksum | awk '{print $1}')"
    log_info "    Creating alias (ctx=$default_context)..."

    ollama rm "$source_alias" >/dev/null 2>&1 || true
    if ! printf 'FROM %s\n' "$target" | ollama create "$source_alias" -f /dev/stdin >/dev/null 2>&1; then
        log_err "    Failed to create temporary source alias for $target"
        echo "CREATE_FAIL|$tag" >> "$STATUS"
        continue
    fi
    ollama_model_name "$source_alias" >> "${RESULTS_DIR}/managed-models.txt"

    ollama stop "$tag" >/dev/null 2>&1 || true
    ollama rm "$tag" >/dev/null 2>&1 || true
    if [[ "$target" != "$tag" ]]; then
        ollama rm "$target" >/dev/null 2>&1 || true
    fi

    if printf 'FROM %s\nPARAMETER num_ctx %s\n' "$source_alias" "$default_context" | ollama create "$tag" -f /dev/stdin >/dev/null 2>&1; then
        ollama_model_name "$tag" >> "${RESULTS_DIR}/managed-models.txt"
        actual=$(ollama show --modelfile "$tag" 2>/dev/null | awk '$1=="PARAMETER" && $2=="num_ctx" {print $3; exit}')
        if [[ "$actual" == "$default_context" ]]; then
            log_ok "    Alias created and verified (ctx=$actual)"
            echo "OK|$tag" >> "$STATUS"
        else
            log_warn "    Context mismatch: expected $default_context, got ${actual:-unset}"
            echo "CREATE_FAIL|$tag" >> "$STATUS"
        fi
    else
        log_err "    Failed to create alias for $tag"
        echo "CREATE_FAIL|$tag" >> "$STATUS"
    fi

    # Cleanup the temporary source manifest. The configured alias remains.
    ollama rm "$source_alias" >/dev/null 2>&1 || true

    log_info ""
done

log_info "=== Pull phase complete ==="
log_info "Status saved to: $STATUS"
log_info ""
log_info "Installed models:"
ollama ls | head -20
