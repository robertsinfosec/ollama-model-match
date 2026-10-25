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
# shellcheck source=lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"
require_yq
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"
RESULTS_DIR="${PIPELINE_RESULTS_DIR:-${SCRIPT_DIR}/results}"

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

# shellcheck source=lib/ollama.sh
source "${SCRIPT_DIR}/lib/ollama.sh"
acquire_pipeline_lock
# A failed or partial rebuild cannot authorize cleanup using an old receipt.
rm -f "${RESULTS_DIR}/aliases-verified-specs.cksum" "${RESULTS_DIR}/aliases-verified-manifests.txt"

stages=()
stage_dir=""
commit_pending=false
finish_aliases() {
    local code=$? stage
    trap - EXIT
    if [[ "$commit_pending" == true ]]; then
        model_transaction_rollback || code=1
    fi
    for stage in "${stages[@]}"; do
        ollama rm "$stage" >/dev/null 2>&1 || code=1
    done
    [[ -z "$stage_dir" ]] || rmdir "$stage_dir" || code=1
    if [[ "$code" -ne 0 ]]; then
        rm -f "${RESULTS_DIR}/aliases-verified-specs.cksum"
    fi
    release_pipeline_lock || code=1
    exit "$code"
}
trap finish_aliases EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

detect_ollama || die "No Ollama found."
ollama ls >/dev/null || die "Cannot connect to Ollama."

validate_review() {
    local review models minimum tag safe_name recorded measured total decision prompt model
    [[ -n "${PIPELINE_RESULTS_DIR:-}" ]] || return 0 # Standalone utility mode.
    [[ -f "${RESULTS_DIR}/execution-complete" && -f "${RESULTS_DIR}/scores.yaml" ]] || die "A completed run and scores.yaml are required for Phase C."
    review=$(yq -o=json '.' "${RESULTS_DIR}/scores.yaml") || die "Invalid scores.yaml."
    models=$(yq -o=json '.models // []' "$SPEC_FILE")
    minimum=$(yq -r '.thresholds.min_tok_per_sec // 15' "$SPEC_FILE")
    [[ "$minimum" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Invalid throughput threshold."
    jq -e '
      (.models | type == "array" and length > 0) and
      ([.models[].tag] | length == (unique | length)) and
      all(.models[];
        (.tag | type == "string" and length > 0) and
        all(.reasoning_score, .coding_score, .instruction_score;
          type == "number" and . >= 1 and . <= 5 and floor == .) and
        (.measured_tok_per_sec | type == "number" and . > 0) and
        (.decision == "promote" or .decision == "reject") and
        all(.reasons.reasoning, .reasons.coding, .reasons.instruction;
          type == "string" and length > 0))
    ' <<< "$review" >/dev/null || die "Scores must contain unique tags, integer scores 1–5, throughput, decisions, and reasons."
    [[ "$(jq 'length' <<< "$models")" == "$(jq '[.[].alias] | unique | length' <<< "$models")" ]] || die "Duplicate model aliases in specs.yaml."
    [[ "$(jq '.models | length' <<< "$review")" -eq "$(wc -l < "${RESULTS_DIR}/qualifying.txt")" ]] || die "Scores must cover exactly this run's qualifying models."
    while IFS='|' read -r tag _; do
        safe_name="${tag//\//_}"
        recorded=$(jq -c --arg tag "$tag" '.models[] | select(.tag == $tag)' <<< "$review")
        [[ -n "$recorded" ]] || die "Missing scores for $tag."
        for prompt in reasoning coding instruction; do
            grep -qx -- '--- END ---' "${RESULTS_DIR}/eval/${safe_name}/${prompt}.txt" || die "Incomplete evaluation for $tag/$prompt."
        done
        measured=$(awk '$1 == "eval" && $2 == "rate:" {print $3; exit}' "${RESULTS_DIR}/bench/${safe_name}.txt")
        [[ "$measured" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Missing benchmark throughput for $tag."
        jq -e --argjson measured "$measured" '.measured_tok_per_sec == $measured' <<< "$recorded" >/dev/null || die "Recorded throughput differs from benchmark for $tag."
        total=$(jq '.reasoning_score + .coding_score + .instruction_score' <<< "$recorded")
        decision=$(jq -r '.decision' <<< "$recorded")
        if (( total >= 12 )) && awk -v m="$measured" -v t="$minimum" 'BEGIN {exit !(m >= t)}'; then
            [[ "$decision" == promote ]] || die "Decision contradicts passing thresholds for $tag."
        else
            [[ "$decision" == reject ]] || die "Decision contradicts failing thresholds for $tag."
        fi
    done < "${RESULTS_DIR}/qualifying.txt"
    while IFS= read -r model; do
        tag=$(jq -r --arg model "$model" '[.[] | select(.alias == $model) | .tag] | if length == 1 then .[0] else empty end' <<< "$models")
        [[ -n "$tag" ]] || die "Selected model '$model' is missing or ambiguous."
        jq -e --arg tag "$tag" 'any(.models[]; .tag == $tag and .decision == "promote")' <<< "$review" >/dev/null || die "Selected model '$model' lacks passing evidence in this run."
    done < <(yq -r '.roles[] | select(. != null)' "$SPEC_FILE")
}
validate_review

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
            yq -r ".models[$i].num_ctx // .models[$i].context // 8192" "$SPEC_FILE"
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
    local destination="$3"

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

    # Prefer the evaluated local candidate; avoid downloading it again.
    local target
    if ollama show "$tag" >/dev/null 2>&1; then
        target="$tag"
    elif [[ "$tag" == */* ]]; then
        target="hf.co/$tag"
    else
        target="$tag"
    fi

    if ! ollama show "$target" >/dev/null 2>&1; then
        if [[ -n "${PIPELINE_RESULTS_DIR:-}" ]]; then
            log_err "    Evaluated model '$target' is unavailable. Return to the human; do not download during Phase C."
            return 1
        fi
        log_info "    Pulling $target..."
        if ! ollama pull "$target" >/dev/null 2>&1; then
            log_err "    Failed to pull $target"
            return 1
        fi
    fi

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
    if printf '%s\n' "$modelfile" | ollama create "$destination" -f /dev/stdin >/dev/null 2>&1; then
        local actual
        actual=$(ollama show --modelfile "$destination" 2>/dev/null | awk '$1=="PARAMETER" && $2=="num_ctx" {print $3; exit}')
        if [[ "$actual" == "$context" ]]; then
            log_ok "    Created and verified (ctx=$actual)"
        else
            log_warn "    Context mismatch: expected $context, got ${actual:-unset}"
            return 1
        fi
    else
        log_err "    Failed to create alias '$role'"
        return 1
    fi

    # Cleanup is a separate, inventory-bounded step after all roles verify.
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
failed=0
selected_roles=()
expected_manifests=()
stage_dir=$(mktemp -d "${RESULTS_DIR}/aliases.XXXXXXXX")

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

    case "$role" in
        default|fast|code|thinking|frontier|cyber|uncensored) ;;
        *) die "Unknown role '$role'; no role aliases have been changed." ;;
    esac
    stage="omm-role-${stage_dir##*/}-${role}"
    if ollama show "$stage" >/dev/null 2>&1; then
        die "Staging alias unexpectedly exists: $stage"
    fi
    stages+=("$stage")
    if create_role_alias "$role" "$model_alias" "$stage"; then
        (( created++ )) || true
        selected_roles+=("$role")
        expected_manifests+=("$(ollama_model_manifest "$stage")")
    else
        log_warn "Failed to create alias for role: $role"
        (( failed++ )) || true
    fi
    log_info ""
done

[[ "$failed" -eq 0 && "$created" -gt 0 ]] || die "Role preparation failed or no roles selected; existing aliases were not changed."
model_transaction_begin "$RESULTS_DIR" "${selected_roles[@]}" || die "Cannot snapshot current role aliases; recovery files: ${TX_DIR:-unavailable}"
commit_pending=true
for i in "${!selected_roles[@]}"; do
    role="${selected_roles[$i]}"
    ollama stop "$role" >/dev/null 2>&1 || true
    ollama cp "${stages[$i]}" "$role" || die "Cannot publish $role; restoring previous roles."
    actual_manifest=$(ollama_model_manifest "$role") || die "Cannot verify published role $role."
    [[ "$actual_manifest" == "${expected_manifests[$i]}" ]] || die "Published model/config mismatch for $role; restoring previous roles."
done
commit_pending=false
model_transaction_discard || die "Roles verified, but backup cleanup failed."

log_info "=== Alias creation complete ==="
log_info "Created: $created | Skipped: $skipped"
log_info ""
log_info "Installed models:"
ollama ls
if [[ -z "$TARGET_ROLE" ]]; then
    for i in "${!selected_roles[@]}"; do
        printf '%s|%s\n' "${selected_roles[$i]}" "$(printf '%s' "${expected_manifests[$i]}" | cksum)" >> "${RESULTS_DIR}/aliases-verified-manifests.txt"
    done
    cksum < "$SPEC_FILE" > "${RESULTS_DIR}/aliases-verified-specs.cksum"
fi
