#!/usr/bin/env bash
set -Eeuo pipefail

# Sourced by run.sh; exercises public entrypoints using isolated workspaces.

prepare_metadata_source() {
    local workspace="$1"
    mkdir -p "${workspace}/bin"
    cat > "${workspace}/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
    https://ollama.com/library)
        [[ "${LIBRARY_EMPTY:-}" != 1 ]] || exit 0
        printf '<a href="/library/arbitrary-family">Family without a size in its name</a>' ;;
    */arbitrary-family)
        for tag in latest alias thinking large-name-32b eight giant draft broken cloud; do
            printf '<a href="/library/arbitrary-family:%s">variant</a>\n' "$tag"
        done ;;
    */manifests/*)
        tag="${url##*/}"
        [[ "$tag" != "${FAIL_VARIANT:-}" ]] || exit 22
        if [[ -n "${INVALID_MANIFEST:-}" ]]; then
            printf '%s' "$INVALID_MANIFEST"
            exit
        fi
        case "$tag" in
            broken) printf '{"layers":[{"size":-1}]}'; exit ;;
            cloud) printf '{"layers":[]}'; exit ;;
            large-name-32b) bytes=4026531840 ;;
            eight) bytes=6979321856 ;;
            giant) bytes=30064771072 ;;
            *) bytes=2147483648 ;;
        esac
        digest=$(printf '%064d' "$bytes")
        printf '{"layers":[{"mediaType":"application/vnd.ollama.image.model","size":%s,"digest":"sha256:%s"}' "$bytes" "$digest"
        if [[ "$tag" == thinking ]]; then
            printf ',{"mediaType":"application/vnd.ollama.image.template","size":20,"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
        elif [[ "$tag" == draft ]]; then
            printf ',{"mediaType":"application/vnd.ollama.image.draft","size":4294967296,"digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}'
        fi
        printf ']}' ;;
    *) printf '[]' ;;
esac
SH
    chmod +x "${workspace}/bin/curl"
}

test_hardware_targeted_discovery() {
    local scenario capacity vendor ram expected workspace count
    while read -r scenario capacity vendor ram expected; do
        workspace=$(make_workspace "target-${scenario}")
        prepare_metadata_source "$workspace"
        write_specs "$workspace" <<YAML
hardware:
  gpu_vram_gb: $capacity
  gpu_vendor: $vendor
  ram_gb: $ram
thresholds:
  vram_headroom_gb: 1
models: []
rejected: []
candidates: []
YAML
        PATH="${workspace}/bin:${PATH}" bash "${workspace}/src/02-discover.sh" > "${workspace}/discovery.log" 2>&1
        bash "${workspace}/src/03-filter.sh" > "${workspace}/filter.log" 2>&1
        count=$(wc -l < "${workspace}/src/results/qualifying.txt")
        [[ "$count" -eq "$expected" ]] || fail "$scenario: expected $expected candidates, got $count"
        [[ "$(yq '.candidates | length' "${workspace}/src/specs.yaml")" -eq "$expected" ]] || fail "discovery and filtering disagree for $scenario"
        ! grep -qE ':(alias|broken|cloud)\|' "${workspace}/src/results/qualifying.txt" || fail "invalid or redundant candidate selected"
        grep -q ':thinking|' "${workspace}/src/results/qualifying.txt" || fail "shared weights lost a different prompt template"
        # Running discovery again must preserve the existing registry.
        PATH="${workspace}/bin:${PATH}" bash "${workspace}/src/02-discover.sh" >/dev/null 2>&1
        [[ "$(yq '.candidates | length' "${workspace}/src/specs.yaml")" -eq "$expected" ]] || fail "repeat discovery added duplicates"
        pass "hardware targeting: $scenario ($expected candidates)"
    done <<'CASES'
small 4 nvidia 32 2
medium 6 nvidia 32 3
large 24 amd 64 5
very-large 80 nvidia 128 6
unified 16 apple 16 5
cpu 0 none 32 6
CASES
}

test_unknown_memory_is_not_guessed() {
    local workspace phase
    workspace=$(make_workspace unknown-memory)
    write_specs "$workspace" <<'YAML'
hardware:
  gpu_vendor: none
thresholds:
  vram_headroom_gb: 1
candidates: []
YAML
    for phase in 02-discover 03-filter; do
        if bash "${workspace}/src/${phase}.sh" > "${workspace}/output.log" 2>&1; then
            fail "$phase accepted unknown RAM"
        fi
        grep -q 'measured memory capacity' "${workspace}/output.log" || fail "$phase did not explain missing capacity"
    done
    pass "unknown memory stops selection instead of assuming capacity"
}

test_fractional_headroom_and_registry_history() {
    local workspace
    workspace=$(make_workspace fractional-memory)
    prepare_execution_workspace "$workspace"
    prepare_metadata_source "$workspace"
    yq -i '.hardware.gpu_vram_gb = 6.25 | .thresholds.vram_headroom_gb = 2 | .candidates = []' "$workspace/src/specs.yaml"
    PATH="${workspace}/bin:${PATH}" bash "$workspace/src/02-discover.sh" >/dev/null 2>&1
    bash "$workspace/src/03-filter.sh" >/dev/null
    grep -q ':large-name-32b|' "$workspace/src/results/qualifying.txt" || fail "fractional budget was rounded down"
    yq -i '.thresholds.vram_headroom_gb = 2.1' "$workspace/src/specs.yaml"
    bash "$workspace/src/03-filter.sh" >/dev/null
    ! grep -q ':large-name-32b|' "$workspace/src/results/qualifying.txt" || fail "configured fractional headroom was ignored"
    yq -i '.candidates = [] | .models = [{"tag": "arbitrary-family"}] | .rejected = [{"tag": "arbitrary-family:thinking"}]' "$workspace/src/specs.yaml"
    PATH="${workspace}/bin:${PATH}" bash "$workspace/src/02-discover.sh" >/dev/null 2>&1
    [[ "$(yq '.candidates | length' "$workspace/src/specs.yaml")" == 0 ]] || fail "discovery bypassed curated/rejected history or latest normalization"
    pass "fractional headroom and existing registry history control selection"
}

test_bad_manifest_descriptors_are_skipped() {
    local workspace manifest mutation output
    workspace=$(make_workspace bad-manifest)
    prepare_metadata_source "$workspace"
    manifest='{"layers":[{"mediaType":"application/vnd.ollama.image.model","size":1073741824,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
    while read -r mutation; do
        output=$(INVALID_MANIFEST="$(printf '%s' "$manifest" | jq -c "$mutation")" \
            PATH="${workspace}/bin:${PATH}" bash "$workspace/src/lib/model-metadata.sh" arbitrary-family 2>/dev/null)
        [[ -z "$output" ]] || fail "invalid manifest emitted a weight estimate: $mutation"
    done <<'MUTATIONS'
del(.layers[0].digest)
.layers[0].digest = "not-a-digest"
.layers[0].size = -1
.layers[0].size = 1.5
.layers[0].size = "1073741824"
.layers += [(.layers[0] | .size = 2147483648)]
MUTATIONS
    pass "malformed and conflicting artifact descriptors never become estimates"
}

test_partial_and_empty_metadata_sources() {
    local workspace output
    workspace=$(make_workspace partial-metadata)
    prepare_execution_workspace "$workspace"
    prepare_metadata_source "$workspace"
    output=$(FAIL_VARIANT=large-name-32b PATH="${workspace}/bin:${PATH}" \
        bash "$workspace/src/lib/model-metadata.sh" arbitrary-family 2>/dev/null)
    grep -q '^arbitrary-family:latest|' <<< "$output" || fail "one unavailable manifest blocked other variants"
    ! grep -q ':large-name-32b|' <<< "$output" || fail "failed manifest produced an estimate"
    LIBRARY_EMPTY=1 PATH="${workspace}/bin:${PATH}" bash "$workspace/src/02-discover.sh" >/dev/null
    [[ "$(yq '.candidates | length' "$workspace/src/specs.yaml")" == 1 ]] || fail "empty source changed existing candidates"
    pass "partial failures and empty sources preserve usable candidates"
}

test_large_registry_deduplication() {
    local workspace
    workspace=$(make_workspace large-known-registry)
    prepare_metadata_source "$workspace"
    jq -n '{
        hardware: {gpu_vram_gb: 4, gpu_vendor: "nvidia"},
        thresholds: {vram_headroom_gb: 1},
        models: ([{tag: "arbitrary-family"}] + [range(0; 4000) |
            {tag: ("known-long-name-for-pipe-buffer-regression-xxxxxxxxxxxxxxxxxxxxxxxx-" + tostring)}]),
        rejected: [{tag: "arbitrary-family:thinking"}], candidates: []
    }' | yq -P > "$workspace/src/specs.yaml"
    PATH="${workspace}/bin:${PATH}" bash "$workspace/src/02-discover.sh" >/dev/null 2>&1
    [[ "$(yq '.candidates | length' "$workspace/src/specs.yaml")" == 0 ]] || fail "large known registry allowed duplicate candidates"
    yq -i '.candidates = [{"tag": "arbitrary-family", "estimated_vram_gb": 1}]' "$workspace/src/specs.yaml"
    bash "$workspace/src/03-filter.sh" >/dev/null
    [[ ! -s "$workspace/src/results/qualifying.txt" ]] || fail "large curated registry bypassed filter history"
    yq -i '.rejected = .models | .models = []' "$workspace/src/specs.yaml"
    bash "$workspace/src/03-filter.sh" >/dev/null
    [[ ! -s "$workspace/src/results/qualifying.txt" ]] || fail "large rejected registry bypassed filter history"
    pass "large registries preserve discovery and filter history without pipe failures"
}


test_interrupted_candidate_write_keeps_metadata() {
    local workspace
    workspace=$(make_workspace interrupted-discovery)
    prepare_execution_workspace "$workspace"
    prepare_metadata_source "$workspace"
    yq -i '.candidates = []' "$workspace/src/specs.yaml"
    cat > "$workspace/bin/yq" <<'SH'
#!/usr/bin/env bash
"${REAL_REVIEW_YQ:?}" "$@" || exit "$?"
if [[ "${1:-}" == -i ]]; then
    kill -TERM "$PPID"
fi
SH
    chmod +x "$workspace/bin/yq"
    if REAL_REVIEW_YQ="$YQ_BIN" PATH="$workspace/bin:$PATH" \
        bash "$workspace/src/02-discover.sh" > "$workspace/output.log" 2>&1; then
        fail "discovery unexpectedly completed after its writer was interrupted"
    fi
    yq -e '.candidates | length == 1' "$workspace/src/specs.yaml" >/dev/null || fail "interrupted discovery lost its completed write"
    yq -e '.candidates[0].estimated_vram_gb == 2' "$workspace/src/specs.yaml" >/dev/null || fail "interrupted discovery published a known candidate without its estimate"
    pass "interrupted discovery preserves a complete candidate and its estimate"
}

test_hardware_targeted_discovery
test_unknown_memory_is_not_guessed
test_fractional_headroom_and_registry_history
test_bad_manifest_descriptors_are_skipped
test_partial_and_empty_metadata_sources
test_large_registry_deduplication
test_interrupted_candidate_write_keeps_metadata
