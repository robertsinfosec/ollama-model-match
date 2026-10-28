"""Read-only official-library metadata discovery and pipeline candidate export."""

import argparse
import hashlib
import json
import math
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path

GIB = 1024**3
WEIGHT_TYPES = {"model", "projector", "adapter", "draft"}


def request_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "ollama-model-match/metadata"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


class LibraryLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.refs = set()

    def handle_starttag(self, tag, attrs):
        if tag != "a":
            return
        for key, value in attrs:
            if key == "href" and value and value.startswith("/library/"):
                self.refs.add(urllib.parse.unquote(value.removeprefix("/library/")))


def discover_tags(family):
    # Ollama's public registry currently returns 404 for tags/list. Discover
    # pullable references from the official tag page, then verify manifests.
    with urllib.request.urlopen(
        "https://ollama.com/library/" + urllib.parse.quote(family) + "/tags", timeout=30
    ) as response:
        parser = LibraryLinks()
        parser.feed(response.read().decode())
    return sorted(t for t in parser.refs if t.startswith(family + ":"))


def variant_priority(tag):
    variant = tag.rsplit(":", 1)[-1].lower()
    if re.search(r"fp16|bf16|(?:^|-)f16", variant):
        priority = 4
    elif re.search(r"q[568]", variant):
        priority = 3
    elif "q4" in variant:
        priority = 2
    elif variant == "latest":
        priority = 2
    else:
        priority = 0  # Include explicit instruct/thinking variants before precision variants.
    return priority, len(tag), tag


def candidate_manifest(tag, budget_gib, context_reserve_gib=0.4):
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*:[A-Za-z0-9_.-]+", tag):
        raise ValueError("Use an exact official-library family:variant tag")
    if not all(math.isfinite(n) and n >= 0 for n in (budget_gib, context_reserve_gib)):
        raise ValueError("Screening budgets must be finite and nonnegative")
    family, variant = tag.rsplit(":", 1)
    url = (
        "https://registry.ollama.ai/v2/library/"
        + urllib.parse.quote(family)
        + "/manifests/"
        + urllib.parse.quote(variant)
    )
    manifest = request_json(url)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("layers"), list):
        raise ValueError("Manifest must contain a layer list")
    layers = manifest["layers"]
    blobs = {}
    for layer in layers + ([manifest["config"]] if "config" in manifest else []):
        if not isinstance(layer, dict) or not isinstance(layer.get("mediaType"), str):
            raise ValueError("Malformed manifest descriptor")
        if type(layer.get("size")) is not int or layer["size"] < 0:
            raise ValueError("Manifest blob size must be a nonnegative integer")
        digest = layer.get("digest", "")
        if not isinstance(digest, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            raise ValueError("Manifest descriptor needs a SHA256 digest")
        if digest in blobs and blobs[digest] != layer["size"]:
            raise ValueError("One blob digest has conflicting sizes")
        blobs[digest] = layer["size"]
    weights = [layer for layer in layers if layer["mediaType"].rsplit(".", 1)[-1] in WEIGHT_TYPES]
    if not any(layer["mediaType"].endswith(".model") for layer in weights):
        raise ValueError("No local GGUF model layer; remote/unsupported variant")
    weight_bytes = sum(layer["size"] for layer in weights)
    return {
        "tag": tag,
        "source": url,
        "manifest_sha256": hashlib.sha256(
            json.dumps(manifest, sort_keys=True).encode()
        ).hexdigest(),
        "layers": weights,
        "weight_bytes": weight_bytes,
        "download_bytes": sum(blobs.values()),
        "weight_gib": weight_bytes / GIB,
        "context_reserve_gib": context_reserve_gib,
        "candidate": weight_bytes / GIB + context_reserve_gib <= budget_gib,
        "reason": "Artifact sizes plus a screening reserve; actual GPU placement must still be measured",
    }


def discovery(args):
    validate_arguments(args)
    output = Path(args.output)
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use a fresh output directory; existing previews are never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    registry = read_specs(args.spec) if args.spec else None
    candidates, errors, tag_counts = [], [], {}
    for family in args.families:
        try:
            tags = discover_tags(family)
            tag_counts[family] = len(tags)
            # Prefer default-size tags and Q4 GGUF alternatives. Do not try MLX,
            # cloud, or hardware-specific quantizations on this Linux experiment.
            tags = [
                t
                for t in tags
                if not re.search(r"mlx|cloud|nvfp|mxfp|mtp|embedding|(?:-|:)base(?:-|$)", t, re.I)
            ]
            tags.sort(key=variant_priority)
            tags = tags[: args.variants_per_family]

            def fetch(tag):
                try:
                    return candidate_manifest(
                        tag, args.vram_gib - args.headroom_gib, args.context_reserve_gib
                    )
                except (urllib.error.URLError, ValueError, KeyError) as exc:
                    return {"tag": tag, "error": str(exc)}

            with ThreadPoolExecutor(max_workers=4) as pool:
                for result in pool.map(fetch, tags):
                    if "error" in result:
                        errors.append(result)
                    else:
                        candidates.append(result)
            print(f"{family}: examined {len(tags)} of {tag_counts[family]} tags", flush=True)
        except (urllib.error.URLError, ValueError) as exc:
            errors.append({"family": family, "error": str(exc)})
    seen, unique = set(), []
    for candidate in sorted(candidates, key=lambda c: (len(c["tag"]), c["tag"])):
        key = tuple(sorted((layer["digest"], layer["size"]) for layer in candidate["layers"]))
        candidate["same_weights_as"] = next((c["tag"] for c in unique if c["_key"] == key), None)
        if key not in seen:
            seen.add(key)
            unique.append(dict(candidate, _key=key))
    data = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "settings": vars(args),
        "tag_counts": tag_counts,
        "candidates": candidates,
        "errors": errors,
    }
    (output / "discovery.json").write_text(json.dumps(data, indent=2, default=str))
    exported = export_candidates(candidates, registry)
    (output / "pipeline-candidates.json").write_text(json.dumps(exported, indent=2))
    lines = [
        "# Metadata-based candidate screening",
        "",
        "Sizes include model, projector, adapter and draft layers. Passing is provisional until a load confirms GPU placement.",
        "",
        "| Tag | Weights GiB | Download GB | Candidate | Same weights as |",
        "|---|---:|---:|---|---|",
    ]
    for candidate in sorted(
        candidates, key=lambda c: (not c["candidate"], c["weight_bytes"], c["tag"])
    ):
        lines.append(
            f"| {candidate['tag']} | {candidate['weight_gib']:.2f} | {candidate['download_bytes'] / 1e9:.2f} | {candidate['candidate']} | {candidate['same_weights_as'] or ''} |"
        )
    (output / "discovery.md").write_text("\n".join(lines) + "\n")
    print(
        f"Saved {len(candidates)} manifest records and {len(errors)} errors to {output}", flush=True
    )
    print(f"Exported {len(exported)} candidates for review; specs.yaml was not changed", flush=True)


def canonical_tag(tag):
    return tag if ":" in tag.rsplit("/", 1)[-1] else tag + ":latest"


def export_candidates(candidates, registry=None):
    """Use fields already consumed by 03-filter.sh; never schedule implicit retests."""
    registry = registry or {}
    known = set()
    for section in ("models", "rejected", "candidates"):
        rows = registry.get(section) or []
        if not isinstance(rows, list):
            raise ValueError(f"Registry section {section} must be a list")
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("tag"), str) or not row["tag"]:
                raise ValueError(f"Registry section {section} contains an invalid model tag")
            known.add(canonical_tag(row["tag"]))
    exported = []
    for candidate in sorted(candidates, key=lambda c: variant_priority(c["tag"])):
        tag = canonical_tag(candidate["tag"])
        if not candidate["candidate"] or tag in known:
            continue
        known.add(tag)
        exported.append(
            {
                "tag": candidate["tag"],
                "source": "ollama",
                "priority": "medium",
                "status": "new",
                "discovered": datetime.now(timezone.utc).date().isoformat(),
                "estimated_vram_gb": candidate["weight_bytes"] / GIB,
                "artifact_bytes": candidate["weight_bytes"],
                "artifact_source": candidate["source"],
                "manifest_sha256": candidate["manifest_sha256"],
                "estimate_note": "Weight bytes in GiB; existing filter adds its KV reserve. Runtime placement still needs verification.",
            }
        )
    return exported


def read_specs(path):
    tools = Path(__file__).resolve().parents[1] / "lib/tools.sh"
    try:
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; require_yq || exit; yq -o=json "." "$2"',
                "metadata-discovery",
                str(tools),
                str(Path(path).resolve()),
            ],
            text=True,
            capture_output=True,
            timeout=10,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        raise ValueError("Cannot read specs with the project Go yq: " + exc.stderr.strip()) from exc
    data = json.loads(result.stdout)
    if not isinstance(data, dict):
        raise ValueError("specs.yaml must contain a mapping")
    return data


def add_arguments(parser):
    parser.add_argument(
        "--families",
        nargs="+",
        default=[
            "qwen3",
            "qwen3.5",
            "qwen2.5-coder",
            "phi4-mini",
            "gemma3",
            "gemma4",
            "ministral-3",
        ],
    )
    parser.add_argument("--vram-gib", type=float, required=True)
    parser.add_argument("--headroom-gib", type=float, default=1)
    parser.add_argument("--context-reserve-gib", type=float, default=0.4)
    parser.add_argument("--variants-per-family", type=int, default=12)
    parser.add_argument(
        "--spec", help="Exclude already-curated, rejected, or pending tags; requires project Go yq"
    )
    parser.add_argument("--output", required=True)


def validate_arguments(args):
    numbers = (args.vram_gib, args.headroom_gib, args.context_reserve_gib)
    if (
        not all(math.isfinite(n) for n in numbers)
        or args.vram_gib <= args.headroom_gib
        or min(numbers) < 0
        or args.variants_per_family <= 0
    ):
        raise ValueError("Invalid finite screening budget")
    if any(not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", family) for family in args.families):
        raise ValueError("Use official library family names")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_arguments(parser)
    args = parser.parse_args()
    try:
        discovery(args)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(1, str(exc) + "\n")
