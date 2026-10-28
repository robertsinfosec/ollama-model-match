#!/usr/bin/env bash
set -Eeuo pipefail

# Read publisher-listed variants from each official family page, without
# enumerating every precision suffix or pulling model weights.
# stdout: tag|weight GiB. Diagnostics go to stderr.
# The caller applies the hardware budget; artifact size alone is not runtime VRAM.
family="${1:?Expected an Ollama library family}"
[[ "$family" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || exit 2
if ! html=$(curl -fsSL "https://ollama.com/library/${family}"); then
    printf 'Could not list variants for %s\n' "$family" >&2
    exit 0
fi
records=$(mktemp)
trap 'rm -f "$records"' EXIT
while read -r tag; do
    [[ "$tag" == "${family}:"* ]] || continue
    variant="${tag#*:}"
    [[ "$variant" =~ ^[A-Za-z0-9_.-]+$ ]] || continue
    if ! manifest=$(curl -fsSL "https://registry.ollama.ai/v2/library/${family}/manifests/${variant}"); then
        printf 'Could not read manifest for %s\n' "$tag" >&2
        continue
    fi
    # Require local model weights. Cloud references have no model layer. Include
    # auxiliary weights (e.g. vision projectors and speculative draft models).
    if ! printf '%s' "$manifest" | jq -ce --arg tag "$tag" '
        [.layers[] | select(.mediaType | startswith("application/vnd.ollama.image.")) |
          select(.mediaType | endswith(".model") or endswith(".projector") or
                             endswith(".adapter") or endswith(".draft"))] as $weights |
        select(any($weights[]; .mediaType == "application/vnd.ollama.image.model")) |
        select(all($weights[]; (.size | type) == "number" and .size > 0 and
                              (.size | floor) == .size and
                              (.digest | test("^sha256:[a-f0-9]{64}$")))) |
        select($weights | group_by(.digest) | all(.[]; (map(.size) | unique | length) == 1)) |
        ($weights | unique_by(.digest)) as $unique |
        {tag: $tag, bytes: ($unique | map(.size) | add),
         manifest: .}
    ' >> "$records"; then
        printf 'No usable weight metadata for %s\n' "$tag" >&2
    fi
done < <(printf '%s' "$html" | grep -oP 'href="/library/\K[^"/?#]+' | sort -u || true)
# Aliases of an identical manifest should not create duplicate benchmark work.
# Keep variants with different templates or parameters, even with shared weights.
# Prefer :latest when present, then shorter aliases; selection does not
# privilege a family, parameter count, or quantization format.
jq -sr 'sort_by([(.tag | endswith(":latest") | not), (.tag | length), .tag]) | unique_by(.manifest) | sort_by(.tag) |
        .[] | "\(.tag)|\(.bytes / 1073741824)"' "$records"
