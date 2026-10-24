#!/usr/bin/env bash
set -Eeuo pipefail

# 02-filter.sh — Filter candidates by VRAM budget.
# Reads: specs.yaml (candidates section)
# Outputs: results/qualifying.txt
# Only models that fit 100% in GPU pass (no CPU offload).
#
# VRAM is ESTIMATED from model tag name (param count).
# LLM should verify estimates before pulling.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"
RESULTS_DIR="${SCRIPT_DIR}/results"
QUALIFYING="${RESULTS_DIR}/qualifying.txt"

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

# --- Hardware specs ---
gpu_vram=$(yq -r '.hardware.gpu_vram_gb' "$SPEC_FILE")
gpu_vendor=$(yq -r '.hardware.gpu_vendor // "none"' "$SPEC_FILE")

if [[ "$gpu_vram" == "0" || "$gpu_vendor" == "none" || "$gpu_vendor" == "snapdragon" ]]; then
    log_warn "No usable GPU detected (CPU-only mode)."
    log_warn "All candidates will pass filter. Expect very slow inference (1-5 tok/s)."
    log_info ""
    vram_budget="999"  # Pass everything
else
    vram_budget=$(awk -v v="$gpu_vram" 'BEGIN { printf "%.1f", v - 1.0 }')
    log_info "Filtering candidates by VRAM budget"
    log_info "GPU: ${gpu_vram}GB | Budget: ${vram_budget}GB (1.0GB headroom)"
    log_info ""
fi

# --- Estimate VRAM from tag name ---
estimate_vram() {
    local tag="$1"
    local lower
    lower=$(echo "$tag" | tr '[:upper:]' '[:lower:]')

    # Extract parameter count from name
    if echo "$lower" | grep -qE '1\.5b'; then
        echo "1.2"
    elif echo "$lower" | grep -qE '2b'; then
        echo "1.5"
    elif echo "$lower" | grep -qE '3b'; then
        echo "2.0"
    elif echo "$lower" | grep -qE '4b'; then
        echo "2.6"
    elif echo "$lower" | grep -qiE 'mini'; then
        echo "1.5"
    elif echo "$lower" | grep -qiE 'tiny'; then
        echo "0.8"
    else
        echo "2.6"  # default to 4B estimate
    fi
}

# --- KV cache estimate (conservative: 0.05 GB per 1K context) ---
KV_PER_1K="0.05"
DEFAULT_CONTEXT="8192"

# --- Check candidates exist ---
candidate_count=$(yq -r '.candidates | length' "$SPEC_FILE" 2>/dev/null || echo "0")
if [[ "$candidate_count" == "0" || "$candidate_count" == "null" ]]; then
    log_warn "No candidates in specs.yaml. Run 01-discover.sh first."
    exit 0
fi

# --- Filter ---
qualifying_count=0
excluded_count=0

: > "$QUALIFYING"

i=0
while (( i < candidate_count )); do
    tag=$(yq -r ".candidates[$i].tag" "$SPEC_FILE")
    priority=$(yq -r ".candidates[$i].priority // \"medium\"" "$SPEC_FILE")
    source=$(yq -r ".candidates[$i].source // \"unknown\"" "$SPEC_FILE")

    # Skip if already in models (curated)
    if yq -r '.models[].tag' "$SPEC_FILE" 2>/dev/null | grep -qxF "$tag"; then
        log_info "SKIP (already curated): $tag"
        (( i++ )) || true
        continue
    fi

    # Skip if already in rejected
    if yq -r '.rejected[].tag' "$SPEC_FILE" 2>/dev/null | grep -qxF "$tag"; then
        log_info "SKIP (already rejected): $tag"
        (( i++ )) || true
        continue
    fi

    # Estimate VRAM
    vram_est=$(estimate_vram "$tag")
    kv_cache=$(awk -v k="$KV_PER_1K" -v c="$DEFAULT_CONTEXT" 'BEGIN { printf "%.2f", (c/1000)*k }')
    total=$(awk -v v="$vram_est" -v k="$kv_cache" 'BEGIN { printf "%.2f", v+k }')

    # Check if fits
    if awk -v t="$total" -v b="$vram_budget" 'BEGIN { exit !(t <= b) }'; then
        printf '%s|%s|%s|%s|%s\n' "$tag" "$priority" "$source" "$total" "$vram_est" >> "$QUALIFYING"
        log_ok "QUALIFY: $tag (est. ${total}GB, priority: $priority)"
        (( qualifying_count++ )) || true
    else
        log_warn "EXCLUDE: $tag (est. ${total}GB > ${vram_budget}GB budget)"
        (( excluded_count++ )) || true
    fi

    (( i++ )) || true
done

log_info ""
log_info "Filtering complete."
log_info "Qualifying: $qualifying_count"
log_info "Excluded:   $excluded_count"
log_info "Output:     $QUALIFYING"
log_info ""
log_warn "NOTE: VRAM estimates are heuristic (from tag name)."
log_warn "LLM should verify estimates against model metadata before pulling."
log_info ""
log_info "HARDWARE-AWARE NOTE:"
log_info "On large machines (32GB+ VRAM), many models will qualify."
log_info "The LLM should prefer LARGER models for 'frontier' and 'default' roles."
log_info "Small models (1B-3B) should only be used for the 'fast' role."