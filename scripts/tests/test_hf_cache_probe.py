"""Tests for Resources/hf_cache_probe.py, using a fake mflux package on PYTHONPATH."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PROBE = Path(__file__).resolve().parents[2] / "Resources" / "hf_cache_probe.py"

# A repo counts as complete when its cache folder has a `complete` marker for
# the patterns asked for, or a `saved` marker for the mflux-save subdirs asked
# for, so the tests can see which layout arrived.
PATH_RESOLUTION = '''
import os
from pathlib import Path

class PathResolution:
    @staticmethod
    def {name}(repo_id, patterns, saved_subdirs=None):
        folder = Path(os.environ["HF_HUB_CACHE"]) / ("models--" + repo_id.replace("/", "--"))
        marker = folder / "complete"
        if marker.is_file() and marker.read_text() == ",".join(patterns):
            return folder
        saved = folder / "saved"
        if saved_subdirs and saved.is_file() and saved.read_text() == ",".join(saved_subdirs):
            return folder
        return None
'''

# The real save_subdirs maps each component to its directory; the fake components are those names.
WEIGHT_DEFINITION = '''
class ComponentDefinition:
    @staticmethod
    def save_subdirs(components):
        return {{c: c for c in components}}
'''

DEFINITION = '''
class {cls}:
    @staticmethod
    def get_download_patterns({param}):
        return {patterns}

    @staticmethod
    def get_components():
        return {components}
'''

FAMILIES = {
    "flux2/weights/flux2_weight_definition.py": ("Flux2KleinWeightDefinition", "", '["transformer/*.safetensors"]'),
    # Both FLUX 3 checkpoints share one module (Base subclasses the distilled definition).
    "flux3/weights/flux3_weight_definition.py": (
        ["Flux3KleinWeightDefinition", "Flux3KleinBaseWeightDefinition"], "", '["vae/*.safetensors"]'
    ),
    "ideogram4/weights/ideogram4_weight_definition.py": ("Ideogram4WeightDefinition", "", '["vae/*.safetensors"]'),
    "krea2/weights/krea2_weight_definition.py": (
        "Krea2WeightDefinition", "model_name=None", '["raw.safetensors" if "raw" in model_name.lower() else "turbo.safetensors"]',
        # An mflux-save of Krea 2 keeps the transformer at the root.
        '["", "vae"]',
    ),
    "z_image/weights/z_image_weight_definition.py": ("ZImageWeightDefinition", "", '["vae/*.safetensors"]'),
    "qwen21/weights/qwen_image21_weight_definition.py": ("QwenImage21WeightDefinition", "", '["vae/*.safetensors"]'),
}

MODEL_CONFIG = """
import types
AVAILABLE_MODELS = {
    "seedvr2-3b": types.SimpleNamespace(model_name="numz/SeedVR2_comfyUI"),
    "seedvr2-7b": types.SimpleNamespace(model_name="numz/SeedVR2_comfyUI"),
}
"""

MODEL_REVISIONS = """
class ModelRevisions:
    @staticmethod
    def get(repo_id):
        return "rev123"
"""

SEEDVR2_DEFINITIONS = """
class SeedVR2WeightDefinition3B:
    @staticmethod
    def get_download_patterns():
        return ["seedvr2_ema_3b_fp16.safetensors", "ema_vae_fp16.safetensors"]

class SeedVR2WeightDefinition7B:
    @staticmethod
    def get_download_patterns():
        return ["seedvr2_ema_7b_fp16.safetensors", "ema_vae_fp16.safetensors"]
"""
WITHOUT_ZIMAGE = {path: family for path, family in FAMILIES.items() if not path.startswith("z_image/")}


class HFCacheProbeTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.site = root / "site"
        self.hub = root / "hub"
        self.hub.mkdir()
        self.write_mflux()

    def tearDown(self):
        self._tmp.cleanup()

    def write_mflux(self, private_name="_find_complete_cached_snapshot", families=FAMILIES, seedvr2=True):
        shutil.rmtree(self.site, ignore_errors=True)
        models = self.site / "mflux/models"
        files = {
            "common/resolution/path_resolution.py": PATH_RESOLUTION.format(name=private_name),
            "common/weights/loading/weight_definition.py": WEIGHT_DEFINITION.format(),
        }
        if seedvr2:
            files["common/config/model_config.py"] = MODEL_CONFIG
            files["common/resolution/model_revisions.py"] = MODEL_REVISIONS
            files["seedvr2/weights/seedvr2_weight_definition.py"] = SEEDVR2_DEFINITIONS
        for path, (cls, param, patterns, *rest) in families.items():
            components = rest[0] if rest else '["transformer", "vae"]'
            classes = cls if isinstance(cls, list) else [cls]
            files[path] = "".join(
                DEFINITION.format(cls=c, param=param, patterns=patterns, components=components) for c in classes
            )
        for path, source in files.items():
            target = models / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source)
        for folder in [self.site / "mflux", *[p for p in models.rglob("*") if p.is_dir()], models]:
            (folder / "__init__.py").touch()

    def cache(self, repo, patterns):
        folder = self.hub / ("models--" + repo.replace("/", "--"))
        folder.mkdir()
        (folder / "complete").write_text(",".join(patterns))

    def cache_saved(self, repo, subdirs):
        folder = self.hub / ("models--" + repo.replace("/", "--"))
        folder.mkdir()
        (folder / "saved").write_text(",".join(subdirs))

    def run_probe(self, *args):
        env = dict(os.environ, PYTHONPATH=str(self.site))
        env.pop("HF_HUB_CACHE", None)
        return subprocess.run([sys.executable, str(PROBE), *args], env=env, capture_output=True, text=True)

    def test_answers_each_repo_with_its_familys_patterns(self):
        self.cache("org/flux-done", ["transformer/*.safetensors"])
        self.cache("krea/Krea-2-Turbo", ["turbo.safetensors"])
        # Cached with another family's patterns: not complete for this one.
        self.cache("org/ideogram-wrong", ["transformer/*.safetensors"])
        result = self.run_probe(
            "--hub", str(self.hub),
            "flux.2=org/flux-done", "flux.2=org/flux-missing", "krea2=krea/Krea-2-Turbo", "ideogram4=org/ideogram-wrong",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "org/flux-done": True,
            "org/flux-missing": False,
            "krea/Krea-2-Turbo": True,
            "org/ideogram-wrong": False,
        })

    def test_counts_an_mflux_save_upload_by_its_saved_subdirs(self):
        # mflux-community/krea-2-turbo-mflux-q4 has no turbo.safetensors: its transformer
        # shards sit at the root, so only the saved layout says it is complete.
        self.cache_saved("mflux-community/krea-2-turbo-mflux-q4", ["", "vae"])
        self.cache_saved("mflux-community/krea-2-turbo-mflux-q8", ["vae"])
        result = self.run_probe(
            "--hub", str(self.hub),
            "krea2=mflux-community/krea-2-turbo-mflux-q4", "krea2=mflux-community/krea-2-turbo-mflux-q8",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "mflux-community/krea-2-turbo-mflux-q4": True,
            "mflux-community/krea-2-turbo-mflux-q8": False,
        })

    def test_leaves_out_families_this_mflux_cannot_answer_for(self):
        self.write_mflux(families=WITHOUT_ZIMAGE)
        self.cache("org/flux-done", ["transformer/*.safetensors"])
        result = self.run_probe("--hub", str(self.hub), "z-image=org/z", "nonsense=org/n", "flux.2=org/flux-done")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"org/flux-done": True})

    def test_rejects_malformed_arguments(self):
        self.assertEqual(self.run_probe().returncode, 2)
        self.assertEqual(self.run_probe("--hub", str(self.hub), "org/no-family").returncode, 2)

    def test_check_fails_when_a_family_is_missing(self):
        self.write_mflux(families=WITHOUT_ZIMAGE)
        result = self.run_probe("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("probe-check/z-image", result.stderr)

    def test_check_passes_when_every_family_answers(self):
        result = self.run_probe("--check")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_fails_when_mflux_renames_the_private_method(self):
        self.write_mflux(private_name="_find_cached_snapshot")
        result = self.run_probe("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("_find_complete_cached_snapshot", result.stderr)

    def test_download_spec_reports_repo_revision_and_patterns(self):
        result = self.run_probe("--download-spec", "seedvr2-3b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"seedvr2-3b": {
            "repo": "numz/SeedVR2_comfyUI",
            "revision": "rev123",
            "include": ["seedvr2_ema_3b_fp16.safetensors", "ema_vae_fp16.safetensors"],
        }})

    def test_download_spec_leaves_out_unknown_names(self):
        result = self.run_probe("--download-spec", "seedvr2-7b", "nonsense")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(json.loads(result.stdout)), ["seedvr2-7b"])

    def test_check_fails_without_seedvr2_definitions(self):
        self.write_mflux(seedvr2=False)
        result = self.run_probe("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("seedvr2-3b", result.stderr)


if __name__ == "__main__":
    unittest.main()
