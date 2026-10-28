"""Offline artifact validation and existing-pipeline integration tests."""

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from lib import metadata_discovery as metadata


class MetadataDiscoveryTests(unittest.TestCase):
    def test_invalid_registry_does_not_silently_discard_prior_decisions(self):
        for registry in [{"models": "broken"}, {"rejected": [{}]}, {"candidates": [{"tag": 123}]}]:
            with self.subTest(registry=registry), self.assertRaises(ValueError):
                metadata.export_candidates([], registry)

    def test_manifest_counts_projector_and_draft(self):
        layers = [
            {
                "mediaType": "application/vnd.ollama.image." + kind,
                "size": size,
                "digest": "sha256:" + hashlib.sha256(kind.encode()).hexdigest(),
            }
            for kind, size in [
                ("model", 2 * metadata.GIB),
                ("projector", metadata.GIB),
                ("draft", metadata.GIB),
                ("template", 20),
            ]
        ]
        with patch.object(metadata, "request_json", return_value={"layers": layers}):
            result = metadata.candidate_manifest("test:mini", 3, 0.4)
        self.assertEqual(result["weight_bytes"], 4 * metadata.GIB)
        self.assertFalse(result["candidate"])
        self.assertEqual(result["download_bytes"], 4 * metadata.GIB + 20)

    def test_manifest_rejects_cloud_only(self):
        with patch.object(metadata, "request_json", return_value={"layers": []}):
            with self.assertRaises(ValueError):
                metadata.candidate_manifest("test:cloud", 999)

    def test_only_discover_actual_family_tags(self):
        parser = metadata.LibraryLinks()
        parser.feed('<a href="/library/qwen3:4b">A</a><a href="/library/qwen3%3A8b">B</a>')
        self.assertEqual(parser.refs, {"qwen3:4b", "qwen3:8b"})

    def test_instruct_variant_is_examined_before_large_precision_variants(self):
        tags = ["qwen3:4b-fp16", "qwen3:4b-instruct", "qwen3:4b-q8_0", "qwen3:4b-q4_K_M"]
        self.assertEqual(
            sorted(tags, key=metadata.variant_priority),
            ["qwen3:4b-instruct", "qwen3:4b-q4_K_M", "qwen3:4b-q8_0", "qwen3:4b-fp16"],
        )

    def test_bad_manifest_descriptors_are_rejected(self):
        good = {
            "mediaType": "application/vnd.ollama.image.model",
            "size": 100,
            "digest": "sha256:" + "a" * 64,
        }
        manifests = [
            {"layers": [dict(good, size=-1)]},
            {"layers": [dict(good, size=True)]},
            {"layers": [dict(good, size="100")]},
            {"layers": [dict(good, digest="bad")]},
            {"layers": None},
            {"layers": [None]},
            {"layers": [good, dict(good, size=200)]},
        ]
        for manifest in manifests:
            with (
                self.subTest(manifest=manifest),
                patch.object(metadata, "request_json", return_value=manifest),
            ):
                with self.assertRaises(ValueError):
                    metadata.candidate_manifest("test:mini", 4)

    def test_config_blob_and_shared_downloads_count_once(self):
        model = {
            "mediaType": "application/vnd.ollama.image.model",
            "size": 100,
            "digest": "sha256:" + "a" * 64,
        }
        config = {
            "mediaType": "application/vnd.docker.container.image.v1+json",
            "size": 20,
            "digest": "sha256:" + "b" * 64,
        }
        with patch.object(
            metadata, "request_json", return_value={"layers": [model, model], "config": config}
        ):
            result = metadata.candidate_manifest("test:tiny", 4)
        self.assertEqual(result["download_bytes"], 120)
        self.assertEqual(result["weight_bytes"], 200)  # Memory screening remains conservative.

    def test_nonfinite_budget_and_invalid_tags_fail_before_network(self):
        with patch.object(metadata, "request_json") as fetch:
            for budget in (float("nan"), float("inf"), -1):
                with self.assertRaises(ValueError):
                    metadata.candidate_manifest("test:mini", budget)
            with self.assertRaises(ValueError):
                metadata.candidate_manifest("../private:latest", 4)
            fetch.assert_not_called()

    def test_export_preserves_registry_decisions_and_deduplicates_tags(self):
        def candidate(tag, fit=True):
            return dict(
                tag=tag,
                candidate=fit,
                weight_bytes=2 * metadata.GIB,
                source="https://registry.example/manifest",
                manifest_sha256="a" * 64,
            )

        registry = {
            "models": [{"tag": "phi4-mini"}],
            "rejected": [{"tag": "old:3b"}],
            "candidates": [{"tag": "pending:4b"}],
        }
        records = [
            candidate(t) for t in ["phi4-mini:latest", "old:3b", "pending:4b", "new:7b", "new:7b"]
        ]
        records.append(candidate("oversized:1b", False))
        before = json.dumps(registry, sort_keys=True)
        exported = metadata.export_candidates(records, registry)
        self.assertEqual([c["tag"] for c in exported], ["new:7b"])
        self.assertEqual(exported[0]["estimated_vram_gb"], 2)
        self.assertNotIn("retest", exported[0])
        self.assertEqual(json.dumps(registry, sort_keys=True), before)

    def test_export_runs_through_existing_filter_without_size_name_guess(self):
        yq = ROOT / "src/.tools/bin/yq"
        if not yq.exists():
            self.skipTest("Integration test requires project Go yq")
        import os
        import shutil

        candidate = dict(
            tag="verified:7b",
            candidate=True,
            weight_bytes=4 * metadata.GIB,
            source="fixture",
            manifest_sha256="a" * 64,
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "lib").mkdir()
            shutil.copy(ROOT / "src/03-filter.sh", root / "03-filter.sh")
            shutil.copy(ROOT / "src/lib/tools.sh", root / "lib/tools.sh")
            specs = {
                "hardware": {"gpu_vram_gb": 6, "gpu_vendor": "nvidia"},
                "thresholds": {"vram_headroom_gb": 1},
                "models": [],
                "rejected": [],
                "candidates": metadata.export_candidates([candidate]),
            }
            (root / "specs.yaml").write_text(json.dumps(specs))
            env = dict(os.environ, PATH=str(yq.parent) + ":" + os.environ["PATH"])
            result = subprocess.run(
                ["bash", str(root / "03-filter.sh")],
                env=env,
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(
                (root / "results/qualifying.txt").read_text().startswith("verified:7b|")
            )

    def test_discovery_refuses_to_overwrite_previous_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "discovery.json").write_text("original")
            args = argparse.Namespace(
                output=tmp,
                vram_gib=6,
                headroom_gib=1,
                context_reserve_gib=0.4,
                variants_per_family=1,
                families=["test"],
                spec=None,
            )
            with patch.object(metadata, "discover_tags") as fetch:
                with self.assertRaises(ValueError):
                    metadata.discovery(args)
                fetch.assert_not_called()
            self.assertEqual((Path(tmp) / "discovery.json").read_text(), "original")


if __name__ == "__main__":
    unittest.main()
