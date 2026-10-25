#!/usr/bin/env bash
set -Eeuo pipefail
# Sourced by run.sh; uses isolated workspaces and the stateful fake Ollama.

test_filter_requires_explicit_retest_for_known_models() {
    local workspace
    workspace=$(make_workspace "retest")
    prepare_execution_workspace "$workspace"
    select_test_roles "$workspace"
    yq -i '.rejected = [{"tag": "test-1b"}]' "${workspace}/src/specs.yaml"
    bash "${workspace}/src/03-filter.sh" >/dev/null
    [[ ! -s "${workspace}/src/results/qualifying.txt" ]] || fail "known model was implicitly retested"
    yq -i '.candidates[0].retest = true' "${workspace}/src/specs.yaml"
    bash "${workspace}/src/03-filter.sh" >/dev/null
    grep -q '^test-1b|' "${workspace}/src/results/qualifying.txt" || fail "explicit retest did not bypass known-model exclusions"
    pass "known models require an explicit retest decision"
}

test_large_parameter_names_do_not_match_small_suffixes() {
    local workspace
    workspace=$(make_workspace "size-boundaries")
    prepare_execution_workspace "$workspace"
    yq -i '.candidates = [{"tag": "model-32b"}, {"tag": "model-13b"}, {"tag": "mini-14b"}, {"tag": "model-a3b-30b"}]' "${workspace}/src/specs.yaml"
    bash "${workspace}/src/03-filter.sh" >/dev/null
    [[ ! -s "${workspace}/src/results/qualifying.txt" ]] || fail "large model matched a small parameter suffix"
    pass "large parameter counts never match small-model suffixes"
}

test_offloaded_models_cannot_reach_review() {
    local workspace run
    workspace=$(make_workspace "gpu-placement")
    prepare_execution_workspace "$workspace"
    if PLACEMENT='50%/50% CPU/GPU' run_execution_workspace "$workspace" > "${workspace}/output.log" 2>&1; then
        fail "offloaded model passed full-GPU verification"
    fi
    run=$(cat "${workspace}/src/results/latest-run.txt")
    [[ ! -f "$run/execution-complete" ]] || fail "offloaded model published review evidence"
    grep -q 'Full-GPU placement could not be verified' "${workspace}/output.log" || fail "placement failure not explained"
    pass "actual CPU offload prevents review on GPU-only runs"
}

test_cpu_mode_remains_explicitly_supported() {
    local workspace run
    workspace=$(make_workspace "cpu-policy")
    prepare_execution_workspace "$workspace"
    yq -i '.hardware.gpu_vendor = "none" | .hardware.gpu_vram_gb = 0' "${workspace}/src/specs.yaml"
    PLACEMENT='100% CPU' run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    [[ -f "$run/execution-complete" ]] || fail "explicit CPU-only mode regressed"
    pass "explicit CPU-only policy remains supported"
}

test_failed_pull_restores_previous_model() {
    local workspace
    workspace=$(make_workspace "pull-rollback")
    prepare_execution_workspace "$workspace"
    printf 'FROM previous-model\nPARAMETER num_ctx 8192\n' > "${workspace}/ollama-state/test-1b:latest"
    if FAIL_PULL=true run_execution_workspace "$workspace" >/dev/null 2>&1; then
        fail "failed pull was accepted"
    fi
    grep -q 'FROM previous-model' "${workspace}/ollama-state/test-1b:latest" || fail "failed pull replaced the previous model"
    pass "failed upstream pull restores the previous model"
}

test_failed_candidate_configuration_restores_previous_model() {
    local workspace
    workspace=$(make_workspace "candidate-rollback")
    prepare_execution_workspace "$workspace"
    printf 'FROM previous-model\nPARAMETER num_ctx 8192\n' > "${workspace}/ollama-state/test-1b:latest"
    if FAIL_CREATE=test-1b run_execution_workspace "$workspace" >/dev/null 2>&1; then
        fail "failed candidate configuration was accepted"
    fi
    grep -q 'FROM previous-model' "${workspace}/ollama-state/test-1b:latest" || fail "candidate failure destroyed previous model"
    pass "failed candidate rebuild restores the previous manifest"
}

test_partial_role_publication_rolls_back_all_roles() {
    local workspace run role
    workspace=$(make_workspace "role-rollback")
    prepare_execution_workspace "$workspace"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    select_test_roles "$workspace"
    for role in code default fast; do
        printf 'FROM previous-%s\nPARAMETER num_ctx 8192\n' "$role" > "${workspace}/ollama-state/${role}:latest"
    done
    if PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" PIPELINE_RESULTS_DIR="$run" FAIL_PUBLISH=fast bash "${workspace}/src/08-alias.sh" >/dev/null 2>&1; then
        fail "partial role publication reported success"
    fi
    for role in code default fast; do
        grep -q "FROM previous-${role}" "${workspace}/ollama-state/${role}:latest" || fail "previous role $role was not restored"
    done
    [[ ! -e "$run/aliases-verified-specs.cksum" ]] || fail "failed publication authorized cleanup"
    pass "partial role publication restores the entire previous role set"
}

test_failed_restoration_retains_recovery_backups() {
    local workspace run
    workspace=$(make_workspace "recovery-backups")
    prepare_execution_workspace "$workspace"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    select_test_roles "$workspace"
    printf 'FROM previous-code\nPARAMETER num_ctx 8192\n' > "${workspace}/ollama-state/code:latest"
    if PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" PIPELINE_RESULTS_DIR="$run" FAIL_PUBLISH=fast FAIL_RESTORE=true bash "${workspace}/src/08-alias.sh" > "${workspace}/output.log" 2>&1; then
        fail "failed restoration reported success"
    fi
    grep -q 'Restoration incomplete' "${workspace}/output.log" || fail "recovery failure was hidden"
    find "$run" -name recovery.txt | grep -q . || fail "recovery instructions were removed"
    find "${workspace}/ollama-state" -name 'omm-backup-*' | grep -q . || fail "recovery backups were removed"
    [[ ! -e "$run/aliases-verified-specs.cksum" ]] || fail "failed restoration authorized cleanup"
    pass "failed restoration retains backups and recovery instructions"
}

test_cleanup_detects_changed_model_identity() {
    local workspace run
    workspace=$(make_workspace "changed-role-model")
    prepare_execution_workspace "$workspace"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    select_test_roles "$workspace"
    PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" PIPELINE_RESULTS_DIR="$run" bash "${workspace}/src/08-alias.sh" >/dev/null
    printf 'FROM unexpected-model\nPARAMETER num_ctx 8192\n' > "${workspace}/ollama-state/default:latest"
    if PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" bash "${workspace}/src/11-cleanup.sh" "$run" >/dev/null 2>&1; then
        fail "cleanup accepted a changed model with the same context size"
    fi
    [[ -f "${workspace}/ollama-state/test-1b:latest" ]] || fail "identity mismatch caused interim deletion"
    pass "cleanup verifies published model identity, not just context size"
}

test_runner_lock_preserves_existing_handoff() {
    local workspace
    workspace=$(make_workspace "runner-lock")
    prepare_execution_workspace "$workspace"
    mkdir "${workspace}/src/results/.pipeline.lock"
    printf '999999999\n' > "${workspace}/src/results/.pipeline.lock/pid"
    printf 'Previous handoff\n' > "${workspace}/src/results/review.md"
    if run_execution_workspace "$workspace" >/dev/null 2>&1; then
        fail "runner ignored an existing lock"
    fi
    grep -qx 'Previous handoff' "${workspace}/src/results/review.md" || fail "blocked runner overwrote handoff"
    [[ ! -e "${workspace}/src/results/latest-run.txt" ]] || fail "blocked runner changed latest run"
    pass "concurrent runner is rejected before modifying handoff state"
}

test_unavailable_snap_falls_back_to_apt() {
    local workspace
    workspace=$(make_workspace "snap-daemon-unavailable")
    prepare_prereq_workspace "$workspace"
    SNAP_UNAVAILABLE=true run_prereq_workspace "$workspace" --yes >/dev/null 2>&1
    grep -qx 'apt-get:install -y glow' "${workspace}/install.log" || fail "unavailable Snap daemon prevented package fallback"
    ! grep -q '^snap:install' "${workspace}/install.log" || fail "unavailable Snap daemon was used for installation"
    pass "Glow falls back to apt when Snap exists but is unavailable"
}

test_failed_hardware_update_is_atomic() {
    local workspace before
    workspace=$(make_workspace "atomic-hardware")
    prepare_execution_workspace "$workspace"
    before=$(cksum < "${workspace}/src/specs.yaml")
    cat > "${workspace}/bin/free" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "${workspace}/bin/free"
    if PATH="${workspace}/bin:${PATH}" bash "${workspace}/src/01-assess.sh" >/dev/null 2>&1; then
        fail "invalid hardware data reported success"
    fi
    [[ "$before" == "$(cksum < "${workspace}/src/specs.yaml")" ]] || fail "failed assessment modified existing registry"
    rm "${workspace}/src/specs.yaml"
    if PATH="${workspace}/bin:${PATH}" bash "${workspace}/src/01-assess.sh" >/dev/null 2>&1; then
        fail "invalid new hardware data reported success"
    fi
    [[ ! -e "${workspace}/src/specs.yaml" ]] || fail "failed assessment left a partial registry"
    pass "failed hardware assessment never publishes partial specs"
}

test_release_archive_has_flat_src_layout() {
    local workspace extracted
    workspace=$(make_workspace "release-layout")
    prepare_prereq_workspace "$workspace"
    mkdir -p "${workspace}/src/.tools/bin"
    printf 'excluded\n' > "${workspace}/src/.tools/bin/private-tool"
    (cd "${workspace}/src" && zip -qr "${workspace}/release.zip" . -x 'results/*' 'specs.yaml' '*.bak' '.tools/*')
    extracted="${workspace}/extracted"
    unzip -q "${workspace}/release.zip" -d "$extracted"
    [[ -f "$extracted/README.md" && -f "$extracted/00-prereqs.sh" && -f "$extracted/lib/tools.sh" ]] || fail "release archive lacks root scripts/helpers"
    [[ ! -d "$extracted/src" && ! -f "$extracted/specs.yaml" && ! -e "$extracted/.tools/bin/private-tool" ]] || fail "release archive contains a wrapper or runtime state"
    ! grep -Eq '^(bash src/|source src/|yq .*src/specs)' "$extracted/README.md" || fail "release manual commands assume a src wrapper"
    PATH="${workspace}/bin" INSTALL_LOG="${workspace}/install.log" bash "$extracted/00-prereqs.sh" --check >/dev/null
    prepare_execution_workspace "$workspace"
    cp "${workspace}/src/specs.yaml" "$extracted/specs.yaml"
    mkdir -p "$extracted/results"
    cp "${workspace}/src/results/research.md" "$extracted/results/research.md"
    PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" bash "$extracted/10-run-unattended.sh" >/dev/null
    [[ -f "$(cat "$extracted/results/latest-run.txt")/execution-complete" ]] || fail "extracted release cannot execute its pipeline"
    pass "flat src release supports setup and deterministic execution"
}

test_yq_selection_does_not_modify_path() {
    bash -c 'before="$PATH"; source "$1/src/lib/tools.sh"; [[ "$PATH" == "$before" ]]' _ "$ROOT_DIR" || fail "dependency helper changed command search PATH"
    pass "runtime yq selection leaves all other command resolution unchanged"
}

test_minimum_yq_version_is_enforced() {
    local workspace
    workspace=$(make_workspace "old-go-yq")
    mkdir -p "${workspace}/bin"
    cat > "${workspace}/bin/old-yq" <<'SH'
#!/usr/bin/env bash
printf 'yq (https://github.com/mikefarah/yq/) version v4.44.2\n'
SH
    chmod +x "${workspace}/bin/old-yq"
    if yq_is_supported "${workspace}/bin/old-yq"; then
        fail "older untested Go yq was accepted"
    fi
    pass "minimum supported Go yq version is enforced"
}

test_apt_metadata_is_refreshed_once() {
    local workspace
    workspace=$(make_workspace "apt-refresh")
    prepare_prereq_workspace "$workspace"
    rm "${workspace}/bin/jq" "${workspace}/bin/curl" "${workspace}/bin/snap"
    run_prereq_workspace "$workspace" --yes >/dev/null 2>&1
    [[ "$(grep -c '^apt-get:update$' "${workspace}/install.log")" -eq 1 ]] || fail "apt metadata was refreshed repeatedly"
    pass "multiple package installs refresh apt metadata only once"
}

test_phase_c_requires_complete_review_evidence() {
    local workspace run
    workspace=$(make_workspace "review-validation")
    prepare_execution_workspace "$workspace"
    run_execution_workspace "$workspace" >/dev/null
    run=$(cat "${workspace}/src/results/latest-run.txt")
    select_test_roles "$workspace"
    rm "$run/scores.yaml"
    if PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" PIPELINE_RESULTS_DIR="$run" bash "${workspace}/src/08-alias.sh" >/dev/null 2>&1; then
        fail "Phase C accepted missing scores"
    fi
    select_test_roles "$workspace"
    yq -i '.models[0].measured_tok_per_sec = 999' "$run/scores.yaml"
    if PATH="${workspace}/bin:${PATH}" OLLAMA_STATE="${workspace}/ollama-state" PIPELINE_RESULTS_DIR="$run" bash "${workspace}/src/08-alias.sh" >/dev/null 2>&1; then
        fail "Phase C accepted throughput inconsistent with benchmark"
    fi
    [[ ! -f "${workspace}/ollama-state/default:latest" && ! -f "$run/aliases-verified-specs.cksum" ]] || fail "invalid review modified role aliases or authorized cleanup"
    pass "Phase C validates scores against this run before changing aliases"
}

test_human_prompts_and_agent_privileges_with_a_terminal() {
    local workspace answer command argument
    if [[ "$(uname -s)" != Linux ]] || ! command -v script >/dev/null 2>&1; then
        printf '[SKIP] PTY prompt tests require Linux util-linux script\n'
        return
    fi
    for answer in y n agent; do
        workspace=$(make_workspace "prompt-${answer}")
        prepare_prereq_workspace "$workspace"
        argument=""
        [[ "$answer" != agent ]] || argument=--yes
        printf -v command '%q PATH=%q FAKE_BIN=%q INSTALL_LOG=%q REAL_JQ=%q bash %q %q' \
            "$(command -v env)" "${workspace}/bin" "${workspace}/bin" "${workspace}/install.log" \
            "$(command -v jq)" "${workspace}/src/00-prereqs.sh" "$argument"
        printf '%s\n' "$answer" | script -qec "$command" /dev/null > "${workspace}/output.log"
        if [[ "$answer" == n ]]; then
            ! grep -q '^snap:install' "${workspace}/install.log" || fail "declining Glow still installed it"
        else
            grep -q '^snap:install glow' "${workspace}/install.log" || fail "accepted Glow install did not run"
        fi
        if [[ "$answer" == agent && "$EUID" -ne 0 ]]; then
            grep -q '^sudo:-n snap install glow' "${workspace}/install.log" || fail "agent setup used interactive sudo with a terminal"
        fi
    done
    pass "human yes/no prompts and agent noninteractive sudo work with a terminal"
}

test_filter_requires_explicit_retest_for_known_models
test_large_parameter_names_do_not_match_small_suffixes
test_offloaded_models_cannot_reach_review
test_cpu_mode_remains_explicitly_supported
test_failed_pull_restores_previous_model
test_failed_candidate_configuration_restores_previous_model
test_partial_role_publication_rolls_back_all_roles
test_failed_restoration_retains_recovery_backups
test_cleanup_detects_changed_model_identity
test_runner_lock_preserves_existing_handoff
test_unavailable_snap_falls_back_to_apt
test_failed_hardware_update_is_atomic
test_release_archive_has_flat_src_layout
test_yq_selection_does_not_modify_path
test_minimum_yq_version_is_enforced
test_apt_metadata_is_refreshed_once
test_phase_c_requires_complete_review_evidence
test_human_prompts_and_agent_privileges_with_a_terminal
