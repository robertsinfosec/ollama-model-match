#!/usr/bin/env bash
set -Eeuo pipefail

# 00-prereqs.sh — Check prerequisites and find Ollama + GPU tools.
# Interactive by default; agents use --yes to accept supported tool installs.
# It checks for required tools and finds Ollama (native/Docker).
# Outputs: status to stdout/stderr. Exit 0 = OK, exit 1 = critical failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"

INSTALL_MODE=ask
case "${1:-}" in
    --yes|-y) INSTALL_MODE=yes ;;
    --check) INSTALL_MODE=check ;;
    --help|-h)
        printf 'Usage: bash 00-prereqs.sh [--yes | --check]\n'
        printf 'Default: offer installs. --yes: accept offers. --check: never install.\n'
        exit 0 ;;
    '') ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { printf 'Expected at most one option.\n' >&2; exit 2; }
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || {
    printf 'Bash 4.4 or newer is required. On macOS, install a current Bash and invoke it explicitly.\n' >&2
    exit 1
}
if ! printf 'probe\n' | grep -qP '^probe$' 2>/dev/null || ! date -Iseconds >/dev/null 2>&1; then
    printf 'This build requires grep -P and date -Iseconds. On macOS, install GNU grep/coreutils and put their gnubin directories on PATH before setup.\n' >&2
    exit 1
fi

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

# --- Check required tools ---
log_info "Checking required tools..."

MISSING=0

confirm_install() {
    local tool="$1" answer
    [[ "$INSTALL_MODE" != check ]] || return 1
    if [[ "$INSTALL_MODE" == yes ]]; then
        log_info "Accepting $tool installation (--yes)."
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_warn "No interactive terminal. Run with --yes to accept installation, or install manually."
        return 1
    fi
    read -r -p "Install $tool now? [y/N] " answer || return 1
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

check_tool() {
    local tool="$1"
    local required="${2:-true}"
    local explanation="${3:-}"
    local installer="${4:-install_package}"
    local available=false
    if tool_is_usable "$tool"; then
        available=true
    elif [[ "$tool" == yq && -n "$YQ_BIN" ]]; then
        log_warn "yq: unsupported implementation/version at $YQ_BIN: $(yq --version 2>&1 || true)"
    fi
    if [[ "$available" == true ]]; then
        log_ok "$tool: available and verified"
    else
        log_warn "Utility '$tool' not detected or unsupported. $explanation"
        case "$tool" in
            yq) log_info "Install method: verified upstream v4 binary in $TOOLS_BIN; system yq is not replaced." ;;
            glow)
                if snap_is_available; then
                    log_info "Install method: snap install glow (may require administrator privileges)."
                else
                    log_info "Install method: system package manager (may require administrator privileges)."
                fi ;;
            *) log_info "Install method: system package manager (may require administrator privileges)." ;;
        esac
        if confirm_install "$tool"; then
            if "$installer" "$tool"; then
                hash -r
                [[ "$tool" != yq ]] || select_yq
                if tool_is_usable "$tool"; then
                    log_ok "$tool installed and verified"
                    return 0
                fi
            fi
            log_warn "$tool installation failed or could not be verified. Resolve permissions/package availability and rerun prerequisites."
        fi
        if [[ "$required" == "true" ]]; then
            log_err "$tool: NOT FOUND (required)"
            MISSING=1
        else
            log_warn "$tool: NOT FOUND (optional)"
        fi
    fi
}

check_tool curl true "Required to discover and download models."
check_tool jq true "Required to process API responses and structured evaluation data."
check_tool yq true "Mike Farah yq v4 is required to read and safely update specs.yaml; Python yq is a different product." install_yq
check_tool glow false "Shows Markdown output in nice formatting. It is not required, but this small utility makes reports nicer." install_glow
if command -v docker >/dev/null 2>&1; then
    log_ok "docker: $(command -v docker)"
else
    log_info "docker: not found (only needed if you use containerized Ollama)."
fi

if [[ $MISSING -eq 1 ]]; then
    die "Missing required tools. Install them before continuing."
fi

log_info ""

# --- Detect GPU tooling ---
log_info "Detecting GPU tooling..."

GPU_VENDOR="none"

# NVIDIA
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_VENDOR="nvidia"
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    log_ok "NVIDIA: nvidia-smi found (driver $driver)"

# AMD (ROCm)
elif command -v amd-smi >/dev/null 2>&1; then
    GPU_VENDOR="amd"
    log_ok "AMD: amd-smi found (ROCm $(amd-smi 2>/dev/null | grep -i 'rocm' | head -1 | xargs || echo 'unknown'))"

elif command -v rocm-smi >/dev/null 2>&1; then
    GPU_VENDOR="amd"
    log_ok "AMD: rocm-smi found"

# Apple Silicon
elif [[ "$(uname -s)" == "Darwin" ]] && sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -qi "apple"; then
    GPU_VENDOR="apple"
    chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
    log_ok "Apple Silicon: $chip"

# Intel GPU (experimental)
elif command -v intel_gpu_top >/dev/null 2>&1 || [[ -d /dev/dri ]] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    GPU_VENDOR="intel"
    log_warn "Intel GPU: /dev/dri found (experimental support)"
    log_warn "  Ollama Intel support requires SYCL/oneAPI. Performance may vary."

# Qualcomm Snapdragon (not supported)
elif [[ "$(uname -m)" == "aarch64" ]] && grep -qi "qualcomm\|snapdragon" /proc/cpuinfo 2>/dev/null; then
    GPU_VENDOR="snapdragon"
    log_warn "Qualcomm Snapdragon detected — NOT YET SUPPORTED"
    log_warn "  Ollama does not yet support Snapdragon NPU/GPU acceleration."
    log_warn "  Models will run on CPU only (very slow)."

else
    log_warn "No GPU tooling found. CPU-only mode."
fi

log_info "GPU vendor: $GPU_VENDOR"
log_info ""

# --- Find Ollama ---
log_info "Looking for Ollama..."

OLLAMA_BACKEND=""
OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-}"

if command -v docker >/dev/null 2>&1; then
    containers=$(docker ps --no-trunc --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.service"}}' 2>/dev/null || true)
    while IFS='|' read -r id name image service; do
        [[ -n "$id" ]] || continue
        if [[ -n "$OLLAMA_CONTAINER" ]]; then
            [[ "$name" == "$OLLAMA_CONTAINER" || "$id" == "$OLLAMA_CONTAINER" ]] || continue
        elif [[ "${name,,}" != *ollama* && "${service,,}" != *ollama* ]] && [[ ! "$image" =~ (^|/)ollama/ollama([:@]|$) ]]; then
            continue
        fi
        if docker exec "$id" sh -c 'command -v ollama >/dev/null 2>&1' >/dev/null 2>&1; then
            OLLAMA_BACKEND=docker
            OLLAMA_CONTAINER="$id"
            log_ok "Ollama found in Docker container: $name ($id)"
            break
        fi
    done <<<"$containers"
fi

if [[ -z "$OLLAMA_BACKEND" ]]; then
    if [[ -n "$(type -P ollama)" ]]; then
        OLLAMA_BACKEND=native
        log_ok "Ollama found (native): $(type -P ollama)"
        log_info "OLLAMA_HOST=${OLLAMA_HOST:-default}"
    else
        die "Ollama not found. Install it or start a Docker container."
    fi
fi

# --- Verify Ollama is responsive ---
log_info ""
log_info "Verifying Ollama is responsive..."

if [[ "$OLLAMA_BACKEND" == "docker" ]]; then
    docker exec "$OLLAMA_CONTAINER" ollama ls >/dev/null 2>&1 || die "Ollama container is not responding."
else
    ollama ls >/dev/null 2>&1 || die "Ollama is not responding. Check OLLAMA_HOST."
fi

log_ok "Ollama is responsive."
log_info ""

# --- Summary ---
log_info "=== Prerequisites OK ==="
log_info "Backend: $OLLAMA_BACKEND"
if [[ "$OLLAMA_BACKEND" == "docker" ]]; then
    log_info "Container: $OLLAMA_CONTAINER"
fi
log_info "GPU vendor: $GPU_VENDOR"
log_info "Tools: yq, jq, curl (required) | glow, docker (optional)"
log_info ""
if [[ "$GPU_VENDOR" == "snapdragon" ]]; then
    log_warn "WARNING: Snapdragon is not yet supported. Models will run on CPU only."
    log_warn "Consider using a different machine or waiting for Ollama Snapdragon support."
fi
if [[ "$GPU_VENDOR" == "intel" ]]; then
    log_warn "WARNING: Intel GPU support is experimental. Verify Ollama is using SYCL backend."
fi
log_info "Ready to proceed to Step 01 (Hardware Assessment)."
