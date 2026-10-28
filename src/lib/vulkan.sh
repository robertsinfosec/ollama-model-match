#!/usr/bin/env bash
# Optional Linux fallback when vendor tools cannot report a discrete GPU.
# Vulkan enumeration proves hardware visibility, not Ollama backend support.
detect_vulkan_gpu() {
    command -v vulkaninfo >/dev/null 2>&1 || return 1
    local record
    record=$(vulkaninfo --text 2>/dev/null | awk '
        function save() {
            if (discrete) {
                count++
                if (bytes > 0 && vendor != "" && name != "")
                    result = vendor "|" name "|" sprintf("%.3f", bytes/1073741824)
            }
        }
        /^GPU[0-9]+:/ {save(); discrete=0; bytes=0; vendor=""; name=""; heaps=0}
        /^[[:space:]]*vendorID[[:space:]]*=/ {
            if ($3 == "0x10de") vendor="nvidia"
            else if ($3 == "0x1002") vendor="amd"
            else if ($3 == "0x8086") vendor="intel"
        }
        /deviceType[[:space:]]*= PHYSICAL_DEVICE_TYPE_DISCRETE_GPU/ {discrete=1}
        /deviceName[[:space:]]*=/ {name=$0; sub(/^[^=]*= */, "", name)}
        /^memoryHeaps: count/ {heaps=1}
        /^memoryTypes: count/ {heaps=0}
        heaps && /memoryHeaps\[/ {size=0}
        heaps && /^[[:space:]]*size[[:space:]]*=/ {size=$3}
        heaps && /MEMORY_HEAP_DEVICE_LOCAL_BIT/ {bytes+=size}
        END {save(); if (count == 1 && result != "") print result; else exit 1}
    ') || return 1
    [[ -n "$record" ]] || return 1
    printf '%s\n' "$record"
}
