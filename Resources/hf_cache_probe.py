"""Asks mflux which Hugging Face cache entries it can load without downloading.

    python3.14 hf_cache_probe.py --hub <hub dir> <family>=<org/repo> ...
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

`--check` runs the probe for every family against an empty cache and fails
unless each answers. `_find_complete_cached_snapshot` is private to mflux, so
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
    "ideogram4": ("mflux.models.ideogram4.weights.ideogram4_weight_definition", "Ideogram4WeightDefinition"),
    "krea2": ("mflux.models.krea2.weights.krea2_weight_definition", "Krea2WeightDefinition"),
    "z-image": ("mflux.models.z_image.weights.z_image_weight_definition", "ZImageWeightDefinition"),
}


def download_patterns(family, repo):
    module, name = DEFINITIONS[family]
    definition = getattr(importlib.import_module(module), name)
    # Krea 2 picks its patterns by model name (Turbo or Raw), which is the repo ID.
    if family == "krea2":
        return definition.get_download_patterns(repo)
    return definition.get_download_patterns()


def probe(hub, requests):
    # huggingface_hub reads the cache location once, at import.
    os.environ["HF_HUB_CACHE"] = hub
    from mflux.models.common.resolution.path_resolution import PathResolution

    verdicts = {}
    for family, repo in requests:
        try:
            patterns = download_patterns(family, repo)
        except Exception:  # noqa: BLE001 - an unknown family or an mflux without it: no answer
            continue
        verdicts[repo] = PathResolution._find_complete_cached_snapshot(repo, patterns) is not None
    return verdicts


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
    return 0


def main(argv):
    if argv == ["--check"]:
        return check()
    try:
        hub, requests = parse(argv)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    print(json.dumps(probe(hub, requests)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
