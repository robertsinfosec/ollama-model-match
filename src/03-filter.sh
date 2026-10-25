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
# shellcheck source=lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"
require_yq
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"
RESULTS_DIR="${PIPELINE_RESULTS_DIR:-${SCRIPT_DIR}/results}"
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
vram_headroom=$(yq -r '.thresholds.vram_headroom_gb // 1.0' "$SPEC_FILE")

if [[ "$gpu_vram" == "0" || "$gpu_vendor" == "none" || "$gpu_vendor" == "snapdragon" ]]; then
    log_warn "No usable GPU detected (CPU-only mode)."
    log_warn "All candidates will pass filter. Expect very slow inference (1-5 tok/s)."
    log_info ""
    vram_budget="999"  # Pass everything
    printf 'false\n' > "${RESULTS_DIR}/require-gpu.txt"
else
    vram_budget=$(awk -v v="$gpu_vram" -v h="$vram_headroom" 'BEGIN { printf "%.1f", v - h }')
    log_info "Filtering candidates by VRAM budget"
    log_info "GPU: ${gpu_vram}GB | Budget: ${vram_budget}GB (${vram_headroom}GB headroom)"
    log_info ""
    printf 'true\n' > "${RESULTS_DIR}/require-gpu.txt"
fi

# --- Estimate VRAM from tag name ---
estimate_vram() {
    local tag="$1"
    local lower sizes
    lower=$(echo "$tag" | tr '[:upper:]' '[:lower:]')
    sizes=$(printf '%s\n' "$lower" | grep -oE '[0-9]+([.][0-9]+)?b' || true)
    if [[ "$(printf '%s\n' "$sizes" | grep -c . || true)" -gt 1 ]]; then
        echo "unknown" # Ambiguous total/active MoE sizes require metadata.
        return
    fi

    # Extract parameter count from name
    if [[ "$lower" =~ (^|[^0-9.])([0-9]+([.][0-9]+)?)b([^a-z0-9]|$) ]]; then
        # Match a complete size, not the '2b' suffix of '32b'. Preserve the
        # existing estimates; unrecognized sizes require artifact metadata.
        case "${BASH_REMATCH[2]}" in
            1.5) echo "1.2" ;;
            2) echo "1.5" ;;
            3) echo "2.0" ;;
            4) echo "2.6" ;;
            *) echo "unknown" ;;
        esac
    elif echo "$lower" | grep -qiE 'mini'; then
        echo "1.5"
    elif echo "$lower" | grep -qiE 'tiny'; then
        echo "0.8"
    else
        echo "unknown"
    fi
}

# --- KV cache estimate (conservative: 0.05 GB per 1K context) ---
KV_PER_1K="0.05"
DEFAULT_CONTEXT="8192"

# --- Check candidates exist ---
: > "$QUALIFYING"
candidate_count=$(yq -r '.candidates | length' "$SPEC_FILE" 2>/dev/null || echo "0")
if [[ "$candidate_count" == "0" || "$candidate_count" == "null" ]]; then
    log_warn "No candidates in specs.yaml. Run 02-discover.sh first."
    exit 0
fi

# --- Filter ---
qualifying_count=0
excluded_count=0

i=0
while (( i < candidate_count )); do
    tag=$(yq -r ".candidates[$i].tag" "$SPEC_FILE")
    priority=$(yq -r ".candidates[$i].priority // \"medium\"" "$SPEC_FILE")
    source=$(yq -r ".candidates[$i].source // \"unknown\"" "$SPEC_FILE")
    configured_vram=$(yq -r ".candidates[$i].estimated_vram_gb // \"null\"" "$SPEC_FILE")
    retest=$(yq -r ".candidates[$i].retest // false" "$SPEC_FILE")

    # Skip if already in models (curated)
    if [[ "$retest" != true ]] && yq -r '.models[].tag' "$SPEC_FILE" 2>/dev/null | grep -qxF "$tag"; then
        log_info "SKIP (already curated): $tag"
        (( i++ )) || true
        continue
    fi

    # Skip if already in rejected
    if [[ "$retest" != true ]] && yq -r '.rejected[].tag' "$SPEC_FILE" 2>/dev/null | grep -qxF "$tag"; then
        log_info "SKIP (already rejected): $tag"
        (( i++ )) || true
        continue
    fi

    # Prefer a verified artifact-size estimate supplied during discovery. Fall
    # back to a name heuristic only for recognizable model sizes.
    if [[ "$configured_vram" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v v="$configured_vram" 'BEGIN {exit !(v > 0)}'; then
        vram_est="$configured_vram"
    else
        vram_est=$(estimate_vram "$tag")
    fi
    if [[ "$vram_est" == "unknown" ]]; then
        log_warn "EXCLUDE: $tag (no VRAM estimate; add estimated_vram_gb from model metadata)"
        (( excluded_count++ )) || true
        (( i++ )) || true
        continue
    fi
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
