#!/usr/bin/env bash
set -Eeuo pipefail

# Sourced by run.sh; exercises public entrypoints using isolated workspaces.

test_vulkan_memory_detection() {
    local workspace
    workspace=$(make_workspace vulkan-memory)
    mkdir -p "${workspace}/bin"
    cat > "${workspace}/bin/vulkaninfo" <<'SH'
#!/usr/bin/env bash
case "${VULKAN_TEST_CASE:-}" in
    empty) exit 0 ;;
    failure) exit 1 ;;
esac
cat <<'DATA'
GPU0:
 vendorID = 0x1002
 deviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
 deviceName = Shared memory GPU
memoryHeaps: count = 1
 memoryHeaps[0]:
  size = 34359738368
  MEMORY_HEAP_DEVICE_LOCAL_BIT
GPU1:
 vendorID = 0x10de
 deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
 deviceName = Test discrete GPU
memoryHeaps: count = 2
 memoryHeaps[0]:
  size = 12884901888
  MEMORY_HEAP_DEVICE_LOCAL_BIT
 memoryHeaps[1]:
  size = 68719476736
  flags: None
memoryTypes: count = 1
 MEMORY_PROPERTY_DEVICE_LOCAL_BIT
GPU2:
 vendorID = 0x10005
 deviceType = PHYSICAL_DEVICE_TYPE_CPU
 deviceName = Software renderer
memoryHeaps: count = 1
 memoryHeaps[0]:
  size = 34359738368
  MEMORY_HEAP_DEVICE_LOCAL_BIT
DATA
if [[ "${VULKAN_TEST_CASE:-}" == multiple* ]]; then
    cat <<DATA
GPU3:
 vendorID = ${SECOND_VENDOR:-0x8086}
 deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
 deviceName = Another discrete GPU
memoryHeaps: count = 1
 memoryHeaps[0]:
  size = ${SECOND_MEMORY:-8589934592}
  MEMORY_HEAP_DEVICE_LOCAL_BIT
DATA
fi
SH
    chmod +x "${workspace}/bin/vulkaninfo"
    PATH="${workspace}/bin:${PATH}" bash -c '
        source "$1/src/lib/vulkan.sh"
        [[ "$(detect_vulkan_gpu)" == "nvidia|Test discrete GPU|12.000" ]] || exit 1
        for scenario in empty failure multiple; do
            if VULKAN_TEST_CASE="$scenario" detect_vulkan_gpu; then exit 1; fi
        done
        if VULKAN_TEST_CASE=multiple SECOND_VENDOR=0xffff detect_vulkan_gpu; then exit 1; fi
        if VULKAN_TEST_CASE=multiple SECOND_MEMORY=0 detect_vulkan_gpu; then exit 1; fi
    ' _ "$workspace" || fail "Vulkan counted shared/software memory or misidentified vendor"
    pass "Vulkan fallback measures dedicated memory and ignores software/shared heaps"
}

test_remote_assessment_preserves_specs() {
    local workspace
    workspace=$(make_workspace remote-assessment)
    printf 'user-owned configuration\n' > "$workspace/src/specs.yaml"
    if OLLAMA_HOST=https://inference.example:11434 bash "$workspace/src/01-assess.sh" > "$workspace/output.log" 2>&1; then
        fail "assessment used local hardware for an explicitly remote server"
    fi
    grep -qx 'user-owned configuration' "$workspace/src/specs.yaml" || fail "remote assessment changed existing config"
    grep -q 'Run hardware assessment on the inference machine' "$workspace/output.log" || fail "remote assessment did not explain the mismatch"
    pass "remote endpoint cannot overwrite hardware with local measurements"
}

test_apple_assessment_without_linux_tools() {
    local workspace
    workspace=$(make_workspace apple-assessment)
    mkdir -p "$workspace/bin" "$workspace/empty-drm" "$workspace/empty-dri"
    write_specs "$workspace" <<'YAML'
thresholds:
  vram_headroom_gb: 2.5
models:
  - tag: user-owned
candidates: []
YAML
    cat > "$workspace/bin/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac
SH
    cat > "$workspace/bin/sysctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    '-n machdep.cpu.brand_string') echo 'Apple M2' ;;
    '-n hw.memsize') echo 25769803776 ;;
esac
SH
    cat > "$workspace/no-gpu-tools" <<'SH'
command() {
    if [[ "${1:-}" == -v ]]; then
        case "${2:-}" in
            nvidia-smi|amd-smi|rocm-smi|intel_gpu_top|vulkaninfo) return 1 ;;
        esac
    fi
    builtin command "$@"
}
SH
    # Linux DRM fixtures are empty even when this test runs on a GPU host.
    sed -e "s|/sys/class/drm|$workspace/empty-drm|g" -e "s|/dev/dri|$workspace/empty-dri|g" "$workspace/src/01-assess.sh" > "$workspace/assess"
    mv "$workspace/assess" "$workspace/src/01-assess.sh"
    chmod +x "$workspace/bin/uname" "$workspace/bin/sysctl"
    OLLAMA_HOST=http://localhost:11434 PATH="$workspace/bin:$PATH" BASH_ENV="$workspace/no-gpu-tools" \
        bash "$workspace/src/01-assess.sh" >/dev/null
    yq -e '.hardware.gpu_vendor == "apple" and .hardware.gpu_vram_gb == 24 and
           .hardware.ram_gb == 24 and .thresholds.vram_headroom_gb == 2.5 and
           .models[0].tag == "user-owned"' "$workspace/src/specs.yaml" >/dev/null || fail "Apple assessment lost measured capacity or user config"
    pass "Apple assessment path works without Linux GPU tools (simulated macOS)"
}

test_vulkan_memory_detection
test_remote_assessment_preserves_specs
test_apple_assessment_without_linux_tools
