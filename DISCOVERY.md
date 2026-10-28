# Preview model variants using artifact metadata

The existing discovery workflow uses model names to find possible candidates.
This optional tool enumerates exact official-library tags and checks their
registry manifests before suggesting candidates. For example, it distinguishes
Qwen3's `4b` thinking weights from `4b-instruct`, and counts supporting projector
and draft weights instead of treating a name containing `mini` as a size.

It uses Python 3.10+ and its standard library. No Ollama server or GPU is needed
for discovery, and no model weights are downloaded.

```bash
python3 src/discover-models.py \
  --families qwen3 qwen3.5 gemma4 \
  --variants-per-family 18 \
  --vram-gib 6 --headroom-gib 1 \
  --output src/results/metadata-preview
```

Run commands from the repository root. Use a fresh output directory; existing
preview evidence is preserved. The public tag pages supply references because
the registry's `tags/list` endpoint is unavailable. Manifests verify artifact
sizes. Sources and errors remain available for review.

## Outputs

- `discovery.json`: exact tags, sources, canonical manifest fingerprints,
  weight descriptors, byte counts, shared-weight aliases and retrieval errors.
- `discovery.md`: a readable candidate table.
- `pipeline-candidates.json`: entries using the existing filter's `tag`,
  `source`, `priority` and `estimated_vram_gb` fields, plus artifact evidence.

Weight estimates include model, projector, adapter and draft layers. Download
sizes include unique layer/config blobs. Fit remains provisional: weight GiB
plus a configurable 0.4-GiB context reserve must fit within VRAM minus headroom.
Actual KV-cache/workspace needs vary, so verify GPU placement after loading.
The export records weight GiB only because the existing filter adds its own KV
reserve. It is research input, not a guarantee that a model will fit.

## Preserve existing registry decisions

Optionally omit already-curated, rejected and pending tags:

```bash
python3 src/discover-models.py \
  --families qwen3 gemma4 --vram-gib 6 \
  --spec src/specs.yaml \
  --output src/results/metadata-with-registry
```

`--spec` reads YAML using the project's Go yq helper; install its supported
version through the existing prerequisite workflow. The command normalizes
omitted `:latest` tags, preserves all registry decisions, and fails on malformed
registry sections. It never writes `specs.yaml` or schedules implicit retests.
Review the export as part of the existing research phase before adding selected
entries to the registry. The export is tested through `03-filter.sh`.

## Selection limits

The default family list is a starting point, not an exhaustive catalog. The
variant cap favors default-size and explicit instruct/thinking variants before
larger precision variants. Cloud, MLX, base and hardware-specific variants are
excluded from this local-chat preview. Unsupported or malformed manifests are
recorded as errors rather than guessed to fit. This supplements the existing
workflow and does not change its discovery/filter scripts or promotion policy.

## Tests

```bash
python3 -m unittest discover -s tests -p 'test_metadata_discovery.py' -v
```

Eleven tests cover supporting weights, config/download accounting, invalid
metadata, variant ordering, registry preservation, immutable previews and
integration with the existing filter. Tests use fixtures and never contact the
model registry. The filter integration check requires the project Go yq and is
skipped when it is absent; the CI workflow installs it so the check runs.
