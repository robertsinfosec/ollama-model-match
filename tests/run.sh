#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

make_workspace() {
    local name="$1"
    local workspace="${TEST_ROOT}/${name}"
    mkdir -p "$workspace"
    cp -a "${ROOT_DIR}/src" "$workspace/src"
    rm -rf "$workspace/src/results"
    mkdir -p "$workspace/src/results"
    printf '%s\n' "$workspace"
}

write_specs() {
    local path="$1"
    cat > "${path}/src/specs.yaml"
}

test_filter_honors_configured_headroom() {
    local workspace
    workspace=$(make_workspace "filter-headroom")
    write_specs "$workspace" <<'YAML'
hardware:
  gpu_name: Test GPU
  gpu_vendor: nvidia
  gpu_vram_gb: 4
thresholds:
  vram_headroom_gb: 2.0
models: []
rejected: []
candidates:
  - tag: test-3b
    source: test
    priority: high
YAML

    (cd "$workspace/src" && bash 03-filter.sh >/dev/null)
    [[ ! -s "${workspace}/src/results/qualifying.txt" ]] || fail "filter ignored configured VRAM headroom"
    pass "filter honors configured VRAM headroom"
}

test_filter_rejects_unknown_vram() {
    local workspace
    workspace=$(make_workspace "filter-unknown-vram")
    write_specs "$workspace" <<'YAML'
hardware:
  gpu_name: Test GPU
  gpu_vendor: nvidia
  gpu_vram_gb: 24
thresholds:
  vram_headroom_gb: 1.0
models: []
rejected: []
candidates:
  - tag: ambiguous-model-name
    source: test
    priority: high
YAML

    (cd "$workspace/src" && bash 03-filter.sh >/dev/null)
    [[ ! -s "${workspace}/src/results/qualifying.txt" ]] || fail "filter accepted a model with unknown VRAM"
    pass "filter rejects unknown VRAM"
}

test_discovery_survives_unavailable_sources() {
    local workspace fake_bin
    workspace=$(make_workspace "discovery-failure")
    fake_bin="${workspace}/bin"
    mkdir -p "$fake_bin"
    write_specs "$workspace" <<'YAML'
hardware:
  gpu_vram_gb: 4
thresholds:
  vram_headroom_gb: 1.0
models: []
rejected: []
candidates: []
YAML
    cat > "${fake_bin}/curl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "${fake_bin}/curl"

    (cd "$workspace/src" && PATH="${fake_bin}:${PATH}" bash 02-discover.sh >/dev/null)
    pass "discovery survives unavailable sources"
}

test_ollama_backend_routing() {
    local workspace fake_bin log
    workspace=$(make_workspace "backend-routing")
    fake_bin="${workspace}/bin"
    log="${workspace}/commands.log"
    mkdir -p "$fake_bin"
    cat > "${fake_bin}/ollama" <<'SH'
#!/usr/bin/env bash
printf 'native:%s\n' "$*" >> "${OLLAMA_TEST_LOG:?}"
SH
    cat > "${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker:%s\n' "$*" >> "${OLLAMA_TEST_LOG:?}"
SH
    chmod +x "${fake_bin}/ollama" "${fake_bin}/docker"

    PATH="${fake_bin}:${PATH}" OLLAMA_TEST_LOG="$log" bash -c '
        source "$1/src/lib/ollama.sh"
        OLLAMA_BACKEND=native
        ollama_with_timeout 5 run native-model
        OLLAMA_BACKEND=docker
        OLLAMA_CONTAINER=test-container
        ollama_with_timeout 5 run docker-model
    ' _ "$workspace"
    grep -qx 'native:run native-model' "$log" || fail "native Ollama routing failed"
    grep -qx 'docker:exec test-container ollama run docker-model' "$log" || fail "Docker Ollama routing failed"
    pass "Ollama backend routing"
}

test_unattended_runner_records_failure() {
    local workspace
    workspace=$(make_workspace "unattended-failure")
    cat > "${workspace}/src/03-filter.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "${workspace}/src/04-pull.sh" <<'SH'
#!/usr/bin/env bash
exit 7
SH
    chmod +x "${workspace}/src/03-filter.sh" "${workspace}/src/04-pull.sh"

    if (cd "$workspace/src" && bash 10-run-unattended.sh >/dev/null 2>&1); then
        fail "unattended runner continued after a failed stage"
    fi
    grep -qE 'FAILED \| 04 \| 04-pull.sh \| exit=7' "${workspace}/src/results/unattended-status.txt" || fail "unattended runner did not record the failure"
    pass "unattended runner records failure"
}

test_pull_preserves_configured_alias() {
    local workspace fake_bin state
    workspace=$(make_workspace "pull-alias")
    fake_bin="${workspace}/bin"
    state="${workspace}/ollama-state"
    mkdir -p "$fake_bin" "$state"
    write_specs "$workspace" <<'YAML'
hardware: {}
thresholds: {}
models: []
rejected: []
candidates:
  - tag: phi4-mini
    source: test
    priority: high
YAML
    printf 'phi4-mini|high|test|1.0|0.6\n' > "${workspace}/src/results/qualifying.txt"
    cat > "${fake_bin}/ollama" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${OLLAMA_STATE:?}"
command="$1"
shift
case "$command" in
    ls) find "$state" -maxdepth 1 -type f -printf '%f\n' ;;
    pull) printf 'FROM upstream\n' > "${state}/$1" ;;
    stop) ;;
    rm) rm -f "${state}/$1" ;;
    create)
        destination="$1"
        shift 2
        contents=$(cat)
        source=$(printf '%s\n' "$contents" | awk '$1 == "FROM" { print $2; exit }')
        [[ -f "${state}/${source}" ]] || exit 1
        printf '%s\n' "$contents" > "${state}/${destination}"
        ;;
    show)
        if [[ "$1" == "--modelfile" ]]; then
            cat "${state}/$2"
        else
            [[ -f "${state}/$1" ]]
        fi
        ;;
    *) exit 1 ;;
esac
SH
    chmod +x "${fake_bin}/ollama"

    (cd "$workspace/src" && PATH="${fake_bin}:${PATH}" OLLAMA_STATE="$state" bash 04-pull.sh >/dev/null)
    [[ -f "${state}/phi4-mini" ]] || fail "pull removed the configured alias"
    grep -qx 'PARAMETER num_ctx 8192' "${state}/phi4-mini" || fail "pull did not configure num_ctx"
    ! find "$state" -maxdepth 1 -type f -name 'omm-source-*' | grep -q . || fail "temporary source alias was not cleaned up"
    grep -qx 'OK|phi4-mini' "${workspace}/src/results/pull-status.txt" || fail "successful pull was not recorded"
    pass "pull preserves configured alias"
}

test_failed_pull_removes_candidate() {
    local workspace fake_bin
    workspace=$(make_workspace "pull-failure")
    fake_bin="${workspace}/bin"
    mkdir -p "$fake_bin"
    write_specs "$workspace" <<'YAML'
hardware: {}
thresholds: {}
models: []
rejected: []
candidates:
  - tag: unavailable-model
    source: test
    priority: high
YAML
    printf 'unavailable-model|high|test|1.0|0.6\n' > "${workspace}/src/results/qualifying.txt"
    cat > "${fake_bin}/ollama" <<'SH'
#!/usr/bin/env bash
case "$1" in
    ls) exit 0 ;;
    pull) exit 1 ;;
    *) exit 1 ;;
esac
SH
    chmod +x "${fake_bin}/ollama"

    (cd "$workspace/src" && PATH="${fake_bin}:${PATH}" bash 04-pull.sh >/dev/null)
    [[ ! -s "${workspace}/src/results/qualifying.txt" ]] || fail "failed pull remained in qualifying models"
    yq -e '.candidates | length == 0' "${workspace}/src/specs.yaml" >/dev/null || fail "failed pull remained a candidate"
    grep -qx 'FAIL|unavailable-model' "${workspace}/src/results/pull-status.txt" || fail "failed pull was not recorded"
    pass "failed pull removes candidate"
}

test_filter_honors_configured_headroom
test_filter_rejects_unknown_vram
test_discovery_survives_unavailable_sources
test_ollama_backend_routing
test_unattended_runner_records_failure
test_pull_preserves_configured_alias
test_failed_pull_removes_candidate
