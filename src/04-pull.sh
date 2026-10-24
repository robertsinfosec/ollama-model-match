#!/usr/bin/env bash
set -Eeuo pipefail

# 04-pull.sh — Pull upstream models, create aliases, verify context.
# Usage:
#   bash 04-pull.sh              # Pull ALL qualifying models (sequential)
#   bash 04-pull.sh <alias>      # Pull just one model
# Reads: results/qualifying.txt
# Outputs: results/pull-status.txt
#
# Pulls are sequential (one at a time) to avoid timeout issues.
# Each model takes 1-3 minutes. Re-running skips already-pulled models.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"
RESULTS_DIR="${SCRIPT_DIR}/results"
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

# --- Helper: convert tag to pull target ---
pull_target() {
    local tag="$1"
    if [[ "$tag" == */* ]]; then
        echo "hf.co/$tag"
    else
        echo "$tag"
    fi
}

# --- Determine which models to pull ---
TARGET_ALIAS="${1:-}"

if [[ -n "$TARGET_ALIAS" ]]; then
    # Single model mode
    line=$(grep "^${TARGET_ALIAS}|" "$QUALIFYING" 2>/dev/null || true)
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

log_info "Estimated time: $(( ${#models_to_pull[@]} * 2 ))-$(( ${#models_to_pull[@]} * 3 )) minutes"
log_info ""

# --- Pull each model sequentially ---
for line in "${models_to_pull[@]}"; do
    tag=$(echo "$line" | cut -d'|' -f1)
    target=$(pull_target "$tag")

    # Check if already pulled
    if grep -q "^OK|$tag$" "$STATUS" 2>/dev/null; then
        log_info "SKIP (already pulled): $tag"
        continue
    fi

    log_info "==> Pulling: $tag"
    log_info "    Target: $target"
    log_info "    This may take 1-3 minutes..."

    if ollama pull "$target" >/dev/null 2>&1; then
        echo "OK|$tag" >> "$STATUS"
        log_ok "Pulled successfully."
    else
        echo "FAIL|$tag" >> "$STATUS"
        log_err "Failed to pull $target"
        continue
    fi

    # Create alias with num_ctx
    default_context="8192"
    log_info "    Creating alias (ctx=$default_context)..."

    ollama stop "$tag" >/dev/null 2>&1 || true
    ollama rm "$tag" >/dev/null 2>&1 || true

    if printf 'FROM %s\nPARAMETER num_ctx %s\n' "$target" "$default_context" | ollama create "$tag" -f /dev/stdin >/dev/null 2>&1; then
        actual=$(ollama show --modelfile "$tag" 2>/dev/null | awk '$1=="PARAMETER" && $2=="num_ctx" {print $3; exit}')
        if [[ "$actual" == "$default_context" ]]; then
            log_ok "    Alias created and verified (ctx=$actual)"
        else
            log_warn "    Context mismatch: expected $default_context, got ${actual:-unset}"
        fi
    else
        log_err "    Failed to create alias for $tag"
        echo "CREATE_FAIL|$tag" >> "$STATUS"
    fi

    # Cleanup upstream manifest
    ollama rm "$target" >/dev/null 2>&1 || true

    log_info ""
done

log_info "=== Pull phase complete ==="
log_info "Status saved to: $STATUS"
log_info ""
log_info "Installed models:"
ollama ls | head -20