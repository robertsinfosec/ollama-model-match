#!/usr/bin/env bash
set -Eeuo pipefail

# 11-cleanup.sh — Remove only new artifacts managed by a completed run.
# Usage: bash src/11-cleanup.sh <run-directory>
# Final role aliases must already exist and match specs.yaml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"
RUN_DIR="${1:?Usage: bash 11-cleanup.sh <run-directory>}"
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

for file in execution-complete models-before.txt managed-models.txt backend.txt aliases-verified-specs.cksum; do
    [[ -f "${RUN_DIR}/${file}" ]] || die "Missing run artifact: $file"
done
[[ "$(cat "${RUN_DIR}/aliases-verified-specs.cksum")" == "$(cksum < "$SPEC_FILE")" ]] || die "Rebuild all role aliases from the current specs before cleanup."

# shellcheck source=lib/ollama.sh
source "${SCRIPT_DIR}/lib/ollama.sh"
detect_ollama || die "No Ollama found."
[[ "$(cat "${RUN_DIR}/backend.txt")" == "${OLLAMA_BACKEND}|${OLLAMA_CONTAINER}|${OLLAMA_HOST:-}" ]] || die "Ollama backend differs from this run."

# Validate the whole selection before deleting anything. Missing evidence or
# an incomplete selection must never turn into destructive cleanup.
roles_json=$(yq -c '.roles // {} | with_entries(select(.value != null))' "$SPEC_FILE")
count=$(jq 'length' <<< "$roles_json")
(( count >= 3 && count <= 6 )) || die "Select and verify 3–6 convenience aliases before cleanup."
mapfile -t roles < <(jq -r 'keys[]' <<< "$roles_json")
for role in "${roles[@]}"; do
    case "$role" in
        default|fast|code|thinking|frontier|cyber|uncensored) ;;
        *) die "Unknown convenience role: $role" ;;
    esac
    model=$(jq -r --arg role "$role" '.[$role]' <<< "$roles_json")
    context=$(yq -r --arg model "$model" '[.models[] | select(.alias == $model) | (.num_ctx // .context // 8192)] | if length == 1 then .[0] else empty end' "$SPEC_FILE")
    [[ "$context" =~ ^[1-9][0-9]*$ ]] || die "Missing or invalid config for $role."
    actual=$(ollama show --modelfile "$role") || die "Cannot verify $role."
    actual_context=$(awk '$1 == "PARAMETER" && $2 == "num_ctx" { print $3; exit }' <<< "$actual")
    [[ "$actual_context" == "$context" ]] || die "Context verification failed for $role."
done

while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    # Pre-existing names and final role aliases are never eligible.
    grep -qxF "$name" "${RUN_DIR}/models-before.txt" && continue
    keep=false
    for role in "${roles[@]}"; do
        [[ "$name" != "$(ollama_model_name "$role")" ]] || keep=true
    done
    [[ "$keep" == false ]] || continue
    if ollama show "$name" >/dev/null 2>&1; then
        ollama rm "$name"
        printf '%s\n' "$name" >> "${RUN_DIR}/removed-models.txt"
    fi
done < <(sort -u "${RUN_DIR}/managed-models.txt")

printf 'Cleanup complete; pre-existing models and final role aliases preserved.\n'
