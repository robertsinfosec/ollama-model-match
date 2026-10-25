#!/usr/bin/env bash
set -Eeuo pipefail

# 02-discover.sh — Poll sources for new model candidates.
# Reads: specs.yaml (hardware section for VRAM budget)
# Updates: specs.yaml (candidates section with priority)
# Outputs: summary to stdout
#
# Discovery is hardware-aware: searches for models that fit the VRAM budget.
# On 4GB: searches 2B-4B models. On 128GB: searches 32B-70B+ models.
# Always includes small models (1B-3B) for the "fast" role.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"
require_yq
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"

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

[[ -f "$SPEC_FILE" ]] || die "specs.yaml not found. Run 01-assess.sh first."

# --- Read hardware specs ---
gpu_vram=$(yq -r '.hardware.gpu_vram_gb' "$SPEC_FILE")
vram_headroom=$(yq -r '.thresholds.vram_headroom_gb // 1.0' "$SPEC_FILE")
vram_budget=$(awk -v v="$gpu_vram" -v h="$vram_headroom" 'BEGIN { printf "%.0f", v - h }')

# --- Calculate size tiers based on VRAM budget ---
# Always include small models (1B-3B) for "fast" role.
# Include larger models based on available VRAM.
build_size_pattern() {
    local budget="$1"
    local pattern="1b|2b|3b|1\.5b|mini|tiny|lite"

    if (( budget >= 4 )); then
        pattern="$pattern|4b"
    fi
    if (( budget >= 8 )); then
        pattern="$pattern|7b|8b"
    fi
    if (( budget >= 16 )); then
        pattern="$pattern|12b|13b|14b"
    fi
    if (( budget >= 24 )); then
        pattern="$pattern|27b|32b"
    fi
    if (( budget >= 48 )); then
        pattern="$pattern|70b|72b"
    fi
    if (( budget >= 96 )); then
        pattern="$pattern|100b|120b|405b"
    fi
    echo "$pattern"
}

build_exclude_pattern() {
    local budget="$1"
    local exclude="vision|embed|all-minilm|nomic|bge-|e5-|rerank|clip|whisper|tts|stt|audio|image|minicpm-v|llava|moondream"

    # Exclude models that are clearly too big for the budget
    if (( budget < 4 )); then
        exclude="$exclude|3b|4b|7b|8b|12b|14b|27b|32b|70b|72b|100b|120b|405b"
    elif (( budget < 8 )); then
        exclude="$exclude|7b|8b|12b|14b|27b|32b|70b|72b|100b|120b|405b"
    elif (( budget < 16 )); then
        exclude="$exclude|14b|27b|32b|70b|72b|100b|120b|405b"
    elif (( budget < 24 )); then
        exclude="$exclude|27b|32b|70b|72b|100b|120b|405b"
    elif (( budget < 48 )); then
        exclude="$exclude|70b|72b|100b|120b|405b"
    elif (( budget < 96 )); then
        exclude="$exclude|100b|120b|405b"
    fi
    echo "$exclude"
}

SIZE_PATTERN=$(build_size_pattern "$vram_budget")
EXCLUDE_PATTERN=$(build_exclude_pattern "$vram_budget")

log_info "Polling sources for models fitting ${vram_budget}GB VRAM budget"
log_info "Reserved headroom: ${vram_headroom}GB"
log_info "Size tiers: $SIZE_PATTERN"
log_info ""

# --- Read known tags ---
known_tags() {
    yq -r '.models[].tag | select(. != null)' "$SPEC_FILE"
    yq -r '.rejected[].tag | select(. != null)' "$SPEC_FILE"
    yq -r '.candidates[].tag | select(. != null)' "$SPEC_FILE"
}

is_known() {
    local tag="$1"
    known_tags | grep -qxF "$tag"
}

# --- Priority scoring ---
score_priority() {
    local source="$1"
    local org="$2"
    local name="$3"

    # Big Tech = low (cloud-first, not local)
    if echo "$org" | grep -qiE 'openai|anthropic|meta-llama|google'; then
        echo "low"
        return
    fi

    # Ollama official library = high (dialed-in, tested)
    if [[ "$source" == "ollama" ]]; then
        echo "high"
        return
    fi

    # Smaller labs = high
    if echo "$org" | grep -qiE 'deepseek|qwen|thudm|minimax|mistral'; then
        echo "high"
        return
    fi

    # Known good families = high
    if echo "$name" | grep -qiE 'phi|qwen|gemma|deepseek|coder|llama'; then
        echo "high"
        return
    fi

    echo "medium"
}

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

today=$(date +%Y-%m-%d)

# --- Source 1: Ollama library ---
log_info "Polling Ollama library..."
if library_html=$(curl -fsSL https://ollama.com/library 2>/dev/null); then
    while read -r name; do
        [[ -n "$name" ]] || continue
        echo "$name" | grep -qiE "$EXCLUDE_PATTERN" && continue
        echo "$name" | grep -qiE "$SIZE_PATTERN" || continue
        echo "ollama||$name" >> "$tmpfile"
    done < <(printf '%s\n' "$library_html" | grep -oP 'href="/library/\K[^"]+' | sort -u || true)
else
    log_warn "Could not retrieve the Ollama library; continuing with other sources."
fi

# --- Source 2: HuggingFace orgs (smaller labs) ---
log_info "Polling HuggingFace orgs..."
ORGS="deepseek-ai Qwen THUDM MiniMaxAI mistralai"
for org in $ORGS; do
    if models_json=$(curl -fsSL "https://huggingface.co/api/models?author=${org}&search=gguf&limit=15" 2>/dev/null); then
        while read -r model; do
            [[ -n "$model" ]] || continue
            name=$(echo "$model" | sed 's|.*/||')
            echo "$name" | grep -qiE "$EXCLUDE_PATTERN" && continue
            echo "$name" | grep -qiE "$SIZE_PATTERN" || continue
            echo "hf|$org|$model" >> "$tmpfile"
        done < <(printf '%s\n' "$models_json" | jq -r '.[].modelId // empty' 2>/dev/null || true)
    else
        log_warn "Could not retrieve HuggingFace models for ${org}; continuing."
    fi
done

# --- Source 3: HuggingFace recent GGUFs (limited) ---
log_info "Polling HuggingFace recent GGUFs..."
if recent_json=$(curl -fsSL "https://huggingface.co/api/models?search=gguf&sort=createdAt&limit=30" 2>/dev/null); then
    while read -r model; do
        [[ -n "$model" ]] || continue
        name=$(echo "$model" | sed 's|.*/||')
        echo "$name" | grep -qiE "$EXCLUDE_PATTERN" && continue
        echo "$name" | grep -qiE "$SIZE_PATTERN" || continue
        echo "hf-trending||$model" >> "$tmpfile"
    done < <(printf '%s\n' "$recent_json" | jq -r '.[] | select(.tags // [] | contains(["gguf"])) | .modelId' 2>/dev/null || true)
else
    log_warn "Could not retrieve recent HuggingFace GGUFs; continuing."
fi

# --- Filter known and deduplicate ---
log_info "Filtering known models and scoring priority..."

sort -u "$tmpfile" | while IFS='|' read -r source org name; do
    if [[ "$source" == "ollama" ]]; then
        tag="$name"
        org="ollama"
    elif [[ "$source" == "hf" ]]; then
        tag="$name"
    else
        tag="$name"
        org="hf-trending"
    fi

    if is_known "$tag"; then
        continue
    fi

    priority=$(score_priority "$source" "$org" "$name")

    MM_TAG="$tag" MM_SOURCE="$source" MM_ORG="$org" MM_PRIORITY="$priority" MM_DATE="$today" \
    yq -i '.candidates += [{"tag": strenv(MM_TAG), "source": strenv(MM_SOURCE), "org": strenv(MM_ORG), "priority": strenv(MM_PRIORITY), "discovered": strenv(MM_DATE), "status": "new"}]' "$SPEC_FILE"

    case "$priority" in
        high)   log_ok "NEW [high]: $tag (from $source)" ;;
        medium) log_info "NEW [medium]: $tag (from $source)" ;;
        low)    log_warn "NEW [low]: $tag (from $source)" ;;
    esac
done

# --- Summary ---
log_info ""
total=$(yq -r '.candidates | length' "$SPEC_FILE")
high=$(yq -r '[.candidates[] | select(.priority == "high")] | length' "$SPEC_FILE")
medium=$(yq -r '[.candidates[] | select(.priority == "medium")] | length' "$SPEC_FILE")
low=$(yq -r '[.candidates[] | select(.priority == "low")] | length' "$SPEC_FILE")
log_info "Discovery complete. Total candidates: $total (high: $high, medium: $medium, low: $low)"
log_info "VRAM budget: ${vram_budget}GB | Size tiers: $SIZE_PATTERN"
