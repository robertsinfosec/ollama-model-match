#!/usr/bin/env bash
set -Eeuo pipefail
# Sourced by tests/run.sh. Every installer command is mocked here.

prepare_prereq_workspace() {
    local workspace="$1" tool
    mkdir -p "${workspace}/bin"
    # An isolated PATH prevents tests from seeing host optional tools or making
    # real package-manager calls. yq/jq themselves are the actual test versions.
    for tool in bash dirname uname grep head xargs ls cat chmod ln rm mktemp sha256sum date; do
        ln -s "$(command -v "$tool")" "${workspace}/bin/${tool}"
    done
    ln -s "$YQ_BIN" "${workspace}/bin/yq"
    ln -s "$(command -v jq)" "${workspace}/bin/jq"
    cat > "${workspace}/bin/ollama" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "${workspace}/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl:%s\n' "$*" >> "${INSTALL_LOG:?}"
[[ "${1:-}" != --version ]] || exit 0
exit 1
SH
    cat > "${workspace}/bin/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo:%s\n' "$*" >> "${INSTALL_LOG:?}"
[[ "${1:-}" != -n ]] || shift
exec "$@"
SH
    cat > "${workspace}/bin/snap" <<'SH'
#!/usr/bin/env bash
printf 'snap:%s\n' "$*" >> "${INSTALL_LOG:?}"
if [[ "${1:-}" == list ]]; then
    [[ "${SNAP_UNAVAILABLE:-false}" == false ]]
    exit $?
fi
[[ "${FAIL_INSTALL:-false}" == false ]] || exit 8
printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN:?}/glow"
chmod +x "${FAKE_BIN}/glow"
SH
    cat > "${workspace}/bin/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get:%s\n' "$*" >> "${INSTALL_LOG:?}"
[[ "${FAIL_INSTALL:-false}" == false ]] || exit 8
if [[ "$1" == install ]]; then
    case "$3" in
        jq) ln -s "${REAL_JQ:?}" "${FAKE_BIN:?}/jq" ;;
        curl)
            printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]]\n' > "${FAKE_BIN:?}/curl"
            chmod +x "${FAKE_BIN}/curl"
            ;;
        glow)
            printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN:?}/glow"
            chmod +x "${FAKE_BIN}/glow"
            ;;
        *) exit 1 ;;
    esac
fi
SH
    chmod +x "${workspace}/bin/"{ollama,curl,sudo,snap,apt-get}
}

run_prereq_workspace() {
    local workspace="$1"
    shift
    REAL_JQ="$(command -v jq)" PATH="${workspace}/bin" FAKE_BIN="${workspace}/bin" \
        INSTALL_LOG="${workspace}/install.log" bash "${workspace}/src/00-prereqs.sh" "$@"
}

test_prereqs_check_never_installs_optional_tools() {
    local workspace
    workspace=$(make_workspace "prereqs-check")
    prepare_prereq_workspace "$workspace"
    run_prereq_workspace "$workspace" --check > "${workspace}/output.log" 2>&1
    ! grep -Eq '^(apt-get:|snap:install|sudo:)' "${workspace}/install.log" || fail "check-only mode invoked an installer"
    grep -q 'glow: NOT FOUND (optional)' "${workspace}/output.log" || fail "missing Glow was not explained"
    pass "prereqs check reports optional Glow without installing or failing"
}

test_prereqs_noninteractive_default_does_not_hang() {
    local workspace
    workspace=$(make_workspace "prereqs-no-tty")
    prepare_prereq_workspace "$workspace"
    run_prereq_workspace "$workspace" </dev/null > "${workspace}/output.log" 2>&1
    ! grep -Eq '^(apt-get:|snap:install|sudo:)' "${workspace}/install.log" || fail "default noninteractive mode installed a tool"
    grep -q 'Run with --yes' "${workspace}/output.log" || fail "noninteractive guidance missing"
    pass "noninteractive prerequisites explain --yes instead of waiting for input"
}

test_prereqs_yes_installs_glow_and_missing_required_tools() {
    local workspace
    workspace=$(make_workspace "prereqs-yes")
    prepare_prereq_workspace "$workspace"
    rm "${workspace}/bin/jq"
    run_prereq_workspace "$workspace" --yes > "${workspace}/output.log" 2>&1
    grep -qx 'snap:install glow' "${workspace}/install.log" || fail "--yes did not install Glow via Snap"
    grep -qx 'apt-get:install -y jq' "${workspace}/install.log" || fail "--yes did not install missing jq"
    [[ -x "${workspace}/bin/glow" && -x "${workspace}/bin/jq" ]] || fail "installed utilities missing"
    pass "--yes accepts optional Glow and required package installs"
}

test_prereqs_glow_uses_package_manager_without_snap() {
    local workspace
    workspace=$(make_workspace "prereqs-glow-apt")
    prepare_prereq_workspace "$workspace"
    rm "${workspace}/bin/snap"
    run_prereq_workspace "$workspace" --yes > "${workspace}/output.log" 2>&1
    grep -qx 'apt-get:install -y glow' "${workspace}/install.log" || fail "Glow package-manager fallback missing"
    pass "Glow uses package manager when Snap is absent"
}

test_prereqs_optional_install_failure_is_nonfatal() {
    local workspace
    workspace=$(make_workspace "prereqs-glow-failure")
    prepare_prereq_workspace "$workspace"
    FAIL_INSTALL=true run_prereq_workspace "$workspace" --yes > "${workspace}/output.log" 2>&1
    grep -q 'glow installation failed' "${workspace}/output.log" || fail "optional install failure not reported"
    pass "optional Glow install failure does not break prerequisites"
}

test_prereqs_required_install_failure_is_fatal() {
    local workspace
    workspace=$(make_workspace "prereqs-required-failure")
    prepare_prereq_workspace "$workspace"
    rm "${workspace}/bin/jq"
    if FAIL_INSTALL=true run_prereq_workspace "$workspace" --yes > "${workspace}/output.log" 2>&1; then
        fail "required dependency installation failure was ignored"
    fi
    grep -q 'Missing required tools' "${workspace}/output.log" || fail "required failure guidance missing"
    pass "required dependency installation failure prevents execution"
}

test_python_yq_is_rejected_without_modifying_specs() {
    local workspace before
    workspace=$(make_workspace "prereqs-python-yq")
    prepare_prereq_workspace "$workspace"
    write_specs "$workspace" <<'YAML'
hardware: {gpu_vram_gb: 4, gpu_vendor: nvidia}
models: []
rejected: []
candidates: []
YAML
    rm "${workspace}/bin/yq"
    cat > "${workspace}/bin/yq" <<'SH'
#!/usr/bin/env bash
echo 'yq 3.4.3'
SH
    chmod +x "${workspace}/bin/yq"
    if run_prereq_workspace "$workspace" --check > "${workspace}/output.log" 2>&1; then
        fail "Python yq was accepted as Mike Farah yq"
    fi
    grep -q 'unsupported implementation' "${workspace}/output.log" || fail "wrong yq implementation not identified"
    before=$(cksum < "${workspace}/src/specs.yaml")
    if PATH="${workspace}/bin" bash "${workspace}/src/03-filter.sh" > "${workspace}/filter.log" 2>&1; then
        fail "filter ran with unsupported yq"
    fi
    [[ "$before" == "$(cksum < "${workspace}/src/specs.yaml")" ]] || fail "unsupported yq modified specs"
    grep -q 'Mike Farah yq v4 is required' "${workspace}/filter.log" || fail "direct script lacks dependency guidance"
    ! grep -Eq '^(apt-get:|snap:install|sudo:)' "${workspace}/install.log" || fail "check-only mode tried to replace Python yq"
    pass "Python yq is rejected before pipeline execution"
}

test_yq_installer_rejects_bad_checksums() {
    local workspace
    workspace=$(make_workspace "yq-checksum")
    prepare_prereq_workspace "$workspace"
    cat > "${workspace}/bin/curl" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then
        printf '#!/usr/bin/env bash\necho malicious\n' > "$2"
        exit 0
    fi
    shift
done
exit 1
SH
    if PATH="${workspace}/bin" bash -c 'source "$1/src/lib/tools.sh"; install_yq' _ "$workspace" > "${workspace}/output.log" 2>&1; then
        fail "yq installer accepted a corrupt download"
    fi
    grep -q 'checksum verification failed' "${workspace}/output.log" || fail "checksum failure not explained"
    [[ ! -e "${workspace}/src/.tools/bin/yq" ]] || fail "corrupt yq installed"
    pass "yq installer rejects corrupt downloads before execution"
}

test_discovery_writes_candidates_with_go_yq() {
    local workspace
    workspace=$(make_workspace "discovery-go-yq")
    prepare_execution_workspace "$workspace"
    cat > "${workspace}/bin/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *ollama.com/library*) printf '<a href="/library/tiny-1b">test</a>\n' ;;
    *) printf '[]\n' ;;
esac
SH
    chmod +x "${workspace}/bin/curl"
    PATH="${workspace}/bin:${PATH}" bash "${workspace}/src/02-discover.sh" >/dev/null
    yq -e '[.candidates[] | select(.tag == "tiny-1b" and .source == "ollama")] | length == 1' "${workspace}/src/specs.yaml" >/dev/null || fail "Go yq candidate append failed"
    pass "discovery appends candidates using Mike Farah yq"
}

test_hardware_assessment_writes_safe_go_yq_values() {
    local workspace
    workspace=$(make_workspace "assessment-go-yq")
    prepare_execution_workspace "$workspace"
    select_test_roles "$workspace"
    cat > "${workspace}/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *--query-gpu=name*) printf '%s\n' 'Test \"quoted\" GPU' ;;
    *--query-gpu=memory.total*) printf '4096 MiB\n' ;;
    *) exit 1 ;;
esac
SH
    chmod +x "${workspace}/bin/nvidia-smi"
    PATH="${workspace}/bin:${PATH}" bash "${workspace}/src/01-assess.sh" >/dev/null
    MM_EXPECT='Test "quoted" GPU' yq -e '.hardware.gpu_name == strenv(MM_EXPECT) and .hardware.gpu_vram_gb == 4 and .models[0].alias == "test-1b"' "${workspace}/src/specs.yaml" >/dev/null || fail "assessment corrupted strings or existing model registry"
    rm "${workspace}/src/specs.yaml"
    PATH="${workspace}/bin:${PATH}" bash "${workspace}/src/01-assess.sh" >/dev/null
    yq -e '.hardware.gpu_vram_gb == 4 and (.models | length == 0) and (.candidates | length == 0)' "${workspace}/src/specs.yaml" >/dev/null || fail "assessment failed to create valid specs"
    pass "hardware assessment safely creates and updates YAML with Go yq"
}

test_prereqs_check_never_installs_optional_tools
test_prereqs_noninteractive_default_does_not_hang
test_prereqs_yes_installs_glow_and_missing_required_tools
test_prereqs_glow_uses_package_manager_without_snap
test_prereqs_optional_install_failure_is_nonfatal
test_prereqs_required_install_failure_is_fatal
test_python_yq_is_rejected_without_modifying_specs
test_yq_installer_rejects_bad_checksums
test_discovery_writes_candidates_with_go_yq
test_hardware_assessment_writes_safe_go_yq_values
