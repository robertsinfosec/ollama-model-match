#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/lib/tools.sh
source "${ROOT_DIR}/src/lib/tools.sh"
YQ_BIN="${MODEL_MATCH_TEST_YQ:-$YQ_BIN}"
require_yq
# Child fixtures may use a PATH-provided Go yq. This is test-only; runtime
# scripts select their yq explicitly without changing PATH.
PATH="$(dirname "$YQ_BIN"):${PATH}"
export PATH
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
    rm -rf "$workspace/src/.tools"
    rm -f "$workspace/src/specs.yaml"
    mkdir -p "$workspace/src/results"
    printf '%s\n' "$workspace"
}

write_specs() {
    local path="$1"
    cat > "${path}/src/specs.yaml"
}

# Stateful fake with the real CLI's inventory shape and :latest normalization.
# No tests contact a real Ollama server or download models.
prepare_execution_workspace() {
    local workspace="$1"
    mkdir -p "${workspace}/bin" "${workspace}/ollama-state"
    printf 'Weekly research: test-1b, default/code/fast.\n' > "${workspace}/src/results/research.md"
    printf 'FROM user-owned\n' > "${workspace}/ollama-state/user-model:latest"
    write_specs "$workspace" <<'YAML'
hardware:
  gpu_name: Test GPU
  gpu_vendor: nvidia
  gpu_vram_gb: 4
thresholds:
  vram_headroom_gb: 1
models: []
rejected: []
candidates:
  - tag: test-1b
    source: test
    priority: high
    estimated_vram_gb: 1
YAML
    cat > "${workspace}/bin/ollama" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${OLLAMA_STATE:?}"
normalize() { [[ "$1" == *:* ]] && printf '%s\n' "$1" || printf '%s:latest\n' "$1"; }
command="$1"
shift
case "$command" in
    ls)
        printf 'NAME ID SIZE MODIFIED\n'
        find "$state" -maxdepth 1 -type f -printf '%f id size now\n'
        ;;
    pull)
        printf 'FROM upstream\n' > "${state}/$(normalize "$1")"
        [[ "${FAIL_PULL:-false}" == false ]] || exit 8
        ;;
    cp)
        if [[ "${FAIL_PUBLISH:-}" == "$2" && "$1" == omm-role-* ]]; then
            exit 8
        fi
        if [[ "${FAIL_RESTORE:-false}" == true && "$1" == omm-backup-* ]]; then
            exit 8
        fi
        cp "${state}/$(normalize "$1")" "${state}/$(normalize "$2")"
        ;;
    ps)
        printf 'NAME ID SIZE PROCESSOR CONTEXT UNTIL\n'
        for file in "$state"/*; do
            [[ -f "$file" ]] || continue
            printf '%s id 1GB %s 8192 running\n' "${file##*/}" "${PLACEMENT:-100% GPU}"
        done
        ;;
    stop) ;;
    rm)
        printf '%s\n' "$1" >> "${state}/../removals.log"
        rm -f "${state}/$(normalize "$1")"
        ;;
    create)
        if [[ -n "${FAIL_ROLE:-}" && ( "$FAIL_ROLE" == "$1" || "$1" == *-"$FAIL_ROLE" ) ]]; then
            exit 8
        fi
        destination=$(normalize "$1")
        contents=$(cat)
        source=$(awk '$1 == "FROM" {print $2; exit}' <<< "$contents")
        [[ -f "${state}/$(normalize "$source")" ]] || exit 1
        printf '%s\n' "$contents" > "${state}/${destination}"
        [[ "${FAIL_CREATE:-}" != "$1" ]] || exit 8
        ;;
    show)
        if [[ "$1" == '--modelfile' ]]; then
            printf '# Display header for %s\n' "$2"
            cat "${state}/$(normalize "$2")"
        else
            [[ -f "${state}/$(normalize "$1")" ]]
        fi
        ;;
    run)
        [[ "${FAIL_RUN:-false}" == false ]] || exit 9
        cat >/dev/null
        printf 'A complete response.\neval rate: 25.00 tokens/s\n'
        ;;
    *) exit 1 ;;
esac
SH
    cat > "${workspace}/bin/docker" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    cat > "${workspace}/bin/timeout" <<'SH'
#!/usr/bin/env bash
echo 'Unexpected execution deadline' >&2
exit 99
SH
    chmod +x "${workspace}/bin/ollama" "${workspace}/bin/docker" "${workspace}/bin/timeout"
}

run_execution_workspace() {
    local workspace="$1"
    PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" bash "${workspace}/src/10-run-unattended.sh"
}

select_test_roles() {
    local workspace="$1"
    yq -i '.models = [{"alias": "test-1b", "tag": "test-1b", "num_ctx": 8192}] | .roles = {"default": "test-1b", "fast": "test-1b", "code": "test-1b"}' "${workspace}/src/specs.yaml"
    if [[ -f "${workspace}/src/results/latest-run.txt" ]]; then
        local run
        run=$(cat "${workspace}/src/results/latest-run.txt")
        cat > "${run}/scores.yaml" <<'YAML'
models:
  - tag: test-1b
    reasoning_score: 4
    coding_score: 4
    instruction_score: 4
    measured_tok_per_sec: 25
    decision: promote
    reasons:
      reasoning: Correct response in this run.
      coding: Correct response in this run.
      instruction: Correct response in this run.
YAML
    fi
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
        ollama run native-model
        OLLAMA_BACKEND=docker
        OLLAMA_CONTAINER=test-container
        ollama run docker-model
    ' _ "$workspace"
    grep -qx 'native:run native-model' "$log" || fail "native Ollama routing failed"
    grep -qx 'docker:exec test-container ollama run docker-model' "$log" || fail "Docker Ollama routing failed"
    pass "Ollama backend routing"
}

test_unattended_runner_records_failure() {
    local workspace
    workspace=$(make_workspace "unattended-failure")
    prepare_execution_workspace "$workspace"
    cat > "${workspace}/src/03-filter.sh" <<'SH'
#!/usr/bin/env bash
printf 'test-1b|high|test|1.0|0.6\n' > "${PIPELINE_RESULTS_DIR:?}/qualifying.txt"
SH
    cat > "${workspace}/src/04-pull.sh" <<'SH'
#!/usr/bin/env bash
exit 7
SH
    chmod +x "${workspace}/src/03-filter.sh" "${workspace}/src/04-pull.sh"

    if run_execution_workspace "$workspace" >/dev/null 2>&1; then
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

test_runner_requires_research_handoff() {
    local workspace
    workspace=$(make_workspace "missing-research")
    if bash "${workspace}/src/10-run-unattended.sh" >/dev/null 2>&1; then
        fail "runner accepted missing research handoff"
    fi
    [[ ! -f "${workspace}/src/results/latest-run.txt" ]] || fail "runner began without research"
    pass "runner requires research handoff"
}

test_runner_produces_isolated_review_packet() {
    local workspace run previous
    workspace=$(make_workspace "review-packet")
    prepare_execution_workspace "$workspace"
    mkdir -p "${workspace}/src/results/bench"
    printf 'stale\n' > "${workspace}/src/results/bench/old-model.txt"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    [[ -f "$run/execution-complete" && -f "$run/eval/test-1b/coding.txt" ]] || fail "missing completed review evidence"
    [[ ! -f "$run/bench/old-model.txt" ]] || fail "stale benchmark entered review packet"
    grep -q '^user-model:latest$' "$run/models-before.txt" || fail "initial inventory missing"
    grep -q '^test-1b:latest$' "$run/managed-models.txt" || fail "managed artifact not recorded"
    grep -q "$run" "${workspace}/src/results/review.md" || fail "handoff points at wrong run"
    previous="$run"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    [[ "$run" != "$previous" && -f "$previous/execution-complete" ]] || fail "new run overwrote previous evidence"
    pass "runner produces isolated review packets without execution deadlines"
}

test_runner_does_not_publish_failed_inference() {
    local workspace run
    workspace=$(make_workspace "inference-failure")
    prepare_execution_workspace "$workspace"
    if FAIL_RUN=true run_execution_workspace "$workspace" >/dev/null 2>&1; then
        fail "runner accepted failed inference"
    fi
    run=$(cat "${workspace}/src/results/latest-run.txt")
    [[ ! -f "$run/execution-complete" ]] || fail "failed inference marked complete"
    grep -q 'FAILED | 05' "$run/status.txt" || fail "failed inference stage not recorded"
    grep -q 'NOT READY' "${workspace}/src/results/review.md" || fail "failed inference published review"
    pass "runner rejects failed inference before review"
}

test_cleanup_requires_verified_aliases_and_preserves_existing_models() {
    local workspace run
    workspace=$(make_workspace "cleanup")
    prepare_execution_workspace "$workspace"
    # A candidate present before the run must not become cleanup-owned.
    printf 'FROM existing\n' > "${workspace}/ollama-state/test-1b:latest"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    select_test_roles "$workspace"
    if PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" bash "${workspace}/src/11-cleanup.sh" "$run" >/dev/null 2>&1; then
        fail "cleanup accepted unverified role selection"
    fi
    PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" PIPELINE_RESULTS_DIR="$run" bash "${workspace}/src/08-alias.sh" >/dev/null
    PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" bash "${workspace}/src/11-cleanup.sh" "$run" >/dev/null
    [[ -f "${workspace}/ollama-state/test-1b:latest" && -f "${workspace}/ollama-state/user-model:latest" ]] || fail "cleanup removed pre-existing model"
    [[ -f "${workspace}/ollama-state/default:latest" && -f "${workspace}/ollama-state/code:latest" && -f "${workspace}/ollama-state/fast:latest" ]] || fail "cleanup removed final aliases"
    pass "cleanup requires verified roles and preserves pre-existing candidates"
}

test_cleanup_removes_new_interim_models_only() {
    local workspace run
    workspace=$(make_workspace "cleanup-new")
    prepare_execution_workspace "$workspace"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    select_test_roles "$workspace"
    PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" PIPELINE_RESULTS_DIR="$run" bash "${workspace}/src/08-alias.sh" >/dev/null
    PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" bash "${workspace}/src/11-cleanup.sh" "$run" >/dev/null
    [[ ! -f "${workspace}/ollama-state/test-1b:latest" ]] || fail "new interim model was retained"
    [[ -f "${workspace}/ollama-state/user-model:latest" && -f "${workspace}/ollama-state/default:latest" ]] || fail "cleanup removed protected model"
    pass "cleanup removes only new managed interim models"
}

test_alias_failure_blocks_cleanup() {
    local workspace run
    workspace=$(make_workspace "alias-failure")
    prepare_execution_workspace "$workspace"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    select_test_roles "$workspace"
    printf 'FROM previous-working-model\nPARAMETER num_ctx 8192\n' > "${workspace}/ollama-state/fast:latest"
    if PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" PIPELINE_RESULTS_DIR="$run" FAIL_ROLE=fast bash "${workspace}/src/08-alias.sh" >/dev/null 2>&1; then
        fail "role creation failure reported success"
    fi
    [[ ! -f "$run/aliases-verified-specs.cksum" ]] || fail "partial role rebuild authorized cleanup"
    [[ -f "${workspace}/ollama-state/test-1b:latest" ]] || fail "alias failure removed interim model"
    grep -q 'FROM previous-working-model' "${workspace}/ollama-state/fast:latest" || fail "failed rebuild removed previous role alias"
    pass "failed role creation blocks cleanup"
}

test_cleanup_rejects_changed_specs() {
    local workspace run
    workspace=$(make_workspace "changed-specs")
    prepare_execution_workspace "$workspace"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    select_test_roles "$workspace"
    PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" PIPELINE_RESULTS_DIR="$run" bash "${workspace}/src/08-alias.sh" >/dev/null
    yq -i '.models[0].num_ctx = 16384' "${workspace}/src/specs.yaml"
    if PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" bash "${workspace}/src/11-cleanup.sh" "$run" >/dev/null 2>&1; then
        fail "cleanup accepted specs modified after verification"
    fi
    [[ -f "${workspace}/ollama-state/test-1b:latest" ]] || fail "changed specs caused deletion"
    pass "cleanup rejects changed specs before any removal"
}

test_filter_honors_configured_headroom
test_filter_rejects_unknown_vram
test_discovery_survives_unavailable_sources
test_ollama_backend_routing
test_unattended_runner_records_failure
test_pull_preserves_configured_alias
test_failed_pull_removes_candidate
test_runner_requires_research_handoff
test_runner_produces_isolated_review_packet
test_runner_does_not_publish_failed_inference
test_cleanup_requires_verified_aliases_and_preserves_existing_models
test_cleanup_removes_new_interim_models_only
test_alias_failure_blocks_cleanup
test_cleanup_rejects_changed_specs

# shellcheck source=hardware.sh
source "${ROOT_DIR}/tests/hardware.sh"

# shellcheck source=prereqs.sh
source "${ROOT_DIR}/tests/prereqs.sh"
# shellcheck source=production.sh
source "${ROOT_DIR}/tests/production.sh"
