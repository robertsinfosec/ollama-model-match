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

# CLI-generated comments may contain the queried alias name. Compare the actual
# Modelfile body, not that display-only header, when verifying copies.
ollama_model_manifest() {
    local output body
    output=$(ollama show --modelfile "$1") || return 1
    body=$(printf '%s\n' "$output" | sed -n '/^FROM /,$p')
    [[ -n "$body" ]] || return 1
    printf '%s\n' "$body"
}

# One mutating pipeline phase per script directory. Never guess whether a stale
# lock is safe to steal; report its PID for human recovery after a crash.
acquire_pipeline_lock() {
    PIPELINE_LOCK_DIR="${SCRIPT_DIR}/results/.pipeline.lock"
    PIPELINE_OWNS_LOCK=false
    if [[ -n "${PIPELINE_LOCK_OWNER_PID:-}" && -f "${PIPELINE_LOCK_DIR}/pid" ]] &&
        [[ "$(cat "${PIPELINE_LOCK_DIR}/pid")" == "$PIPELINE_LOCK_OWNER_PID" ]] &&
        kill -0 "$PIPELINE_LOCK_OWNER_PID" 2>/dev/null; then
        return 0 # A runner owns this lock; its child stages share it.
    fi
    mkdir -p "${SCRIPT_DIR}/results"
    if ! mkdir "$PIPELINE_LOCK_DIR" 2>/dev/null; then
        printf 'Pipeline is locked (%s). Check its pid file; do not run phases concurrently.\n' "$PIPELINE_LOCK_DIR" >&2
        return 1
    fi
    printf '%s\n' "$$" > "${PIPELINE_LOCK_DIR}/pid"
    PIPELINE_OWNS_LOCK=true
    export PIPELINE_LOCK_OWNER_PID="$$"
}

release_pipeline_lock() {
    [[ "${PIPELINE_OWNS_LOCK:-false}" == true ]] || return 0
    rm -f "${PIPELINE_LOCK_DIR}/pid"
    rmdir "$PIPELINE_LOCK_DIR"
}

# Snapshot exactly the names a phase will replace. Backups use unique names and
# remain available, with a recovery manifest, if any restoration fails.
model_transaction_begin() {
    local results_dir="$1" inventory name backup i=0
    shift
    TX_DIR=$(mktemp -d "${results_dir}/transaction.XXXXXXXX") || return 1
    TX_NAMES=("$@")
    TX_BACKUPS=()
    TX_CREATED_BACKUPS=()
    inventory=$(ollama_model_names) || return 1
    for name in "${TX_NAMES[@]}"; do
        backup=""
        if grep -qxF "$(ollama_model_name "$name")" <<< "$inventory"; then
            backup="omm-backup-${TX_DIR##*/}-${i}"
            if ollama show "$backup" >/dev/null 2>&1; then
                printf 'Backup name unexpectedly exists: %s\n' "$backup" >&2
                return 1
            fi
            ollama cp "$name" "$backup" || return 1
            TX_CREATED_BACKUPS+=("$backup")
        fi
        TX_BACKUPS+=("$backup")
        printf '%s|%s\n' "$name" "$backup" >> "${TX_DIR}/recovery.txt"
        i=$((i + 1))
    done
}

model_transaction_discard() {
    local backup
    for backup in "${TX_CREATED_BACKUPS[@]}"; do
        ollama rm "$backup" || return 1
    done
    rm -f "${TX_DIR}/recovery.txt"
    rmdir "$TX_DIR"
}

model_transaction_rollback() {
    local i name backup failed=false
    for i in "${!TX_NAMES[@]}"; do
        name="${TX_NAMES[$i]}"
        backup="${TX_BACKUPS[$i]}"
        if [[ -n "$backup" ]]; then
            ollama cp "$backup" "$name" || failed=true
        elif ollama show "$name" >/dev/null 2>&1; then
            ollama rm "$name" || failed=true
        fi
    done
    if [[ "$failed" == true ]]; then
        printf 'Restoration incomplete. Backups retained; recovery manifest: %s/recovery.txt\n' "$TX_DIR" >&2
        return 1
    fi
    model_transaction_discard
}

verify_gpu_placement() {
    local tag="$1" results_dir="$2" required listing name rest
    [[ -f "${results_dir}/require-gpu.txt" ]] || {
        printf 'GPU placement policy missing. Run 03-filter.sh first.\n' >&2
        return 1
    }
    required=$(cat "${results_dir}/require-gpu.txt")
    [[ "$required" != false ]] || return 0
    [[ "$required" == true ]] || return 1
    listing=$(ollama ps) || return 1
    while read -r name rest; do
        [[ "$(ollama_model_name "$name")" == "$(ollama_model_name "$tag")" ]] || continue
        if [[ "$rest" =~ (^|[[:space:]])100%[[:space:]]+GPU([[:space:]]|$) ]]; then
            return 0
        fi
    done <<< "$listing"
    printf 'Full-GPU placement could not be verified for %s. Ollama reports:\n%s\n' "$tag" "$listing" >&2
    return 1
}
