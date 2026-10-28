#!/usr/bin/env bash
# Shared screening policy for discovery and filtering. Values are GiB, matching
# assessment. Artifact weights plus the existing 8K KV estimate are provisional.
# Outputs consumed by callers: vram_budget, vram_headroom, cpu_mode.
# shellcheck disable=SC2034
read_memory_budget() {
    local gpu_vram gpu_vendor memory_capacity
    gpu_vram=$(yq -r '.hardware.gpu_vram_gb // 0' "$SPEC_FILE")
    gpu_vendor=$(yq -r '.hardware.gpu_vendor // "unknown"' "$SPEC_FILE")
    vram_headroom=$(yq -r '.thresholds.vram_headroom_gb // 1.0' "$SPEC_FILE")
    memory_capacity="$gpu_vram"
    cpu_mode=false
    if [[ "$gpu_vram" == 0 || "$gpu_vendor" == none || "$gpu_vendor" == snapdragon ]]; then
        cpu_mode=true
        memory_capacity=$(yq -r '.hardware.ram_gb' "$SPEC_FILE")
    fi
    if [[ ! "$memory_capacity" =~ ^[0-9]+([.][0-9]+)?$ ||
          ! "$vram_headroom" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        ! awk -v c="$memory_capacity" -v h="$vram_headroom" 'BEGIN {exit !(c > h)}'; then
        printf 'A measured memory capacity greater than configured headroom is required. Run 01-assess.sh on the inference machine.\n' >&2
        return 1
    fi
    vram_budget=$(awk -v c="$memory_capacity" -v h="$vram_headroom" 'BEGIN {printf "%.6f", c-h}')
}

estimated_runtime_memory() {
    # Match the 8K context used for initial testing in 04-pull.sh.
    local context_tokens=8192 kv_gib_per_1k=0.05
    awk -v weights="$1" -v context="$context_tokens" -v kv="$kv_gib_per_1k" \
        'BEGIN {printf "%.6f", weights + context/1000*kv}'
}
