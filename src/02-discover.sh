#!/usr/bin/env bash
set -Eeuo pipefail

# 01-discover.sh — Poll sources for new model candidates.
# Reads: specs.yaml
# Updates: specs.yaml (candidates section with priority)
# Outputs: summary to stdout
#
# Priority rules:
#   - Ollama official library = high (dialed-in, tested)
#   - Smaller labs (DeepSeek, Qwen, THUDM, MiniMax, Mistral) = high
#   - Big Tech (OpenAI, Anthropic, Meta, Google) = low (cloud-first, not local)
#   - Known good families (phi, qwen, gemma, deepseek) = high
#   - Obscure/unknown orgs = low

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"

# --- Colors ---
if [[ -t 1 ]]; then
    CYAN='\033[0;36m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    CYAN='' GREEN='' YELLOW='' RED='' NC=''
fi

log_info()  { printf "${CYAN}[*]${NC} %s\n" "$*"; }
log_ok()    { printf "${GREEN}[+]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
log_err()   { printf "${RED}[-]${NC} %s\n" "$*" >&2; }
die() { log_err "$*"; exit 1; }

[[ -f "$SPEC_FILE" ]] || die "specs.yaml not found."

# --- Read known tags ---
known_tags() {
    yq -r '.models[].tag // empty' "$SPEC_FILE" 2>/dev/null
    yq -r '.rejected[].tag // empty' "$SPEC_FILE" 2>/dev/null
    yq -r '.candidates[].tag // empty' "$SPEC_FILE" 2>/dev/null
}

is_known() {
    local tag="$1"
    known_tags | grep -qxF "$tag"
}

# --- Exclusion patterns ---
EXCLUDE_PATTERN='vision|embed|all-minilm|nomic|bge-|e5-|rerank|clip|whisper|tts|stt|audio|image|minicpm-v|llava|moondream|7b|8b|12b|14b|26b|32b|70b'

# --- Size filter: only 2B-4B models ---
SIZE_PATTERN='2b|3b|4b|1\.5b|mini|tiny|lite'

# --- Priority scoring ---
# Returns: high, medium, or low
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
    if echo "$name" | grep -qiE 'phi|qwen|gemma|deepseek|coder'; then
        echo "high"
        return
    fi

    # Obscure = medium (worth a look)
    echo "medium"
}

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

today=$(date +%Y-%m-%d)

# --- Source 1: Ollama library ---
log_info "Polling Ollama library..."
curl -s https://ollama.com/library 2>/dev/null | \
    grep -oP 'href="/library/\K[^"]+' | sort -u | \
    while read -r name; do
        echo "$name" | grep -qiE "$EXCLUDE_PATTERN" && continue
        echo "$name" | grep -qiE "$SIZE_PATTERN" || continue
        echo "ollama||$name" >> "$tmpfile"
    done

# --- Source 2: HuggingFace orgs (smaller labs) ---
log_info "Polling HuggingFace orgs..."
ORGS="deepseek-ai Qwen THUDM MiniMaxAI mistralai"
for org in $ORGS; do
    curl -s "https://huggingface.co/api/models?author=${org}&search=gguf&limit=10" 2>/dev/null | \
        jq -r '.[].modelId // empty' 2>/dev/null | \
        while read -r model; do
            name=$(echo "$model" | sed 's|.*/||')
            echo "$name" | grep -qiE "$EXCLUDE_PATTERN" && continue
            echo "$name" | grep -qiE "$SIZE_PATTERN" || continue
            echo "hf|$org|$model" >> "$tmpfile"
        done
done

# --- Source 3: HuggingFace recent GGUFs (limited) ---
log_info "Polling HuggingFace recent GGUFs..."
curl -s "https://huggingface.co/api/models?search=gguf&sort=createdAt&limit=20" 2>/dev/null | \
    jq -r '.[] | select(.tags // [] | contains(["gguf"])) | .modelId' 2>/dev/null | \
    while read -r model; do
        name=$(echo "$model" | sed 's|.*/||')
        echo "$name" | grep -qiE "$EXCLUDE_PATTERN" && continue
        echo "$name" | grep -qiE "$SIZE_PATTERN" || continue
        echo "hf-trending||$model" >> "$tmpfile"
    done

# --- Filter known and deduplicate ---
log_info "Filtering known models and scoring priority..."

sort -u "$tmpfile" | while IFS='|' read -r source org name; do
    # Determine tag
    if [[ "$source" == "ollama" ]]; then
        tag="$name"
        org="ollama"
    elif [[ "$source" == "hf" ]]; then
        tag="$name"
    else
        tag="$name"
        org="hf-trending"
    fi

    # Skip if already known
    if is_known "$tag"; then
        continue
    fi

    # Score priority
    priority=$(score_priority "$source" "$org" "$name")

    # Append to candidates with priority
    yq -iy ".candidates += [{\"tag\": \"$tag\", \"source\": \"$source\", \"org\": \"$org\", \"priority\": \"$priority\", \"discovered\": \"$today\", \"status\": \"new\"}]" "$SPEC_FILE"

    case "$priority" in
        high)   log_ok "NEW [$priority]: $tag (from $source)" ;;
        medium) log_info "NEW [$priority]: $tag (from $source)" ;;
        low)    log_warn "NEW [$priority]: $tag (from $source)" ;;
    esac
done

# --- Summary ---
log_info ""
total=$(yq -r '.candidates | length' "$SPEC_FILE")
high=$(yq -r '[.candidates[] | select(.priority == "high")] | length' "$SPEC_FILE")
medium=$(yq -r '[.candidates[] | select(.priority == "medium")] | length' "$SPEC_FILE")
low=$(yq -r '[.candidates[] | select(.priority == "low")] | length' "$SPEC_FILE")
log_info "Discovery complete. Total candidates: $total (high: $high, medium: $medium, low: $low)"