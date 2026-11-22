"""Asks mflux which Hugging Face cache entries it can load without downloading.

    python3.14 hf_cache_probe.py --hub <hub dir> <family>=<org/repo> ...
    python3.14 hf_cache_probe.py --download-spec <name> ...
    python3.14 hf_cache_probe.py --check

Prints one JSON object, {"<org/repo>": true | false, ...}. True means mflux's
loader would take the cached snapshot as it is. Only the loader can say that
(#19): a snapshot holds only the files the family's download patterns ask for,
not the whole repo, and a repo's index files can be stale upstream. mflux
follows the cache's links, so both layouts count: real files under
`models--…/blobs` (huggingface_hub 1.x, the bundled runtime) and links into a
shared store (huggingface_hub 2.x).

A family this mflux can't answer for is left out of the result, and the app
keeps its own size check for those repos.

`--download-spec` prints what mflux downloads for a model the app fetches from
an upstream repo, {"<name>": {"repo", "revision", "include"}}: the repo and
pinned revision mflux resolves, and the file patterns its weight definition
asks for. Only SeedVR2's names are known; others are left out.

`--check` runs the probe for every family against an empty cache and fails
unless each answers, and unless both SeedVR2 names answer a download spec. `_find_complete_cached_snapshot` is private to mflux, so
the runtime build runs it: an mflux bump that renames it fails the build, not
the app.
"""

import importlib
import json
import os
import sys
import tempfile

# The weight definition each family's loader passes to PathResolution, by the
# app's ModelFamily.id.
DEFINITIONS = {
    "flux.2": ("mflux.models.flux2.weights.flux2_weight_definition", "Flux2KleinWeightDefinition"),
    # FLUX 3 rides the `.flux` pipeline but has its own loader, and the two checkpoints
    # carry different weight sets — so each variant gets a dedicated key (see probeKey).
    "flux3": ("mflux.models.flux3.weights.flux3_weight_definition", "Flux3KleinWeightDefinition"),
    "flux3-base": ("mflux.models.flux3.weights.flux3_weight_definition", "Flux3KleinBaseWeightDefinition"),
    "ideogram4": ("mflux.models.ideogram4.weights.ideogram4_weight_definition", "Ideogram4WeightDefinition"),
    "krea2": ("mflux.models.krea2.weights.krea2_weight_definition", "Krea2WeightDefinition"),
    "z-image": ("mflux.models.z_image.weights.z_image_weight_definition", "ZImageWeightDefinition"),
    # The edit pipeline's definition: the app runs both modes through mflux-generate-qwen-2.1-edit.
    "qwenimage2.1": ("mflux.models.qwen21.weights.qwen_image21_weight_definition", "QwenImage21WeightDefinition"),
}

# The weight definition behind each name `--download-spec` answers.
SPECS = {
    "seedvr2-3b": ("mflux.models.seedvr2.weights.seedvr2_weight_definition", "SeedVR2WeightDefinition3B"),
    "seedvr2-7b": ("mflux.models.seedvr2.weights.seedvr2_weight_definition", "SeedVR2WeightDefinition7B"),
}


def layout(family, repo):
    # The download patterns and mflux-save subdirs the family's loader passes to
    # PathResolution (WeightLoader.load). The app loads mflux-community repos, which are
    # mflux-save uploads: Krea 2's keeps its transformer shards at the root, where the
    # patterns only name turbo.safetensors, so without the subdirs a complete download
    # would never count.
    from mflux.models.common.weights.loading.weight_definition import ComponentDefinition

    module, name = DEFINITIONS[family]
    definition = getattr(importlib.import_module(module), name)
    # Krea 2 picks its patterns by model name (Turbo or Raw), which is the repo ID.
    if family == "krea2":
        patterns = definition.get_download_patterns(repo)
    else:
        patterns = definition.get_download_patterns()
    saved_subdirs = list(ComponentDefinition.save_subdirs(definition.get_components()).values())
    return patterns, saved_subdirs


def probe(hub, requests):
    # huggingface_hub reads the cache location once, at import.
    os.environ["HF_HUB_CACHE"] = hub
    from mflux.models.common.resolution.path_resolution import PathResolution

    verdicts = {}
    for family, repo in requests:
        try:
            patterns, saved_subdirs = layout(family, repo)
        except Exception:  # noqa: BLE001 - an unknown family or an mflux without it: no answer
            continue
        verdicts[repo] = PathResolution._find_complete_cached_snapshot(repo, patterns, saved_subdirs) is not None
    return verdicts


def download_specs(names):
    specs = {}
    for name in names:
        try:
            from mflux.models.common.config.model_config import AVAILABLE_MODELS
            from mflux.models.common.resolution.model_revisions import ModelRevisions

            module, cls = SPECS[name]
            definition = getattr(importlib.import_module(module), cls)
            repo = AVAILABLE_MODELS[name].model_name
            specs[name] = {
                "repo": repo,
                "revision": ModelRevisions.get(repo),
                "include": list(definition.get_download_patterns()),
            }
        except Exception:  # noqa: BLE001 - an unknown name or an mflux without it: no answer
            continue
    return specs


def parse(argv):
    if len(argv) < 2 or argv[0] != "--hub":
        raise ValueError("usage: hf_cache_probe.py --hub <hub dir> <family>=<org/repo> ... | --check")
    requests = []
    for arg in argv[2:]:
        family, sep, repo = arg.partition("=")
        if not sep or not repo:
            raise ValueError(f"expected <family>=<org/repo>, got {arg!r}")
        requests.append((family, repo))
    return argv[1], requests


def check():
    requests = [(family, f"probe-check/{family}") for family in DEFINITIONS]
    with tempfile.TemporaryDirectory() as hub:
        verdicts = probe(hub, requests)
    missing = [repo for _, repo in requests if verdicts.get(repo) is not False]
    if missing:
        print(f"hf_cache_probe: no answer for {missing}", file=sys.stderr)
        return 1
    unanswered = [name for name in SPECS if name not in download_specs(SPECS)]
    if unanswered:
        print(f"hf_cache_probe: no download spec for {unanswered}", file=sys.stderr)
        return 1
    return 0


def main(argv):
    if argv == ["--check"]:
        return check()
    if argv[:1] == ["--download-spec"]:
        print(json.dumps(download_specs(argv[1:])))
        return 0
    try:
        hub, requests = parse(argv)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    print(json.dumps(probe(hub, requests)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
