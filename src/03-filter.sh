#!/usr/bin/env bash
set -Eeuo pipefail

# 03-filter.sh — Filter candidates by assessed GPU memory or CPU-only RAM.
# Reads: specs.yaml (candidates section)
# Outputs: results/qualifying.txt
# Screens estimated memory use; GPU placement is checked after warmup.
#
# Prefers artifact-size estimates, with a tag-name fallback. Runtime fit and
# performance must still be measured.

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
# shellcheck source=lib/memory-budget.sh
source "${SCRIPT_DIR}/lib/memory-budget.sh"
read_memory_budget
if [[ "$cpu_mode" == true ]]; then
    log_warn "CPU-only mode: screening against measured RAM; inference may be slow."
    printf 'false\n' > "${RESULTS_DIR}/require-gpu.txt"
else
    printf 'true\n' > "${RESULTS_DIR}/require-gpu.txt"
fi
log_info "Memory budget: ${vram_budget}GiB (${vram_headroom}GiB headroom)"

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

    # Evaluate history inside yq: grep -q can close a large output pipe early,
    # causing a false non-match under pipefail. Explicit retests bypass history.
    # Skip if already in models (curated)
    if [[ "$retest" != true ]] && MM_TAG="$tag" yq -e \
        '[.models[].tag | select(. == strenv(MM_TAG))] | length > 0' "$SPEC_FILE" >/dev/null 2>&1; then
        log_info "SKIP (already curated): $tag"
        (( i++ )) || true
        continue
    fi

    # Skip if already in rejected
    if [[ "$retest" != true ]] && MM_TAG="$tag" yq -e \
        '[.rejected[].tag | select(. == strenv(MM_TAG))] | length > 0' "$SPEC_FILE" >/dev/null 2>&1; then
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
    total=$(estimated_runtime_memory "$vram_est")

    # Check if fits
    if awk -v t="$total" -v b="$vram_budget" 'BEGIN { exit !(t <= b) }'; then
        printf '%s|%s|%s|%s|%s\n' "$tag" "$priority" "$source" "$total" "$vram_est" >> "$QUALIFYING"
        log_ok "QUALIFY: $tag (est. ${total}GiB, priority: $priority)"
        (( qualifying_count++ )) || true
    else
        log_warn "EXCLUDE: $tag (est. ${total}GiB > ${vram_budget}GiB budget)"
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
log_warn "Memory estimates include weights and a heuristic 8K-context KV allowance."
log_warn "Qualifying models still require measured inference and GPU-placement checks."
