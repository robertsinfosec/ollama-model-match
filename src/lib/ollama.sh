#!/usr/bin/env bash
# Shared Ollama backend helpers. Source from pipeline scripts; do not execute.

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
                OLLAMA_BACKEND=docker
                OLLAMA_CONTAINER="$id"
                return 0
            done <<<"$containers"
        fi
    fi

    if [[ -n "$(type -P ollama)" ]]; then
        OLLAMA_BACKEND=native
    else
        return 1
    fi
}

ollama() {
    if [[ "$OLLAMA_BACKEND" == "docker" ]]; then
        docker exec "$OLLAMA_CONTAINER" ollama "$@"
    else
        command ollama "$@"
    fi
}

# Ollama displays untagged references with :latest. Normalize before comparing
# inventories so cleanup never mistakes a pre-existing model for a new one.
ollama_model_name() {
    local name="$1"
    [[ "${name##*/}" == *:* ]] || name="${name}:latest"
    printf '%s\n' "$name"
}

ollama_model_names() {
    local listing name
    listing=$(ollama ls) || return "$?"
    while read -r name; do
        [[ -n "$name" ]] || continue
        ollama_model_name "$name"
    done < <(printf '%s\n' "$listing" | awk 'NR > 1 {print $1}')
}
