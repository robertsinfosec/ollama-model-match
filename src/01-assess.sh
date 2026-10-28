#!/usr/bin/env bash
set -Eeuo pipefail

# 01-assess.sh — Detect hardware and create/update specs.yaml.
# Supports NVIDIA (nvidia-smi), AMD (amd-smi/rocm-smi), and Apple Silicon.
# This script is run by the OpenCode LLM (not the user).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="${SCRIPT_DIR}/specs.yaml"

# --- Colors ---
if [[ -t 1 ]]; then
    CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
    CYAN='' GREEN='' YELLOW='' RED='' NC=''
fi
log_info()  { printf "${CYAN}[*]${NC} %s\n" "$*"; }
log_ok()    { printf "${GREEN}[+]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
log_err()   { printf "${RED}[-]${NC} %s\n" "$*" >&2; }
die() { log_err "$*"; exit 1; }

# --- Detect GPU ---
has_intel_drm_device() {
    local vendor_file
    for vendor_file in /sys/class/drm/card*/device/vendor; do
        if [[ "$(cat "$vendor_file" 2>/dev/null)" == "0x8086" ]]; then
            return 0
        fi
    done
    return 1
}

detect_gpu() {
    # NVIDIA
    if command -v nvidia-smi >/dev/null 2>&1; then
        local name vram_mb
        name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)
        vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 | tr -d ' MiB' | xargs)
        if [[ -z "$name" || -z "$vram_mb" || "$vram_mb" == "0" ]]; then
            log_warn "nvidia-smi found but returned no data. Falling back."
        else
            local vram_gb
            vram_gb=$(awk -v v="$vram_mb" 'BEGIN { printf "%.0f", v/1024 }')
            echo "nvidia|$name|$vram_gb"
            return
        fi
    fi

    # AMD — try amd-smi first (ROCm 6.x+), then rocm-smi
    if command -v amd-smi >/dev/null 2>&1; then
        local name vram
        # amd-smi metric --gpu 0 (JSON or text)
        name=$(amd-smi 2>/dev/null | grep -iE "card series|gpu" | head -1 | sed 's/.*: *//' | xargs || echo "")
        # Try to get VRAM from amd-smi
        vram=$(amd-smi 2>/dev/null | grep -iE "vram.*total|total.*vram|memory.*total" | head -1 | grep -oP '[0-9]+' | head -1 || echo "")
        if [[ -z "$name" ]]; then
            name="AMD GPU (amd-smi)"
        fi
        if [[ -z "$vram" || "$vram" == "0" ]]; then
            # Fallback: check if this is unified memory (Strix Halo)
            # In unified mode, VRAM = system RAM
            local sys_ram
            sys_ram=$(free -g 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")
            if [[ "$sys_ram" -gt 64 ]]; then
                log_warn "AMD GPU detected but VRAM not reported. Assuming unified memory (Strix Halo)."
                vram_gb="$sys_ram"
                name="$name (unified memory)"
            else
                log_warn "AMD GPU detected but VRAM not reported. Defaulting to 8GB."
                vram_gb=8
            fi
        else
            # amd-smi may report in MB or GB
            if [[ "$vram" -gt 1000 ]]; then
                vram_gb=$(awk -v v="$vram" 'BEGIN { printf "%.0f", v/1024 }')
            else
                vram_gb="$vram"
            fi
        fi
        echo "amd|$name|$vram_gb"
        return
    fi

    if command -v rocm-smi >/dev/null 2>&1; then
        local name vram
        name=$(rocm-smi --showproductname 2>/dev/null | grep -i "card" | head -1 | sed 's/.*: *//' | xargs || echo "AMD GPU (rocm-smi)")
        vram=$(rocm-smi --showmeminfo vram 2>/dev/null | grep -i "total" | head -1 | grep -oP '[0-9]+' | head -1 || echo "")
        if [[ -z "$vram" || "$vram" == "0" ]]; then
            local sys_ram
            sys_ram=$(free -g 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")
            if [[ "$sys_ram" -gt 64 ]]; then
                log_warn "AMD GPU detected but VRAM not reported. Assuming unified memory."
                vram_gb="$sys_ram"
                name="$name (unified memory)"
            else
                log_warn "AMD GPU detected but VRAM not reported. Defaulting to 8GB."
                vram_gb=8
            fi
        else
            if [[ "$vram" -gt 1000 ]]; then
                vram_gb=$(awk -v v="$vram" 'BEGIN { printf "%.0f", v/1024 }')
            else
                vram_gb="$vram"
            fi
        fi
        echo "amd|$name|$vram_gb"
        return
    fi

    # Intel GPU (experimental)
    if command -v intel_gpu_top >/dev/null 2>&1 || has_intel_drm_device; then
        local name vram
        name="Intel GPU"
        if command -v intel_gpu_top >/dev/null 2>&1; then
            name=$(intel_gpu_top -l 2>/dev/null | grep -i "device" | head -1 | xargs || echo "Intel GPU")
        fi
        # Intel GPUs typically have shared or dedicated VRAM
        # Try to get from /sys
        vram=$(cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null || echo "")
        if [[ -z "$vram" || "$vram" == "0" ]]; then
            # Fallback: check if this is integrated (shared memory)
            local sys_ram
            sys_ram=$(free -g 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0")
            if [[ "$sys_ram" -gt 32 ]]; then
                log_warn "Intel GPU detected but VRAM not reported. Assuming shared memory."
                vram_gb=$(awk -v r="$sys_ram" 'BEGIN { printf "%.0f", r/4 }')
                name="$name (shared memory, estimated)"
            else
                log_warn "Intel GPU detected but VRAM not reported. Defaulting to 4GB."
                vram_gb=4
            fi
        else
            # /sys reports in bytes
            vram_gb=$(awk -v v="$vram" 'BEGIN { printf "%.0f", v/1073741824 }')
        fi
        echo "intel|$name|$vram_gb"
        return
    fi

    # Apple Silicon
    if [[ "$(uname -s)" == "Darwin" ]] && sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -qi "apple"; then
        local chip unified_ram unified_gb
        chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
        unified_ram=$(sysctl -n hw.memsize 2>/dev/null)
        unified_gb=$(awk -v r="$unified_ram" 'BEGIN { printf "%.0f", r/1073741824 }')
        echo "apple|$chip (unified)|$unified_gb"
        return
    fi

    # Qualcomm Snapdragon (not supported)
    if [[ "$(uname -m)" == "aarch64" ]] && grep -qi "qualcomm\|snapdragon" /proc/cpuinfo 2>/dev/null; then
        local name
        name=$(grep -m1 -i "hardware" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Qualcomm Snapdragon")
        log_warn "Snapdragon detected — NOT YET SUPPORTED by Ollama."
        log_warn "Models will run on CPU only (very slow)."
        echo "snapdragon|$name (not supported)|0"
        return
    fi

    # No GPU found
    echo "none|No GPU detected|0"
}

# --- Detect RAM ---
detect_ram() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}'
    else
        free -g 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "0"
    fi
}

# --- Detect CPU ---
detect_cpu() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown"
    else
        grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown"
    fi
}

# --- Detect OS ---
detect_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    else
        uname -s
    fi
}

# --- Detect ROCm version (AMD only) ---
detect_rocm_version() {
    if command -v amd-smi >/dev/null 2>&1; then
        amd-smi 2>/dev/null | grep -i "rocm" | head -1 | xargs || echo "unknown"
    elif command -v rocm-smi >/dev/null 2>&1; then
        rocm-smi --showdriverversion 2>/dev/null | grep -i "rocm\|version" | head -1 | xargs || echo "unknown"
    else
        echo "N/A"
    fi
}

# --- Main ---
log_info "Assessing hardware..."
log_info ""

gpu_info=$(detect_gpu)
IFS='|' read -r gpu_type gpu_name gpu_vram <<< "$gpu_info"
ram_gb=$(detect_ram)
cpu=$(detect_cpu)
os=$(detect_os)

log_info "GPU:  $gpu_name (${gpu_vram}GB VRAM) [$gpu_type]"
log_info "RAM:  ${ram_gb}GB"
log_info "CPU:  $cpu"
log_info "OS:   $os"
if [[ "$gpu_type" == "amd" ]]; then
    rocm_ver=$(detect_rocm_version)
    log_info "ROCm: $rocm_ver"
fi
log_info ""

# --- Create or update specs.yaml ---
if [[ -f "$SPEC_FILE" ]]; then
    log_info "specs.yaml exists. Updating hardware section only."
    yq -iy ".hardware.gpu_name = \"$gpu_name\"" "$SPEC_FILE"
    yq -iy ".hardware.gpu_vram_gb = $gpu_vram" "$SPEC_FILE"
    yq -iy ".hardware.ram_gb = $ram_gb" "$SPEC_FILE"
    yq -iy ".hardware.cpu = \"$cpu\"" "$SPEC_FILE"
    yq -iy ".hardware.os = \"$os\"" "$SPEC_FILE"
    yq -iy ".hardware.gpu_vendor = \"$gpu_type\"" "$SPEC_FILE"
    log_ok "Hardware section updated."
else
    log_info "Creating new specs.yaml..."
    cat > "$SPEC_FILE" <<EOF
# System specification and model registry.
# Auto-generated by 01-assess.sh

hardware:
  gpu_name: "$gpu_name"
  gpu_vendor: "$gpu_type"
  gpu_vram_gb: $gpu_vram
  ram_gb: $ram_gb
  cpu: "$cpu"
  os: "$os"

thresholds:
  min_tok_per_sec: 15
  vram_headroom_gb: 1.0
  min_coding_score: 50

models: []

rejected: []

candidates: []
EOF
    log_ok "specs.yaml created."
fi

log_info ""
log_info "=== Hardware Assessment Complete ==="