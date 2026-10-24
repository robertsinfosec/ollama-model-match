#!/usr/bin/env bash
set -Eeuo pipefail

# 08-update.sh — Rebuild a single model alias with current specs.yaml config.
# Usage: bash 08-update.sh <alias>
# Reads: specs.yaml (models section)
# Outputs: updated alias in Ollama
#
# Guardrails: validates all config values before attempting update.
# Fails fast with clear messages if config is invalid or unsupported.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

[[ -f "$SPEC_FILE" ]] || die "specs.yaml not found."

# --- Parse arguments ---
ALIAS="${1:-}"
if [[ -z "$ALIAS" ]]; then
    log_err "Usage: bash 08-update.sh <alias>"
    log_err "Example: bash 08-update.sh code"
    exit 1
fi

# --- Find model in specs.yaml ---
model_index=""
count=$(yq -r '.models | length' "$SPEC_FILE" 2>/dev/null || echo "0")
i=0
while (( i < count )); do
    found_alias=$(yq -r ".models[$i].alias" "$SPEC_FILE")
    if [[ "$found_alias" == "$ALIAS" ]]; then
        model_index=$i
        break
    fi
    (( i++ )) || true
done

if [[ -z "$model_index" ]]; then
    die "Model '$ALIAS' not found in specs.yaml models section."
fi

# --- Read model config ---
tag=$(yq -r ".models[$model_index].tag" "$SPEC_FILE")
context=$(yq -r ".models[$model_index].context // 8192" "$SPEC_FILE")
thinking=$(yq -r ".models[$model_index].thinking // false" "$SPEC_FILE")
thinking_effort=$(yq -r ".models[$model_index].thinking_effort // null" "$SPEC_FILE")
roles=$(yq -r ".models[$model_index].roles // [] | join(\", \")" "$SPEC_FILE")

log_info "Model: $ALIAS"
log_info "Tag: $tag"
log_info "Context: $context"
log_info "Thinking: $thinking"
log_info "Thinking effort: $thinking_effort"
log_info "Roles: $roles"
log_info ""

# --- Guardrail 1: Validate context is a positive integer ---
if ! [[ "$context" =~ ^[1-9][0-9]*$ ]]; then
    die "Invalid context value: '$context'. Must be a positive integer (e.g., 8192, 32768)."
fi

# Warn if context is very large
if [[ "$context" -gt 131072 ]]; then
    log_warn "Context $context is very large. May cause OOM or load failure."
    log_warn "Consider starting with a smaller value and increasing incrementally."
fi

# --- Guardrail 2: Validate thinking is boolean ---
if [[ "$thinking" != "true" && "$thinking" != "false" ]]; then
    die "Invalid thinking value: '$thinking'. Must be 'true' or 'false'."
fi

# --- Guardrail 3: Validate thinking_effort ---
if [[ "$thinking" == "true" ]]; then
    if [[ "$thinking_effort" != "null" && "$thinking_effort" != "low" && "$thinking_effort" != "medium" && "$thinking_effort" != "high" ]]; then
        die "Invalid thinking_effort: '$thinking_effort'. Must be 'low', 'medium', 'high', or null."
    fi
else
    if [[ "$thinking_effort" != "null" ]]; then
        die "thinking is false but thinking_effort is set to '$thinking_effort'. Set thinking_effort to null or set thinking to true."
    fi
fi

# --- Guardrail 4: Warn about thinking support ---
if [[ "$thinking" == "true" ]]; then
    log_warn "Thinking requested. Not all Ollama models support thinking mode."
    log_warn "If the model doesn't support it, Ollama will ignore the parameter silently."
    log_warn "Verify by checking the model's response for <think> tags."
fi

# --- Guardrail 5: Check tag is non-empty ---
if [[ -z "$tag" || "$tag" == "null" ]]; then
    die "Model '$ALIAS' has no tag defined in specs.yaml."
fi

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

# --- Determine pull target ---
pull_target() {
    local tag="$1"
    if [[ "$tag" == */* ]]; then
        echo "hf.co/$tag"
    else
        echo "$tag"
    fi
}

target=$(pull_target "$tag")

# --- Phase 1: Pull upstream (if not already present) ---
log_info "Checking if upstream model is available..."
if ! ollama ls 2>/dev/null | grep -q "$target"; then
    log_info "Pulling $target..."
    if ! ollama pull "$target"; then
        die "Failed to pull $target. Check the tag name in specs.yaml."
    fi
    log_ok "Pulled successfully."
else
    log_ok "Upstream already available."
fi

# --- Phase 2: Stop and remove old alias ---
log_info "Removing old alias '$ALIAS'..."
ollama stop "$ALIAS" >/dev/null 2>&1 || true
ollama rm "$ALIAS" >/dev/null 2>&1 || true

# --- Phase 3: Create alias with new config ---
log_info "Creating alias '$ALIAS' (ctx=$context, thinking=$thinking)..."

# Build Modelfile
modelfile="FROM $target
PARAMETER num_ctx $context"

if [[ "$thinking" == "true" ]]; then
    modelfile="$modelfile
PARAMETER think true"
    if [[ "$thinking_effort" != "null" ]]; then
        modelfile="$modelfile
PARAMETER thinking_effort $thinking_effort"
    fi
fi

if printf '%s\n' "$modelfile" | ollama create "$ALIAS" -f /dev/stdin >/dev/null 2>&1; then
    log_ok "Alias created."
else
    die "Failed to create alias. Check Modelfile parameters."
fi

# --- Phase 4: Verify ---
log_info "Verifying..."

actual_context=$(ollama show --modelfile "$ALIAS" 2>/dev/null | awk '$1=="PARAMETER" && $2=="num_ctx" {print $3; exit}')
if [[ "$actual_context" == "$context" ]]; then
    log_ok "Context verified: $actual_context"
else
    log_warn "Context mismatch: expected $context, got ${actual_context:-unset}"
fi

# --- Phase 5: Quick smoke test ---
log_info "Running smoke test..."
response=$(echo "Say hello in one sentence." | ollama run "$ALIAS" 2>&1 | head -5)
if [[ -n "$response" ]]; then
    log_ok "Smoke test passed."
    echo ""
    echo "Response preview:"
    echo "$response" | head -3
else
    log_warn "Smoke test produced no output. Model may have issues."
fi

log_info ""
log_ok "Update complete: $ALIAS"
log_info "Config: ctx=$context, thinking=$thinking, effort=$thinking_effort"