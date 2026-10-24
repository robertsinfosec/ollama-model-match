#!/usr/bin/env bash
set -Eeuo pipefail

# 08-alias.sh — Create friendly role-based aliases from specs.yaml.
# Usage:
#   bash 08-alias.sh              # Create all role aliases
#   bash 08-alias.sh <role>       # Create just one role alias (e.g., default)
# Reads: specs.yaml (roles section + models section)
# Outputs: aliases in Ollama with num_ctx and thinking config
#
# The LLM assigns roles during Step 07 (Score & Promote).
# This script creates the friendly aliases (default, code, fast, etc.)
# based on those assignments.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"
RESULTS_DIR="${SCRIPT_DIR}/results"

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

# --- Read a model's config from specs.yaml ---
get_model_config() {
    local model_alias="$1"
    local count i=0
    count=$(yq -r '.models | length' "$SPEC_FILE" 2>/dev/null || echo "0")
    while (( i < count )); do
        local found
        found=$(yq -r ".models[$i].alias" "$SPEC_FILE")
        if [[ "$found" == "$model_alias" ]]; then
            yq -r ".models[$i].tag" "$SPEC_FILE"
            yq -r ".models[$i].context // 8192" "$SPEC_FILE"
            yq -r ".models[$i].thinking // false" "$SPEC_FILE"
            yq -r ".models[$i].thinking_effort // null" "$SPEC_FILE"
            return 0
        fi
        (( i++ )) || true
    done
    return 1
}

# --- Create alias for a role ---
create_role_alias() {
    local role="$1"
    local model_alias="$2"

    # Read model config
    local config
    config=$(get_model_config "$model_alias") || {
        log_warn "Model '$model_alias' not found in specs.yaml. Skipping role '$role'."
        return 1
    }

    local tag context thinking thinking_effort
    tag=$(echo "$config" | sed -n '1p')
    context=$(echo "$config" | sed -n '2p')
    thinking=$(echo "$config" | sed -n '3p')
    thinking_effort=$(echo "$config" | sed -n '4p')

    log_info "==> Creating alias: $role → $model_alias (ctx=$context, thinking=$thinking)"

    # Pull upstream if not available
    local target
    if [[ "$tag" == */* ]]; then
        target="hf.co/$tag"
    else
        target="$tag"
    fi

    if ! ollama ls 2>/dev/null | grep -q "$target"; then
        log_info "    Pulling $target..."
        if ! ollama pull "$target" >/dev/null 2>&1; then
            log_err "    Failed to pull $target"
            return 1
        fi
    fi

    # Stop/remove old alias
    ollama stop "$role" >/dev/null 2>&1 || true
    ollama rm "$role" >/dev/null 2>&1 || true

    # Build Modelfile
    local modelfile
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

    # Create alias
    if printf '%s\n' "$modelfile" | ollama create "$role" -f /dev/stdin >/dev/null 2>&1; then
        local actual
        actual=$(ollama show --modelfile "$role" 2>/dev/null | awk '$1=="PARAMETER" && $2=="num_ctx" {print $3; exit}')
        if [[ "$actual" == "$context" ]]; then
            log_ok "    Created and verified (ctx=$actual)"
        else
            log_warn "    Context mismatch: expected $context, got ${actual:-unset}"
        fi
    else
        log_err "    Failed to create alias '$role'"
        return 1
    fi

    # Cleanup upstream
    ollama rm "$target" >/dev/null 2>&1 || true
}

# --- Determine which roles to create ---
TARGET_ROLE="${1:-}"

log_info "Creating role-based aliases from specs.yaml"
log_info ""

# Read roles from specs.yaml
roles_count=$(yq -r '.roles | length' "$SPEC_FILE" 2>/dev/null || echo "0")
if [[ "$roles_count" == "0" || "$roles_count" == "null" ]]; then
    die "No roles defined in specs.yaml. Run Step 07 (Score & Promote) first."
fi

# Get all role names
mapfile -t role_names < <(yq -r '.roles | keys[]' "$SPEC_FILE" 2>/dev/null)

created=0
skipped=0

for role in "${role_names[@]}"; do
    model_alias=$(yq -r ".roles.$role" "$SPEC_FILE" 2>/dev/null)

    # Skip if role is null or empty
    if [[ "$model_alias" == "null" || -z "$model_alias" ]]; then
        log_info "SKIP: $role (not assigned)"
        (( skipped++ )) || true
        continue
    fi

    # If targeting a specific role, skip others
    if [[ -n "$TARGET_ROLE" && "$role" != "$TARGET_ROLE" ]]; then
        continue
    fi

    if create_role_alias "$role" "$model_alias"; then
        (( created++ )) || true
    else
        log_warn "Failed to create alias for role: $role"
    fi
    log_info ""
done

log_info "=== Alias creation complete ==="
log_info "Created: $created | Skipped: $skipped"
log_info ""
log_info "Installed models:"
ollama ls