#!/usr/bin/env bash
# Shared dependency setup. Source from scripts; installation is opt-in.

TOOLS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_BIN="${TOOLS_SCRIPT_DIR}/.tools/bin"
YQ_BIN=""
APT_UPDATED=false

select_yq() {
    if [[ -x "${TOOLS_BIN}/yq" ]]; then
        YQ_BIN="${TOOLS_BIN}/yq"
    else
        YQ_BIN=$(type -P yq || true)
    fi
}
select_yq

# Scope selection to yq alone; never change resolution of other commands.
yq() {
    [[ -n "$YQ_BIN" ]] || { printf 'Mike Farah yq is not installed.\n' >&2; return 127; }
    "$YQ_BIN" "$@"
}

yq_is_supported() {
    local binary="${1:-$YQ_BIN}" version minor patch
    [[ -n "$binary" ]] || return 1
    version=$("$binary" --version 2>/dev/null) || return 1
    [[ "$version" == *github.com/mikefarah/yq/* && "$version" =~ version[[:space:]]v?4\.([0-9]+)\.([0-9]+) ]] || return 1
    minor="${BASH_REMATCH[1]}"
    patch="${BASH_REMATCH[2]}"
    (( minor > 44 || (minor == 44 && patch >= 3) )) || return 1
    MODEL_MATCH_PROBE='quoted "value"' "$binary" -ne 'strenv(MODEL_MATCH_PROBE) == "quoted \"value\""' >/dev/null 2>&1
}

require_yq() {
    if ! yq_is_supported; then
        printf 'Mike Farah yq v4 is required (minimum 4.44.3; not Python yq). Run: bash %q --yes\n' "${TOOLS_SCRIPT_DIR}/00-prereqs.sh" >&2
        return 1
    fi
}

# Pinned upstream binaries, verified against the release's SHA256 checksums-bsd.
# Keep the version and hashes together when updating this dependency.
# https://github.com/mikefarah/yq/releases/tag/v4.54.1
install_yq() (
    local platform arch asset expected tmp actual
    case "$(uname -s)" in
        Linux) platform=linux ;;
        Darwin) platform=darwin ;;
        *) printf 'Unsupported yq platform; install Mike Farah yq v4 manually.\n' >&2; return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) printf 'Unsupported yq architecture; install Mike Farah yq v4 manually.\n' >&2; return 1 ;;
    esac
    asset="yq_${platform}_${arch}"
    case "$asset" in
        yq_linux_amd64) expected=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f ;;
        yq_linux_arm64) expected=189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b ;;
        yq_darwin_amd64) expected=3a812fce205a4d67014fb71b7fa297092210e580df3d8f52dddc2cf3a599c22b ;;
        yq_darwin_arm64) expected=fee511a181bd8b3e6b7da98842b41973bfac8cd3bcd341ed29a584620b5b2844 ;;
    esac
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        printf 'Install sha256sum or shasum before downloading yq.\n' >&2
        return 1
    fi
    # Do not overwrite an unexpected executable, even in the managed directory.
    if [[ -e "${TOOLS_BIN}/yq" || -L "${TOOLS_BIN}/yq" ]]; then
        yq_is_supported "${TOOLS_BIN}/yq" && return 0
        printf 'Unexpected %s/yq; move it aside before installation.\n' "$TOOLS_BIN" >&2
        return 1
    fi
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "$tmp"' EXIT
    curl -fL "https://github.com/mikefarah/yq/releases/download/v4.54.1/${asset}" -o "${tmp}/yq" || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "${tmp}/yq") || return 1
    else
        actual=$(shasum -a 256 "${tmp}/yq") || return 1
    fi
    [[ "${actual%% *}" == "$expected" ]] || { printf 'yq checksum verification failed.\n' >&2; return 1; }
    chmod +x "${tmp}/yq" || return 1
    yq_is_supported "${tmp}/yq" || return 1
    mkdir -p "$TOOLS_BIN" || return 1
    mv "${tmp}/yq" "${TOOLS_BIN}/yq" || return 1
    printf 'Installed Mike Farah yq v4.54.1 in %s (system yq unchanged).\n' "$TOOLS_BIN"
)

run_privileged() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        if [[ -t 0 && "${INSTALL_MODE:-ask}" != yes ]]; then
            sudo "$@"
        else
            if sudo -n "$@"; then
                return 0
            fi
            printf 'Command failed. If administrator credentials are needed, run in a human terminal: sudo ' >&2
            printf '%q ' "$@" >&2
            printf '\n' >&2
            return 1
        fi
    else
        printf 'Administrator privileges required. Ask the human to run: ' >&2
        printf '%q ' "$@" >&2
        printf '\n' >&2
        return 1
    fi
}

install_package() {
    local tool="$1"
    if [[ "$(uname -s)" == Darwin ]] && command -v brew >/dev/null 2>&1; then
        brew install "$tool"
    elif [[ "$(uname -s)" == Linux ]] && command -v apt-get >/dev/null 2>&1; then
        if [[ "$APT_UPDATED" == false ]]; then
            run_privileged apt-get update || return 1
            APT_UPDATED=true
        fi
        run_privileged apt-get install -y "$tool"
    else
        printf 'Install %s with your package manager, then rerun prerequisites.\n' "$tool" >&2
        return 1
    fi
}

install_glow() {
    if snap_is_available; then
        run_privileged snap install glow
    else
        install_package glow
    fi
}

snap_is_available() {
    [[ "$(uname -s)" == Linux ]] && command -v snap >/dev/null 2>&1 && snap list >/dev/null 2>&1
}

tool_is_usable() {
    local tool="$1" binary
    if [[ "$tool" == yq ]]; then
        yq_is_supported
        return
    fi
    binary=$(type -P "$tool" || true)
    if [[ -z "$binary" && "$tool" == glow ]]; then
        for binary in /snap/bin/glow /var/lib/snapd/snap/bin/glow; do
            [[ ! -x "$binary" ]] || break
        done
    fi
    [[ -x "$binary" ]] && "$binary" --version >/dev/null 2>&1
}
