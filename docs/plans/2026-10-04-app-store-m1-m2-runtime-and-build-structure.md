# App Store build, milestones 1–2: Python runtime and build structure — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a pinned, license-checked, smoke-tested Python runtime, and an App Store build configuration that embeds and signs it inside a sandboxed app.

**Architecture:** The runtime is built outside Xcode by `scripts/build-python-runtime.sh` from pins in `Runtime/` and cached in `build/python-runtime/`. Build-time logic (license guard, acknowledgements, manifest, Mach-O scan) lives in a stdlib-only `scripts/runtime_tools.py`, unit-tested with `unittest`. `project.yml` gains `Debug-AppStore`/`Release-AppStore` configurations and an "(App Store)" scheme. A post-build phase (`scripts/embed-python-runtime.sh`) copies the runtime into `Contents/Resources/python` and signs it per flavor. The DMG configurations keep `BUNDLE_PYTHON_RUNTIME=NO` until milestone 4, so nothing about the shipped DMG changes in this plan.

**Tech stack:**
- Python: python-build-standalone CPython 3.14.7, `uv` (lock and install), stdlib `unittest`
- Shell: bash, which must run under macOS's `/bin/bash` 3.2
- Xcode: XcodeGen 2.46, Xcode 26, `codesign`
- CI: GitHub Actions

**Spec:** `docs/specs/2026-10-03-app-store-build-design.md`. This plan implements §1 and §2 and milestones 1–2. Read both documents.

**Branch:** `feature/app-store-runtime`, created from `docs/app-store-spec` so the spec and this plan travel with the code.

## Global Constraints

**Platform**
- Deployment target: macOS 26.0, Apple Silicon (arm64) only.

**Python runtime**
- **CPython:** 3.14.7 from python-build-standalone release `20260901`, variant `install_only_stripped`, `aarch64-apple-darwin`.
  - **URL:** `https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.14.7%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz`
  - **SHA-256:** `4632cb1a6edad9e73d3c81b6d2e69131637d995173e3e85005df14102b0592ba`
- **Lock generation:** `MACOSX_DEPLOYMENT_TARGET=26.0 uv pip compile … --python-platform aarch64-apple-darwin --python-version 3.14 --generate-hashes`. Without the deployment target, uv resolves for macOS 13, where `mlx>=0.31.2` has no wheels.
- **No opencv:** `opencv-python` is removed by override. The lock must contain no `opencv` line.
- **License rules:**
  - No package with a GPL, AGPL or LGPL license.
  - No `libav*`, `libsw*`, `libpostproc*`, `libx264*` or `libx265*` file anywhere in the runtime.
  - MPL-2.0 is allowed.
  - A package with no license metadata fails the guard unless `Runtime/license-overrides.json` names it.
- **Tool names** the runtime must provide, exactly: `mflux-generate-flux2`, `mflux-generate-flux2-edit`, `mflux-generate-ideogram4`, `mflux-generate-krea2`, `mflux-generate-z-image`, `mflux-generate-z-image-turbo`, `mflux-upscale-seedvr2`, `mflux-save`, `hf`, `mlx_lm.generate`, `mlx_vlm.generate`.

**App identity and bundle**
- **Bundle IDs:** DMG `com.mlxbits.image-studio` (unchanged); App Store `com.mlxbits.image-studio.appstore`.
- **Runtime location:** `Contents/Resources/python` inside the app.
- **Executables in the runtime** (`python3.14`, `torch_shm_manager`):
  - **App Store flavor:** exactly `com.apple.security.app-sandbox` + `com.apple.security.inherit`.
  - **DMG flavor:** no entitlements.
- **`BUNDLE_PYTHON_RUNTIME`:** `YES` for `Debug-AppStore`/`Release-AppStore`, `NO` for `Debug`/`Release` (until milestone 4).

**Process**
- **Lint gates unchanged:**
  - `swiftformat --lint --config .swiftformat .`
  - `swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict`
- **Tracked DMG scheme:** after every `xcodegen generate`, restore it:
  ```bash
  git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
  ```
  XcodeGen rewrites it with cosmetic differences. Commit `project.pbxproj` and any *new* scheme.
- **Shell scripts:**
  - start with `set -euo pipefail` and quote every path (the repo path contains spaces)
  - never expand a possibly-empty array as `"${arr[@]}"`; macOS bash 3.2 treats that as unbound under `set -u`
- **Commits:** no AI attribution of any kind (no `Co-Authored-By`, no "Generated with" lines).
- **Data safety:** don't launch the DMG flavor against real data while the user's own build is running. The App Store flavor uses its own container (`~/Library/Containers/com.mlxbits.image-studio.appstore`) and is safe to launch.

## Review Focus

Failure modes the spec implies but ordinary tests won't hit, most likely first. Each has a pinning test in the task named.

1. **Paths with spaces.** The repo is `…/MLXBits Image Studio`, and DerivedData paths contain spaces too. Every script must work there. Pinned by Task 3 (Mach-O scan of a folder with a space) and by Tasks 6 and 10, which run in the real repo path.
2. **An interrupted build must never look complete.** That covers a killed runtime build and a killed signing pass alike. The next run must rebuild rather than reuse half-built output. Pinned by Task 6, Step 5 (deleting `cache-key` forces a rebuild) and Task 10, Step 7 (deleting `.complete` forces a re-sign).
3. **A lock bump must replace the embedded runtime.** No stale files, and old signed copies pruned so DerivedData doesn't grow by 1.4 GB per bump. Pinned by Task 10, Step 8.
4. **macOS bash 3.2 with `set -u`.** Xcode runs build phases with `/bin/bash` 3.2, and an empty array expansion aborts the script. Pinned by Task 10, Step 5, which runs the sign script under `/bin/bash` in the plain flavor (empty entitlements array).
5. **Ad-hoc signing plus hardened runtime breaks Python.** Library validation rejects ad-hoc libraries under hardened runtime, which affects DMG Debug builds once milestone 4 turns bundling on. Pinned by Task 10, Step 6: ad-hoc-sign a plain copy, then import `mlx.core` and `mflux` with it.

---

## File map

| File | Status | Responsibility |
|---|---|---|
| `scripts/runtime_tools.py` | create | License guard, acknowledgements, manifest, Mach-O scan (stdlib only) |
| `scripts/tests/test_runtime_tools.py` | create | Unit tests for the above |
| `Resources/run_tool.py` | create | Runs a package's command-line tool by name; bundled into the app |
| `scripts/tests/test_run_tool.py` | create | Unit tests for `run_tool.py` |
| `Runtime/python.lock` | create | CPython download URL, SHA-256, version |
| `Runtime/requirements.in` | create | Top-level package pins |
| `Runtime/overrides.txt` | create | Removes `opencv-python` |
| `Runtime/requirements.lock` | create (generated) | Hashed lock, the build's only install input |
| `Runtime/license-overrides.json` | create | Licenses for packages without metadata |
| `Runtime/tools.txt` | create | The 11 tool names; smoke-test list and the future Swift contract |
| `scripts/lock-python-runtime.sh` | create | Regenerates `requirements.lock` |
| `scripts/build-python-runtime.sh` | create | Builds `build/python-runtime/` |
| `scripts/sign-python-runtime.sh` | create | Signs a runtime copy for one flavor and identity |
| `scripts/embed-python-runtime.sh` | create | Xcode phase: build if needed, sign once, rsync into the app |
| `.github/workflows/runtime.yml` | create | CI for the runtime |
| `Config/AppStore.xcconfig` | create | Optional include of the untracked `Local.xcconfig` |
| `Config/Local.xcconfig.example` | create | Template for the local team ID |
| `Resources/MLXBits_Image_Studio_AppStore.entitlements` | create | App Store app entitlements |
| `Resources/PythonRuntime-Sandboxed.entitlements` | create | Sandbox-inherit pair for runtime executables |
| `project.yml` | modify | Configs, per-config settings, `run_tool.py` resource, App Store scheme, embed phase, Info.plist bundle ID |
| `Resources/Info.plist` | regenerated | `CFBundleIdentifier` becomes `$(PRODUCT_BUNDLE_IDENTIFIER)` |
| `.gitignore` | modify | Ignore `Config/Local.xcconfig` |
| `.github/workflows/ci.yml` | modify | App Store compile-only job; `BUNDLE_PYTHON_RUNTIME=NO` on the test job |
| `README.md`, `AGENTS.md` | modify | How to build the runtime and the App Store flavor |

---

### Task 1: License classification and guard

**Files:**
- Create: `scripts/runtime_tools.py`
- Test: `scripts/tests/test_runtime_tools.py`

**Interfaces:**
- **Produces** (`scripts/runtime_tools.py`):
  - `PackageLicense(name: str, version: str, license: str, dist_info: Path)`: a frozen dataclass
  - `normalize(name: str) -> str`
  - `site_packages(prefix: Path) -> Path`
  - `read_licenses(site: Path) -> list[PackageLicense]`
  - `classify(pkg: PackageLicense, overrides: dict[str, str]) -> tuple[str, str]`: the verdict is `"ok"`, `"copyleft"` or `"unknown"`
  - `forbidden_binaries(root: Path) -> list[Path]`
  - `load_overrides(path: Path) -> dict[str, str]`
  - `guard(prefix: Path, overrides_file: Path) -> list[str]`: problem lines, empty when clean
- **Produces** (CLI): `runtime_tools.py guard <prefix> --overrides <file>` exits 0 when clean. Otherwise it prints each problem to stderr and exits 1.

- [ ] **Step 1: Create the branch**

```bash
cd "$(git rev-parse --show-toplevel)"
git switch docs/app-store-spec
git switch -c feature/app-store-runtime
mkdir -p scripts/tests
```

- [ ] **Step 2: Write the failing tests**

Create `scripts/tests/test_runtime_tools.py`:

```python
"""Tests for scripts/runtime_tools.py. Stdlib only: python3 -m unittest discover -s scripts/tests"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "scripts" / "runtime_tools.py"
sys.path.insert(0, str(TOOLS.parent))
import runtime_tools as rt  # noqa: E402


def make_prefix(tmp: Path) -> Path:
    """A fake python-build-standalone prefix with an empty site-packages."""
    prefix = tmp / "python"
    (prefix / "lib/python3.14/site-packages").mkdir(parents=True)
    (prefix / "lib/python3.14/LICENSE.txt").write_text("PSF LICENSE AGREEMENT FOR PYTHON\n")
    return prefix


def add_package(prefix: Path, name: str, version: str = "1.0", *, expression: str | None = None,
                classifiers: tuple[str, ...] = (), license_field: str | None = None,
                license_files: dict[str, str] | None = None) -> Path:
    site = prefix / "lib/python3.14/site-packages"
    dist = site / f"{name.replace('-', '_')}-{version}.dist-info"
    dist.mkdir()
    lines = ["Metadata-Version: 2.4", f"Name: {name}", f"Version: {version}"]
    if expression:
        lines.append(f"License-Expression: {expression}")
    if license_field:
        lines.append(f"License: {license_field}")
    lines += [f"Classifier: License :: {c}" for c in classifiers]
    (dist / "METADATA").write_text("\n".join(lines) + "\n\nLong description.\n")
    for fname, text in (license_files or {}).items():
        target = dist / "licenses" / fname
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    return dist


class LicenseClassificationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.prefix = make_prefix(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def verdict(self, overrides: dict[str, str] | None = None) -> tuple[str, str]:
        [pkg] = rt.read_licenses(rt.site_packages(self.prefix))
        return rt.classify(pkg, overrides or {})

    def test_spdx_expression_is_ok(self):
        add_package(self.prefix, "numpy", expression="BSD-3-Clause")
        self.assertEqual(self.verdict(), ("ok", "BSD-3-Clause"))

    def test_gpl_expression_is_copyleft(self):
        add_package(self.prefix, "badpkg", expression="GPL-3.0-or-later")
        self.assertEqual(self.verdict()[0], "copyleft")

    def test_lgpl_classifier_is_copyleft(self):
        add_package(self.prefix, "badpkg",
                    classifiers=("OSI Approved :: GNU Lesser General Public License v3 (LGPLv3)",))
        self.assertEqual(self.verdict()[0], "copyleft")

    def test_agpl_free_text_is_copyleft(self):
        add_package(self.prefix, "badpkg", license_field="GNU AFFERO GENERAL PUBLIC LICENSE")
        self.assertEqual(self.verdict()[0], "copyleft")

    def test_mpl_is_allowed(self):
        add_package(self.prefix, "certifi", classifiers=("OSI Approved :: Mozilla Public License 2.0 (MPL 2.0)",))
        self.assertEqual(self.verdict()[0], "ok")

    def test_missing_license_is_unknown(self):
        add_package(self.prefix, "hf_transfer")
        self.assertEqual(self.verdict(), ("unknown", ""))

    def test_long_free_text_license_is_unknown(self):
        # A License field holding the whole license text, not a name, can't be trusted.
        add_package(self.prefix, "oddpkg", license_field="Copyright (c) 2010 Somebody. " * 5)
        self.assertEqual(self.verdict()[0], "unknown")

    def test_override_resolves_unknown_with_normalized_name(self):
        add_package(self.prefix, "hf_transfer")
        self.assertEqual(self.verdict({"hf-transfer": "Apache-2.0"}), ("ok", "Apache-2.0"))

    def test_non_ascii_metadata_does_not_crash(self):
        add_package(self.prefix, "intlpkg", expression="MIT", license_field="Licença MIT — © Ünïcode")
        self.assertEqual(self.verdict()[0], "ok")


class ForbiddenBinaryTests(unittest.TestCase):
    def test_finds_ffmpeg_and_x264_but_not_avif(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "cv2/.dylibs").mkdir(parents=True)
            for name in ("libavcodec.61.19.101.dylib", "libx264.164.dylib", "libswscale.8.dylib",
                         "libavif.16.3.0.dylib", "libdav1d.7.dylib"):
                (root / "cv2/.dylibs" / name).write_bytes(b"")
            found = sorted(p.name for p in rt.forbidden_binaries(root))
            self.assertEqual(found, ["libavcodec.61.19.101.dylib", "libswscale.8.dylib", "libx264.164.dylib"])


class GuardCLITests(unittest.TestCase):
    def run_guard(self, prefix: Path, overrides: dict[str, str]) -> subprocess.CompletedProcess:
        overrides_file = prefix.parent / "overrides.json"
        overrides_file.write_text(json.dumps(overrides))
        return subprocess.run([sys.executable, str(TOOLS), "guard", str(prefix), "--overrides", str(overrides_file)],
                              capture_output=True, text=True)

    def test_clean_runtime_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = make_prefix(Path(tmp))
            add_package(prefix, "numpy", expression="BSD-3-Clause")
            add_package(prefix, "hf_transfer")
            result = self.run_guard(prefix, {"_comment": "why", "hf-transfer": "Apache-2.0"})
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_copyleft_unknown_and_binaries_all_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = make_prefix(Path(tmp))
            add_package(prefix, "badpkg", expression="GPL-2.0-only")
            add_package(prefix, "mystery")
            (prefix / "lib/libx264.164.dylib").write_bytes(b"")
            result = self.run_guard(prefix, {})
            self.assertEqual(result.returncode, 1)
            self.assertIn("badpkg 1.0: copyleft license (GPL-2.0-only)", result.stderr)
            self.assertIn("mystery 1.0: no license metadata", result.stderr)
            self.assertIn("lib/libx264.164.dylib", result.stderr)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: an ERROR on import, `ModuleNotFoundError: No module named 'runtime_tools'`.

- [ ] **Step 4: Write the implementation**

Create `scripts/runtime_tools.py`:

```python
#!/usr/bin/env python3
"""Build-time helpers for the Python runtime bundled into MLXBits Image Studio.

    runtime_tools.py guard <prefix> --overrides FILE
        Exit 1 if any installed package is GPL-family licensed or has no license
        metadata (and no entry in FILE), or if a GPL-family native library
        (FFmpeg, x264) is anywhere under <prefix>.

Stdlib only. The runtime build runs this with the bundled interpreter; the unit
tests run it with any python3 >= 3.10.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from email.parser import BytesParser
from email.policy import compat32
from pathlib import Path

COPYLEFT = re.compile(r"\b(A?GPL|LGPL)\b|GNU (AFFERO |LESSER |LIBRARY )?GENERAL PUBLIC", re.IGNORECASE)
# FFmpeg's libraries and the x264/x265 encoders. libavif (AV1 images, BSD) is fine.
FORBIDDEN_BINARY = re.compile(r"^lib(av(codec|format|util|device|filter)|sw(scale|resample)|postproc|x264|x265)\b")
# A License field longer than this is license *text*, not a license name.
MAX_LICENSE_NAME = 80


@dataclass(frozen=True)
class PackageLicense:
    name: str
    version: str
    license: str  # best-effort license name; "" when the metadata has none
    dist_info: Path


def normalize(name: str) -> str:
    """PEP 503 name normalization: hf_transfer, HF.Transfer and hf-transfer are one package."""
    return re.sub(r"[-_.]+", "-", name).lower()


def site_packages(prefix: Path) -> Path:
    matches = sorted(prefix.glob("lib/python3.*/site-packages"))
    if not matches:
        raise SystemExit(f"error: no lib/python3.*/site-packages under {prefix}")
    return matches[0]


def read_licenses(site: Path) -> list[PackageLicense]:
    packages = []
    for meta in sorted(site.glob("*.dist-info/METADATA")):
        with meta.open("rb") as fh:
            msg = BytesParser(policy=compat32).parse(fh)

        def field(key: str) -> str:
            return str(msg.get(key) or "").strip()  # str(): non-ASCII values parse as Header objects

        classifiers = [str(c).split("::")[-1].strip()
                       for c in msg.get_all("Classifier") or [] if str(c).startswith("License ::")]
        free_text = field("License")
        first_line = free_text.splitlines()[0].strip() if free_text else ""
        best = (field("License-Expression") or "; ".join(classifiers)
                or (first_line if len(first_line) <= MAX_LICENSE_NAME else ""))
        packages.append(PackageLicense(field("Name"), field("Version"), best, meta.parent))
    return packages


def classify(pkg: PackageLicense, overrides: dict[str, str]) -> tuple[str, str]:
    license_name = overrides.get(normalize(pkg.name), pkg.license)
    if not license_name:
        return "unknown", ""
    if COPYLEFT.search(license_name):
        return "copyleft", license_name
    return "ok", license_name


def forbidden_binaries(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*") if p.is_file() and FORBIDDEN_BINARY.match(p.name))


def load_overrides(path: Path) -> dict[str, str]:
    raw = json.loads(path.read_text())
    return {normalize(k): v for k, v in raw.items() if not k.startswith("_")}


def guard(prefix: Path, overrides_file: Path) -> list[str]:
    overrides = load_overrides(overrides_file)
    problems = []
    for pkg in read_licenses(site_packages(prefix)):
        verdict, license_name = classify(pkg, overrides)
        if verdict == "copyleft":
            problems.append(f"{pkg.name} {pkg.version}: copyleft license ({license_name})")
        elif verdict == "unknown":
            problems.append(f"{pkg.name} {pkg.version}: no license metadata; check it by hand "
                            f"and record it in {overrides_file.name}")
    problems += [f"GPL-family native library: {p.relative_to(prefix)}" for p in forbidden_binaries(prefix)]
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_guard = sub.add_parser("guard")
    p_guard.add_argument("prefix", type=Path)
    p_guard.add_argument("--overrides", type=Path, required=True)
    args = parser.parse_args(argv)

    if args.command == "guard":
        problems = guard(args.prefix, args.overrides)
        for line in problems:
            print(f"license guard: {line}", file=sys.stderr)
        return 1 if problems else 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: all 12 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/runtime_tools.py scripts/tests/test_runtime_tools.py
git commit -m "build: license guard for the bundled Python runtime"
```

---

### Task 2: Acknowledgements and manifest

**Files:**
- Modify: `scripts/runtime_tools.py`
- Test: `scripts/tests/test_runtime_tools.py`

**Interfaces:**
- **Consumes:** `read_licenses`, `site_packages`, `classify`, `load_overrides`, `normalize` (Task 1).
- **Produces:**
  - `license_texts(dist_info: Path) -> list[str]`
  - `acknowledgements(prefix: Path, python_version: str, overrides: dict[str, str]) -> str`
  - `manifest(prefix: Path, lock: Path, python_version: str, overrides: dict[str, str]) -> dict`, of the form `{"python": str, "lock_sha256": str, "packages": {normalized_name: {"version": str, "license": str}}}`
- **Produces** (CLI): `runtime_tools.py acknowledgements <prefix> <out> --overrides FILE [--python-version V]` and `runtime_tools.py manifest <prefix> <lock> <out> --overrides FILE [--python-version V]`. `--python-version` defaults to the running interpreter's `platform.python_version()`.

- [ ] **Step 1: Write the failing tests** (append to `scripts/tests/test_runtime_tools.py`, above the `if __name__` line)

```python
class AcknowledgementsTests(unittest.TestCase):
    def test_includes_cpython_and_every_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = make_prefix(Path(tmp))
            add_package(prefix, "alpha", "2.1", expression="MIT", license_files={"LICENSE": "MIT text for alpha"})
            add_package(prefix, "hf_transfer", "0.1.9")
            text = rt.acknowledgements(prefix, "3.14.7", {"hf-transfer": "Apache-2.0"})
            self.assertIn("CPython 3.14.7", text)
            self.assertIn("PSF LICENSE AGREEMENT FOR PYTHON", text)
            self.assertIn("alpha 2.1 (MIT)", text)
            self.assertIn("MIT text for alpha", text)
            self.assertIn("hf_transfer 0.1.9 (Apache-2.0)", text)
            self.assertIn("No license file is shipped with this package", text)

    def test_reads_root_level_license_files_too(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = make_prefix(Path(tmp))
            dist = add_package(prefix, "legacy", expression="BSD-2-Clause")
            (dist / "LICENSE.txt").write_text("BSD text for legacy")
            self.assertEqual(rt.license_texts(dist), ["BSD text for legacy"])


class ManifestTests(unittest.TestCase):
    def test_records_versions_licenses_and_lock_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = make_prefix(Path(tmp))
            add_package(prefix, "Alpha_Pkg", "2.1", expression="MIT")
            lock = Path(tmp) / "requirements.lock"
            lock.write_text("alpha-pkg==2.1\n")
            data = rt.manifest(prefix, lock, "3.14.7", {})
            self.assertEqual(data["python"], "3.14.7")
            self.assertEqual(data["lock_sha256"], hashlib.sha256(b"alpha-pkg==2.1\n").hexdigest())
            self.assertEqual(data["packages"], {"alpha-pkg": {"version": "2.1", "license": "MIT"}})

    def test_cli_writes_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = make_prefix(Path(tmp))
            add_package(prefix, "alpha", expression="MIT")
            lock = Path(tmp) / "requirements.lock"
            lock.write_text("alpha==1.0\n")
            overrides = Path(tmp) / "o.json"
            overrides.write_text("{}")
            out = Path(tmp) / "runtime-manifest.json"
            subprocess.run([sys.executable, str(TOOLS), "manifest", str(prefix), str(lock), str(out),
                            "--overrides", str(overrides), "--python-version", "3.14.7"], check=True)
            self.assertEqual(json.loads(out.read_text())["packages"]["alpha"]["version"], "1.0")
```

Also add `import hashlib` to the test file's import block at the top.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: the 4 new tests ERROR with `AttributeError: module 'runtime_tools' has no attribute 'acknowledgements'` (or `'license_texts'`, `'manifest'`).

- [ ] **Step 3: Write the implementation**

In `scripts/runtime_tools.py`:

1. Extend the module docstring's command list:

```
    runtime_tools.py acknowledgements <prefix> <out> --overrides FILE [--python-version V]
        Write CPython's license and every package's license texts to <out>.

    runtime_tools.py manifest <prefix> <lock> <out> --overrides FILE [--python-version V]
        Write runtime-manifest.json: Python version, lock hash, package versions and licenses.
```

2. Add the imports `hashlib` and `platform` to the import block.

3. Add these functions after `guard`:

```python
LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE)", re.IGNORECASE)


def license_texts(dist_info: Path) -> list[str]:
    """License files from a .dist-info: the PEP 639 licenses/ folder plus legacy root-level files."""
    candidates = set()
    licenses_dir = dist_info / "licenses"
    if licenses_dir.is_dir():
        candidates.update(p for p in licenses_dir.rglob("*") if p.is_file())
    candidates.update(p for p in dist_info.iterdir() if p.is_file() and LICENSE_FILE.match(p.name))
    return [p.read_text(encoding="utf-8", errors="replace").strip() for p in sorted(candidates)]


def acknowledgements(prefix: Path, python_version: str, overrides: dict[str, str]) -> str:
    rule = "-" * 72
    parts = ["Open-source software bundled with MLXBits Image Studio", "=" * 72, ""]
    cpython_license = next(iter(sorted(prefix.glob("lib/python3.*/LICENSE.txt"))), None)
    parts += [f"CPython {python_version}", rule]
    parts.append(cpython_license.read_text(encoding="utf-8", errors="replace").strip()
                 if cpython_license else "See https://docs.python.org/3/license.html")
    parts.append("")
    for pkg in read_licenses(site_packages(prefix)):
        _, license_name = classify(pkg, overrides)
        parts += [f"{pkg.name} {pkg.version}" + (f" ({license_name})" if license_name else ""), rule]
        texts = license_texts(pkg.dist_info)
        parts += texts or ["No license file is shipped with this package; see its project page."]
        parts.append("")
    return "\n".join(parts) + "\n"


def manifest(prefix: Path, lock: Path, python_version: str, overrides: dict[str, str]) -> dict:
    packages = {}
    for pkg in read_licenses(site_packages(prefix)):
        _, license_name = classify(pkg, overrides)
        packages[normalize(pkg.name)] = {"version": pkg.version, "license": license_name}
    return {
        "python": python_version,
        "lock_sha256": hashlib.sha256(lock.read_bytes()).hexdigest(),
        "packages": packages,
    }
```

4. In `main`, register the two subcommands after the `p_guard.add_argument(...)` lines and before `args = parser.parse_args(argv)`:

```python
    p_ack = sub.add_parser("acknowledgements")
    p_ack.add_argument("prefix", type=Path)
    p_ack.add_argument("out", type=Path)
    p_manifest = sub.add_parser("manifest")
    p_manifest.add_argument("prefix", type=Path)
    p_manifest.add_argument("lock", type=Path)
    p_manifest.add_argument("out", type=Path)
    for p in (p_ack, p_manifest):
        p.add_argument("--overrides", type=Path, required=True)
        p.add_argument("--python-version", default=platform.python_version())
```

5. Handle the two subcommands before the final `return 2`:

```python
    if args.command == "acknowledgements":
        args.out.write_text(acknowledgements(args.prefix, args.python_version, load_overrides(args.overrides)))
        return 0
    if args.command == "manifest":
        data = manifest(args.prefix, args.lock, args.python_version, load_overrides(args.overrides))
        args.out.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        return 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: all 16 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/runtime_tools.py scripts/tests/test_runtime_tools.py
git commit -m "build: acknowledgements and manifest for the bundled runtime"
```

---

### Task 3: Mach-O scan

**Files:**
- Modify: `scripts/runtime_tools.py`
- Test: `scripts/tests/test_runtime_tools.py`

**Interfaces:**
- **Produces:**
  - `macho_kind(path: Path) -> str | None`: `"exe"` for `MH_EXECUTE`, `"lib"` for any other Mach-O, `None` otherwise (including Java class files, which share the fat magic)
  - `macho_files(root: Path) -> list[tuple[str, Path]]`: skips symlinks, sorted by path
- **Produces** (CLI): `runtime_tools.py macho <dir>` prints `exe\t<path>` or `lib\t<path>` per line. Task 9's `sign-python-runtime.sh` consumes this.

- [ ] **Step 1: Write the failing tests** (append above `if __name__`)

```python
import struct  # noqa: E402

MH_MAGIC_64 = b"\xcf\xfa\xed\xfe"


def thin(filetype: int) -> bytes:
    # magic, cputype (ARM64), cpusubtype, filetype, then padding
    return MH_MAGIC_64 + struct.pack("<iiI", 0x0100000C, 0, filetype) + b"\0" * 16


def fat(filetype: int) -> bytes:
    header = struct.pack(">II", 0xCAFEBABE, 1) + struct.pack(">iiIII", 0x0100000C, 0, 4096, 32, 12)
    return header + b"\0" * (4096 - len(header)) + thin(filetype)


class MachOTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "dir with space"
        (self.root / "bin").mkdir(parents=True)
        (self.root / "bin/python3.14").write_bytes(thin(2))       # MH_EXECUTE
        (self.root / "libpython3.14.dylib").write_bytes(thin(6))  # MH_DYLIB
        (self.root / "_ext.cpython-314-darwin.so").write_bytes(thin(8))  # MH_BUNDLE
        (self.root / "universal_tool").write_bytes(fat(2))
        (self.root / "Klass.class").write_bytes(struct.pack(">II", 0xCAFEBABE, 0x34) + b"\0" * 32)
        (self.root / "notes.txt").write_text("hello")
        (self.root / "tiny").write_bytes(MH_MAGIC_64)
        (self.root / "link.dylib").symlink_to(self.root / "libpython3.14.dylib")

    def tearDown(self):
        self._tmp.cleanup()

    def test_kinds(self):
        self.assertEqual(rt.macho_kind(self.root / "bin/python3.14"), "exe")
        self.assertEqual(rt.macho_kind(self.root / "libpython3.14.dylib"), "lib")
        self.assertEqual(rt.macho_kind(self.root / "_ext.cpython-314-darwin.so"), "lib")
        self.assertEqual(rt.macho_kind(self.root / "universal_tool"), "exe")
        self.assertIsNone(rt.macho_kind(self.root / "Klass.class"))
        self.assertIsNone(rt.macho_kind(self.root / "notes.txt"))
        self.assertIsNone(rt.macho_kind(self.root / "tiny"))

    def test_cli_lists_each_real_file_once(self):
        out = subprocess.run([sys.executable, str(TOOLS), "macho", str(self.root)],
                             capture_output=True, text=True, check=True).stdout
        rows = sorted(line.split("\t") for line in out.splitlines())
        self.assertEqual([(kind, Path(p).name) for kind, p in rows], [
            ("exe", "python3.14"), ("exe", "universal_tool"),
            ("lib", "_ext.cpython-314-darwin.so"), ("lib", "libpython3.14.dylib"),
        ])
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: the 2 new tests ERROR with `AttributeError: module 'runtime_tools' has no attribute 'macho_kind'`, or fail on the CLI's `invalid choice: 'macho'`.

- [ ] **Step 3: Write the implementation**

In `scripts/runtime_tools.py`:

1. Add `import struct` to the imports.

2. Add to the docstring:

```
    runtime_tools.py macho <dir>
        Print "exe<TAB>path" or "lib<TAB>path" for every Mach-O file under <dir>.
```

3. Add the functions:

```python
MH_MAGIC_64 = b"\xcf\xfa\xed\xfe"
FAT_MAGIC = b"\xca\xfe\xba\xbe"
FAT_MAGIC_64 = b"\xca\xfe\xba\xbf"
MH_EXECUTE = 2


def macho_kind(path: Path) -> str | None:
    with path.open("rb") as fh:
        head = fh.read(32)
        if len(head) < 16:
            return None
        if head[:4] == MH_MAGIC_64:
            filetype = struct.unpack_from("<I", head, 12)[0]
        elif head[:4] in (FAT_MAGIC, FAT_MAGIC_64):
            count = struct.unpack_from(">I", head, 4)[0]
            if not 0 < count < 20:  # Java class files share 0xCAFEBABE; their "count" is a version >= 45
                return None
            offset_fmt = ">I" if head[:4] == FAT_MAGIC else ">Q"
            offset = struct.unpack_from(offset_fmt, head, 8 + 8)[0]  # first fat_arch: cputype, cpusubtype, offset
            fh.seek(offset)
            sub = fh.read(16)
            if len(sub) < 16 or sub[:4] != MH_MAGIC_64:
                return None
            filetype = struct.unpack_from("<I", sub, 12)[0]
        else:
            return None
    return "exe" if filetype == MH_EXECUTE else "lib"


def macho_files(root: Path) -> list[tuple[str, Path]]:
    found = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        kind = macho_kind(path)
        if kind:
            found.append((kind, path))
    return found
```

4. In `main`, register the subcommand alongside the others, before `args = parser.parse_args(argv)`:

```python
    p_macho = sub.add_parser("macho")
    p_macho.add_argument("root", type=Path)
```

5. Handle it before the final `return 2`:

```python
    if args.command == "macho":
        for kind, path in macho_files(args.root):
            print(f"{kind}\t{path}")
        return 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: all 18 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/runtime_tools.py scripts/tests/test_runtime_tools.py
git commit -m "build: Mach-O scan for signing the bundled runtime"
```

---

### Task 4: `run_tool.py`

**Files:**
- Create: `Resources/run_tool.py`
- Test: `scripts/tests/test_run_tool.py`
- Modify: `project.yml` (bundle it as a resource)

**Interfaces:**
- **Produces:** `python3.14 Resources/run_tool.py <tool-name> [args…]`.
  - Runs the console-script entry point named `<tool-name>`, with `sys.argv = [<tool-name>, *args]`.
  - Exit semantics are exactly those of a pip-generated launcher script, `sys.exit(main())`: `None` exits 0, an int exits with that code, and a string is printed to stderr and exits 1.
  - Exits 127 for an unknown tool and 2 for no arguments.
  - Task 6 (smoke test) consumes it, and so will milestone 4's Swift `Toolchain`.

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/test_run_tool.py`:

```python
"""Tests for Resources/run_tool.py, using a fake installed package on PYTHONPATH."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RUN_TOOL = Path(__file__).resolve().parents[2] / "Resources" / "run_tool.py"

FAKE_MODULE = '''
import sys

def echo():
    print(repr(sys.argv))
    return 3

def quiet():
    return None

def complain():
    return "something went wrong"
'''


class RunToolTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        site = Path(self._tmp.name)
        (site / "fakepkg").mkdir()
        (site / "fakepkg/__init__.py").write_text(FAKE_MODULE)
        dist = site / "fakepkg-1.0.dist-info"
        dist.mkdir()
        (dist / "METADATA").write_text("Metadata-Version: 2.1\nName: fakepkg\nVersion: 1.0\n")
        (dist / "entry_points.txt").write_text(
            "[console_scripts]\nfake-echo = fakepkg:echo\nfake-quiet = fakepkg:quiet\n"
            "fake.complain = fakepkg:complain\n")
        self.env = {**os.environ, "PYTHONPATH": str(site), "PYTHONDONTWRITEBYTECODE": "1"}

    def tearDown(self):
        self._tmp.cleanup()

    def run_tool(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(RUN_TOOL), *args], capture_output=True, text=True, env=self.env)

    def test_passes_name_and_arguments_as_argv_and_returns_exit_code(self):
        result = self.run_tool("fake-echo", "--flag", "two words")
        self.assertEqual(result.stdout.strip(), repr(["fake-echo", "--flag", "two words"]))
        self.assertEqual(result.returncode, 3)

    def test_none_exits_zero(self):
        self.assertEqual(self.run_tool("fake-quiet").returncode, 0)

    def test_string_result_is_printed_and_exits_one(self):
        result = self.run_tool("fake.complain")
        self.assertEqual(result.returncode, 1)
        self.assertIn("something went wrong", result.stderr)

    def test_unknown_tool_exits_127(self):
        result = self.run_tool("no-such-tool")
        self.assertEqual(result.returncode, 127)
        self.assertIn("no-such-tool", result.stderr)

    def test_no_arguments_exits_2(self):
        self.assertEqual(self.run_tool().returncode, 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: the 5 new tests FAIL (`can't open file …/Resources/run_tool.py`, exit code 2 where others are expected).

- [ ] **Step 3: Write the implementation**

Create `Resources/run_tool.py`:

```python
"""Runs a bundled package's command-line tool by name.

    python3.14 run_tool.py <tool-name> [args...]

<tool-name> is a console-script name such as `mflux-generate-flux2` or `hf`. It
is looked up in the interpreter's installed package metadata, so the app never
depends on the launcher scripts in bin/, whose shebangs hold absolute paths
that break once the runtime is copied into the app bundle. Exit semantics match
those launchers exactly: sys.exit(<tool's return value>).
"""

import sys
from importlib.metadata import entry_points


def main(argv):
    if len(argv) < 2:
        print("usage: run_tool.py <tool-name> [args...]", file=sys.stderr)
        return 2
    name = argv[1]
    matches = entry_points(group="console_scripts", name=name)
    if not matches:
        print(f"run_tool.py: no installed tool named {name!r}", file=sys.stderr)
        return 127
    tool = next(iter(matches)).load()
    sys.argv = [name, *argv[2:]]
    return tool()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: all 23 tests PASS.

- [ ] **Step 5: Bundle it with the app**

In `project.yml`, in the app target's `sources:` list, after the `Resources/mflux_driver.py` entry, add:

```yaml
      - path: Resources/run_tool.py
        buildPhase: resources
```

Then regenerate and restore the tracked scheme:

```bash
xcodegen generate
git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
git diff --stat
```

Expected: `project.yml` and `project.pbxproj` changed; nothing else.

- [ ] **Step 6: Commit**

```bash
git add Resources/run_tool.py scripts/tests/test_run_tool.py project.yml "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: run_tool.py runs bundled command-line tools by name"
```

---

### Task 5: Runtime pins and lock

**Files:**
- Create: `Runtime/python.lock`, `Runtime/requirements.in`, `Runtime/overrides.txt`, `Runtime/license-overrides.json`, `Runtime/tools.txt`, `scripts/lock-python-runtime.sh`
- Create (generated): `Runtime/requirements.lock`

**Interfaces:**
- **Produces:**
  - `Runtime/python.lock`: three `key=value` lines, `url`, `sha256`, `version`
  - `Runtime/tools.txt`: one tool name per line; `#` comments and blank lines are ignored
  - Task 6's build script reads all of these.

- [ ] **Step 1: Write the pin files**

`Runtime/python.lock`:

```
# python-build-standalone CPython for the bundled runtime. Bump all three together;
# the SHA-256 comes from the release's SHA256SUMS asset.
url=https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.14.7%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz
sha256=4632cb1a6edad9e73d3c81b6d2e69131637d995173e3e85005df14102b0592ba
version=3.14.7
```

`Runtime/requirements.in`:

```
# Everything the app runs on the bundled Python. After any change, re-lock:
#   scripts/lock-python-runtime.sh
# mflux is pinned exactly: a bump is a deliberate app change (new model families,
# changed CLI flags) and ships with an app release.
mflux==0.21.0
# Local Gemma for the Scenario Generator and caption tools (Utilities/GemmaChatRunner.swift).
mlx-lm>=0.31.3
# Pinned, not a floor: 0.6.4 regressed gemma4_unified (see GemmaChatRunner.swift).
mlx-vlm==0.6.3
# One pin both sides accept: mflux needs >=5.5; mlx-lm/mlx-vlm break on 5.13.
transformers>=5.5,<5.13
```

`Runtime/overrides.txt`:

```
# Remove opencv-python everywhere it is declared (mflux, mlx-vlm). Its wheel
# bundles FFmpeg built with libx264, which is GPL. Nothing Image Studio runs
# imports cv2: mflux uses it only for ControlNet/OpenPose/HED, mlx-vlm only for
# video input. A marker that can never match drops the requirement.
opencv-python ; sys_platform == "never"
```

`Runtime/license-overrides.json`. Keys are package names; values are the license verified by hand against the project's repository:

```json
{
  "_comment": "Packages whose metadata carries no license. Verify against the project's repo before adding one.",
  "hf-transfer": "Apache-2.0"
}
```

`Runtime/tools.txt`:

```
# Command-line tools the app runs through Resources/run_tool.py. The runtime
# build smoke-tests each with --help, and the Swift toolchain is tested against
# this list, so a renamed command fails a build instead of a user's job.
mflux-generate-flux2
mflux-generate-flux2-edit
mflux-generate-ideogram4
mflux-generate-krea2
mflux-generate-z-image
mflux-generate-z-image-turbo
mflux-upscale-seedvr2
mflux-save
hf
mlx_lm.generate
mlx_vlm.generate
```

`scripts/lock-python-runtime.sh`:

```bash
#!/bin/bash
# Re-resolves Runtime/requirements.lock from Runtime/requirements.in.
#
# MACOSX_DEPLOYMENT_TARGET matters: without it uv resolves for macOS 13, where
# mlx >= 0.31.2 publishes no wheels, and the resolution fails.
set -euo pipefail
cd "$(dirname "$0")/.."
MACOSX_DEPLOYMENT_TARGET=26.0 uv pip compile Runtime/requirements.in \
  --override Runtime/overrides.txt \
  --python-platform aarch64-apple-darwin \
  --python-version 3.14 \
  --generate-hashes \
  --no-config \
  --output-file Runtime/requirements.lock
```

- [ ] **Step 2: Generate the lock**

```bash
chmod +x scripts/lock-python-runtime.sh
scripts/lock-python-runtime.sh
```

Expected: exit 0 and `Runtime/requirements.lock` written.

- [ ] **Step 3: Verify the lock**

```bash
grep -E "^(mflux|mlx|mlx-lm|mlx-vlm|transformers|torch)==" Runtime/requirements.lock | cut -d' ' -f1
grep -ci opencv Runtime/requirements.lock
grep -cE '^[a-z0-9]' Runtime/requirements.lock
```

Expected:
- `mflux==0.21.0`, `mlx==0.32.3`, `mlx-lm==0.32.0`, `mlx-vlm==0.6.3`, `transformers==5.12.1`, `torch==2.14.1`. If PyPI has since published newer patch releases of the floored packages, newer versions are fine as long as `transformers` stays below 5.13.
- An opencv count of `0`.
- About 86 packages.

- [ ] **Step 4: Commit**

```bash
git add Runtime/ scripts/lock-python-runtime.sh
git commit -m "build: pin and lock the bundled Python runtime"
```

---

### Task 6: Runtime build script

**Files:**
- Create: `scripts/build-python-runtime.sh`

**Interfaces:**
- **Consumes:** every file in `Runtime/` (Task 5), `scripts/runtime_tools.py` (Tasks 1–3), `Resources/run_tool.py` (Task 4).
- **Produces:**
  - `build/python-runtime/python/`: the runtime, with `bin/python3.14`, `Acknowledgements.txt` and `runtime-manifest.json` at its top level
  - `build/python-runtime/cache-key`: a 16-hex-character key, written last
  - Re-running with unchanged inputs exits 0 immediately.
  - Task 10's embed script consumes all of it.

- [ ] **Step 1: Write the script**

Create `scripts/build-python-runtime.sh`:

```bash
#!/bin/bash
# Builds the Python runtime bundled into the app: the pinned standalone CPython
# plus the locked packages, trimmed, precompiled, license-checked and
# smoke-tested.
#
#   Output: build/python-runtime/python/   the runtime
#           build/python-runtime/cache-key written last; its presence means "complete"
#
# A no-op while the inputs are unchanged, so the Xcode build phase can call it
# on every build. Requires uv (brew install uv) and network on a cold build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/python-runtime"
PREFIX="$OUT/python"

INPUTS="Runtime/python.lock Runtime/requirements.lock Runtime/license-overrides.json Runtime/tools.txt
scripts/build-python-runtime.sh scripts/runtime_tools.py Resources/run_tool.py"
KEY=$(cd "$ROOT" && for f in $INPUTS; do cat "$f"; done | shasum -a 256 | cut -c1-16)

lock_value() { sed -n "s/^$1=//p" "$ROOT/Runtime/python.lock"; }
VERSION=$(lock_value version)
MINOR=${VERSION%.*}
PY="$PREFIX/bin/python$MINOR"

if [ -f "$OUT/cache-key" ] && [ "$(cat "$OUT/cache-key")" = "$KEY" ] && [ -x "$PY" ]; then
  echo "Python runtime up to date ($KEY)"
  exit 0
fi

command -v uv >/dev/null || { echo "error: uv is required to build the Python runtime (brew install uv)" >&2; exit 1; }

echo "Building Python runtime ($KEY)"
rm -rf "$OUT"
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "→ CPython $VERSION"
curl -fsSL --retry 3 -o "$WORK/python.tar.gz" "$(lock_value url)"
echo "$(lock_value sha256)  $WORK/python.tar.gz" | shasum -a 256 -c - >/dev/null
tar -xzf "$WORK/python.tar.gz" -C "$OUT"  # the archive's root folder is python/
[ -x "$PY" ] || { echo "error: $PY missing after extraction" >&2; exit 1; }

echo "→ Locked packages"
uv pip install --python "$PY" --break-system-packages --require-hashes --no-deps --no-config \
  --quiet -r "$ROOT/Runtime/requirements.lock"

echo "→ Trimming"
LIB="$PREFIX/lib"
STDLIB="$LIB/python$MINOR"
rm -rf "$LIB"/itcl* "$LIB"/libtcl* "$LIB"/tcl9* "$LIB"/tk9* "$LIB"/thread* "$LIB/pkgconfig" \
  "$STDLIB/tkinter" "$STDLIB/idlelib" "$STDLIB/turtledemo" "$STDLIB/ensurepip" "$STDLIB/__phello__" \
  "$STDLIB"/lib-dynload/_tkinter* \
  "$PREFIX/include" "$PREFIX/share" \
  "$STDLIB/site-packages/torch/include" "$STDLIB"/site-packages/torch/bin/protoc*
# bin/ launchers have absolute shebangs that break once moved; the app runs
# tools through run_tool.py instead.
find "$PREFIX/bin" -mindepth 1 ! -name "python$MINOR" -exec rm -f {} +

echo "→ Bytecode"
find "$PREFIX" -name __pycache__ -type d -prune -exec rm -rf {} +
# unchecked-hash: Python never re-validates or rewrites these inside the signed bundle.
"$PY" -m compileall -q -j 0 --invalidation-mode unchecked-hash "$STDLIB" >/dev/null \
  || echo "  note: some files could not be compiled and stay source-only"

export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 HF_HOME="$WORK/hf" MPLCONFIGDIR="$WORK/mpl"
TOOLS="$ROOT/scripts/runtime_tools.py"
OVERRIDES="$ROOT/Runtime/license-overrides.json"

echo "→ License guard"
"$PY" "$TOOLS" guard "$PREFIX" --overrides "$OVERRIDES"
"$PY" "$TOOLS" acknowledgements "$PREFIX" "$PREFIX/Acknowledgements.txt" --overrides "$OVERRIDES"
"$PY" "$TOOLS" manifest "$PREFIX" "$ROOT/Runtime/requirements.lock" "$PREFIX/runtime-manifest.json" \
  --overrides "$OVERRIDES"

echo "→ Smoke test"
"$PY" -c "import mflux, mlx.core, mlx_lm, mlx_vlm, torch"
grep -vE '^[[:space:]]*(#|$)' "$ROOT/Runtime/tools.txt" | while read -r tool; do
  if ! "$PY" "$ROOT/Resources/run_tool.py" "$tool" --help >/dev/null 2>"$WORK/err"; then
    echo "error: '$tool --help' failed:" >&2
    cat "$WORK/err" >&2
    exit 1
  fi
done

echo "→ $(du -sh "$PREFIX" | cut -f1) in $PREFIX"
echo "$KEY" >"$OUT/cache-key"
```

- [ ] **Step 2: Run it cold**

```bash
chmod +x scripts/build-python-runtime.sh
time scripts/build-python-runtime.sh
```

Expected:
- Each `→` stage prints, ending with a size line of about 1.3G.
- The script exits 0.
- A cold build takes a few minutes; with a warm uv cache it's well under a minute.

- [ ] **Step 3: Check the output**

```bash
ls build/python-runtime/python/bin
head -3 build/python-runtime/python/Acknowledgements.txt
python3 -c 'import json; d=json.load(open("build/python-runtime/python/runtime-manifest.json")); print(d["python"], d["packages"]["mflux"], len(d["packages"]))'
ls build/python-runtime/python/lib | grep -ciE "tcl|tk" || true
```

Expected:
- `bin` contains only `python3.14`.
- The acknowledgements header shows.
- The manifest line reads `3.14.7 {'version': '0.21.0', 'license': …} 86`. The license is whatever mflux's metadata declares, for example `MIT`; the package count is about 86.
- The Tcl/Tk count is `0`.

- [ ] **Step 4: Verify the re-run is a no-op**

Run: `time scripts/build-python-runtime.sh`
Expected: `Python runtime up to date (<key>)` in well under a second.

- [ ] **Step 5: Verify an incomplete build is rebuilt** (Review Focus 2)

```bash
rm build/python-runtime/cache-key
scripts/build-python-runtime.sh | head -2
```

Expected: `Building Python runtime (<key>)`, followed by a full rebuild that ends in exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/build-python-runtime.sh
git commit -m "build: script that builds, trims, checks and smoke-tests the Python runtime"
```

---

### Task 7: Runtime CI workflow

**Files:**
- Create: `.github/workflows/runtime.yml`

**Interfaces:**
- **Consumes:** `scripts/tests/`, `scripts/build-python-runtime.sh`.

- [ ] **Step 1: Write the workflow**

```yaml
name: Runtime

# Builds the Python runtime bundled into the app whenever its inputs change:
# runs the build-script unit tests, then resolves and installs the locked
# packages, runs the license guard, and smoke-tests every tool the app runs.
# Separate from ci.yml because it downloads ~1 GB and only matters when the
# runtime's inputs change.
on:
  pull_request:
    paths:
      - "Runtime/**"
      - "scripts/build-python-runtime.sh"
      - "scripts/runtime_tools.py"
      - "scripts/tests/**"
      - "Resources/run_tool.py"
      - ".github/workflows/runtime.yml"
  push:
    branches: [main]
    paths:
      - "Runtime/**"
      - "scripts/build-python-runtime.sh"
      - "scripts/runtime_tools.py"
      - "scripts/tests/**"
      - "Resources/run_tool.py"
      - ".github/workflows/runtime.yml"

concurrency:
  group: runtime-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  runtime:
    name: Build & check runtime
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7

      - uses: astral-sh/setup-uv@v10

      - name: Unit tests (runtime scripts)
        run: python3 -m unittest discover -s scripts/tests -v

      # Same inputs as the script's own cache key, so a hit means this exact
      # runtime already passed the guard and smoke test.
      - name: Restore runtime
        uses: actions/cache@v6
        with:
          path: build/python-runtime
          key: python-runtime-${{ hashFiles('Runtime/**', 'scripts/build-python-runtime.sh', 'scripts/runtime_tools.py', 'Resources/run_tool.py') }}

      - name: Build runtime (license guard + smoke test)
        run: scripts/build-python-runtime.sh

      - name: Report
        run: |
          {
            echo "### Python runtime"
            echo "Size: $(du -sh build/python-runtime/python | cut -f1)"
            echo "Packages: $(python3 -c 'import json; print(len(json.load(open("build/python-runtime/python/runtime-manifest.json"))["packages"]))')"
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: Validate the YAML locally**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/runtime.yml"); puts "ok"'`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/runtime.yml
git commit -m "ci: build and check the Python runtime when its inputs change"
```

The workflow first runs when the branch's PR is opened in Task 12. If `import mlx.core` fails on the hosted runner because it lacks a Metal device, change the smoke test's import line in `build-python-runtime.sh` to skip `mlx.core` only when `CI=true`, and leave a comment saying why. The `--help` checks for tools don't touch the GPU.

---

### Task 8: App Store configurations

**Files:**
- Create: `Config/AppStore.xcconfig`, `Config/Local.xcconfig.example`, `Resources/MLXBits_Image_Studio_AppStore.entitlements`
- Modify: `project.yml`, `.gitignore`
- Regenerated: `Resources/Info.plist`, `MLXBits Image Studio.xcodeproj/project.pbxproj`

**Interfaces:**
- **Produces:**
  - build configurations `Debug-AppStore` and `Release-AppStore`
  - build settings `BUNDLE_PYTHON_RUNTIME` and `PYTHON_RUNTIME_SANDBOXED` (`YES`/`NO`), which Task 10 reads
  - Swift compilation condition `APP_STORE` in the App Store configurations

- [ ] **Step 1: Write the config and entitlement files**

`Config/AppStore.xcconfig`:

```
// App Store configurations (Debug-AppStore, Release-AppStore).
//
// Signing needs your Apple Developer Team ID, which this repo keeps out of
// version control: copy Config/Local.xcconfig.example to Config/Local.xcconfig
// and fill it in. CI passes DEVELOPMENT_TEAM on the xcodebuild command line.
#include? "Local.xcconfig"
```

`Config/Local.xcconfig.example`:

```
// Copy to Config/Local.xcconfig (gitignored) and set your Apple Developer Team
// ID: the 10-character ID under developer.apple.com → Membership details.
DEVELOPMENT_TEAM = ABCDE12345
```

`Resources/MLXBits_Image_Studio_AppStore.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.assets.pictures.read-write</key>
	<true/>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
```

Append to `.gitignore`, under the existing "Local secrets" block:

```
Config/Local.xcconfig
```

- [ ] **Step 2: Edit `project.yml`**

1. After the `options:` block, add:

```yaml
# Debug/Release build the DMG app; the -AppStore pair builds the sandboxed App
# Store app from the same sources (docs/specs/2026-10-03-app-store-build-design.md).
configs:
  Debug: debug
  Release: release
  Debug-AppStore: debug
  Release-AppStore: release

configFiles:
  Debug-AppStore: Config/AppStore.xcconfig
  Release-AppStore: Config/AppStore.xcconfig
```

2. In the app target's `info.properties`, change `CFBundleIdentifier: com.mlxbits.image-studio` to:

```yaml
        CFBundleIdentifier: "$(PRODUCT_BUNDLE_IDENTIFIER)"
```

3. Replace the app target's `settings:` block (currently `base:` with `PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER` and `ASSETCATALOG_COMPILER_APPICON_NAME`) with:

```yaml
    settings:
      base:
        PRODUCT_NAME: "MLXBits Image Studio"
        PRODUCT_BUNDLE_IDENTIFIER: com.mlxbits.image-studio
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        # Read by scripts/embed-python-runtime.sh. The DMG configurations switch
        # BUNDLE_PYTHON_RUNTIME on when the app starts using the runtime.
        BUNDLE_PYTHON_RUNTIME: NO
        PYTHON_RUNTIME_SANDBOXED: NO
      configs:
        Debug-AppStore:
          PRODUCT_BUNDLE_IDENTIFIER: com.mlxbits.image-studio.appstore
          CODE_SIGN_ENTITLEMENTS: Resources/MLXBits_Image_Studio_AppStore.entitlements
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) APP_STORE"
          BUNDLE_PYTHON_RUNTIME: YES
          PYTHON_RUNTIME_SANDBOXED: YES
          # A stable identity: ad-hoc signatures change every build, which
          # invalidates security-scoped bookmarks. Team from Config/Local.xcconfig.
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: Apple Development
        Release-AppStore:
          PRODUCT_BUNDLE_IDENTIFIER: com.mlxbits.image-studio.appstore
          CODE_SIGN_ENTITLEMENTS: Resources/MLXBits_Image_Studio_AppStore.entitlements
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) APP_STORE"
          BUNDLE_PYTHON_RUNTIME: YES
          PYTHON_RUNTIME_SANDBOXED: YES
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: Apple Distribution
```

- [ ] **Step 3: Generate and restore the tracked scheme**

```bash
xcodegen generate
git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
```

- [ ] **Step 4: Verify the per-configuration settings**

```bash
for c in Debug Release Debug-AppStore Release-AppStore; do
  echo "== $c"
  xcodebuild -project "MLXBits Image Studio.xcodeproj" -target "MLXBits Image Studio" -configuration "$c" \
    -showBuildSettings 2>/dev/null \
    | grep -E " (PRODUCT_BUNDLE_IDENTIFIER|CODE_SIGN_ENTITLEMENTS|SWIFT_ACTIVE_COMPILATION_CONDITIONS|BUNDLE_PYTHON_RUNTIME|PYTHON_RUNTIME_SANDBOXED|CODE_SIGN_IDENTITY) ="
done
grep -A1 CFBundleIdentifier Resources/Info.plist
```

Expected:

| Config | Bundle ID | Entitlements | Conditions | Runtime / sandboxed | Identity |
|---|---|---|---|---|---|
| Debug | `com.mlxbits.image-studio` | `Resources/MLXBits_Image_Studio.entitlements` | `DEBUG` | `NO` / `NO` | `-` or `Apple Development` |
| Release | `com.mlxbits.image-studio` | `Resources/MLXBits_Image_Studio.entitlements` | (none) | `NO` / `NO` | unchanged |
| Debug-AppStore | `…appstore` | `…AppStore.entitlements` | `DEBUG APP_STORE` | `YES` / `YES` | `Apple Development` |
| Release-AppStore | `…appstore` | `…AppStore.entitlements` | `APP_STORE` | `YES` / `YES` | `Apple Distribution` |

`Info.plist` shows `$(PRODUCT_BUNDLE_IDENTIFIER)`.

**If the App Store rows still show the DMG entitlements file:** XcodeGen's `entitlements:` key wrote `CODE_SIGN_ENTITLEMENTS` at a level the config override doesn't beat. Then remove the `entitlements:` key from the target. Keep `Resources/MLXBits_Image_Studio.entitlements` as a plain tracked file with its current contents, and add `CODE_SIGN_ENTITLEMENTS: Resources/MLXBits_Image_Studio.entitlements` to `settings.base`. Regenerate, restore the scheme, and re-run this step.

- [ ] **Step 5: Verify the DMG flavor is unaffected**

Run: `xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio" build -quiet`
Expected: `** BUILD SUCCEEDED **`, or silence with `-quiet` and exit 0. The build log shows no "Embed Python runtime" phase yet; it arrives in Task 10.

- [ ] **Step 6: Commit**

```bash
git add Config/AppStore.xcconfig Config/Local.xcconfig.example Resources/MLXBits_Image_Studio_AppStore.entitlements \
  .gitignore project.yml Resources/Info.plist "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "build: App Store configurations with their own bundle ID, entitlements and APP_STORE flag"
```

---

### Task 9: App Store scheme

**Files:**
- Modify: `project.yml`
- Create (generated): `MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio (App Store).xcscheme`

**Interfaces:**
- **Produces:** the scheme `MLXBits Image Studio (App Store)`. Run uses `Debug-AppStore`, Archive uses `Release-AppStore`, and it has no testables. Task 11's CI job and milestone 3's `appstore.yml` consume it.

- [ ] **Step 1: Add the scheme**

In `project.yml` under `schemes:`, after the existing scheme, add:

```yaml
  # The App Store flavor. Choosing this scheme is choosing the flavor; tests
  # run under the main scheme only.
  MLXBits Image Studio (App Store):
    build:
      targets:
        MLXBits Image Studio: all
    run:
      config: Debug-AppStore
    analyze:
      config: Debug-AppStore
    profile:
      config: Release-AppStore
    archive:
      config: Release-AppStore
```

- [ ] **Step 2: Generate, restore the DMG scheme, and inspect the new one**

```bash
xcodegen generate
git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
grep -oE 'buildConfiguration = "[^"]+"' "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio (App Store).xcscheme" | sort | uniq -c
xcodebuild -project "MLXBits Image Studio.xcodeproj" -list | sed -n '/Schemes:/,$p'
```

Expected:
- The new scheme lists `Debug-AppStore` (launch, analyze) and `Release-AppStore` (profile, archive). Its test action may show `Debug`, which is harmless because it has no testables.
- `-list` shows both schemes.

- [ ] **Step 3: Commit**

```bash
git add project.yml "MLXBits Image Studio.xcodeproj/project.pbxproj" \
  "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio (App Store).xcscheme"
git commit -m "build: App Store scheme"
```

---

### Task 10: Embed and sign the runtime

**Files:**
- Create: `scripts/sign-python-runtime.sh`, `scripts/embed-python-runtime.sh`, `Resources/PythonRuntime-Sandboxed.entitlements`
- Modify: `project.yml` (post-build phase)
- Create locally, never committed: `Config/Local.xcconfig`

**Interfaces:**
- **Consumes:**
  - `build/python-runtime/{python,cache-key}` (Task 6)
  - `runtime_tools.py macho` (Task 3)
  - `BUNDLE_PYTHON_RUNTIME`, `PYTHON_RUNTIME_SANDBOXED` (Task 8)
  - Xcode's `EXPANDED_CODE_SIGN_IDENTITY`, `CODE_SIGNING_ALLOWED`, `CONFIGURATION`, `OBJROOT`, `TARGET_BUILD_DIR`, `UNLOCALIZED_RESOURCES_FOLDER_PATH`, `SRCROOT`
- **Produces:**
  - `sign-python-runtime.sh <dir> <identity> <plain|sandboxed> <configuration>`
  - the runtime at `<App>.app/Contents/Resources/python` in App Store builds

- [ ] **Step 1: Write the child entitlements and the sign script**

`Resources/PythonRuntime-Sandboxed.entitlements`. These are exactly the two keys a helper executable of a sandboxed app may carry:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.inherit</key>
	<true/>
</dict>
</plist>
```

`scripts/sign-python-runtime.sh`:

```bash
#!/bin/bash
# Signs every Mach-O file in a copy of the bundled Python runtime.
#
#   sign-python-runtime.sh <runtime-dir> <identity> <plain|sandboxed> <configuration>
#
#   identity       codesign identity (SHA-1 or name); "-" signs ad-hoc
#   flavor         sandboxed: executables get the sandbox-inherit pair (App Store
#                  build). plain: no entitlements (DMG build), because the inherit
#                  pair crashes a child of an unsandboxed app.
#   configuration  Release* gets a secure timestamp (notarization requires one)
#
# Ad-hoc signatures skip the hardened runtime: library validation rejects
# ad-hoc-signed libraries under it, and Python could not load its own modules.
# Plain strings instead of arrays throughout: macOS bash 3.2 with set -u aborts
# on an empty "${array[@]}".
set -euo pipefail

DIR="$1"; IDENTITY="$2"; FLAVOR="$3"; CONFIGURATION="$4"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(sed -n 's/^version=//p' "$ROOT/Runtime/python.lock")
# The unsigned build output is runnable here; the copy being signed may not be.
SCANNER="$ROOT/build/python-runtime/python/bin/python${VERSION%.*}"
ENTITLEMENTS="$ROOT/Resources/PythonRuntime-Sandboxed.entitlements"

case "$FLAVOR" in
  sandboxed|plain) ;;
  *) echo "error: flavor must be 'plain' or 'sandboxed', got '$FLAVOR'" >&2; exit 2 ;;
esac

# Word-split on purpose below: flags only, never paths.
OPTS="--force --sign $IDENTITY"
if [ "$IDENTITY" != "-" ]; then OPTS="$OPTS --options runtime"; fi
if [ "$IDENTITY" != "-" ] && [[ "$CONFIGURATION" == Release* ]]; then
  OPTS="$OPTS --timestamp"
else
  OPTS="$OPTS --timestamp=none"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
"$SCANNER" "$ROOT/scripts/runtime_tools.py" macho "$DIR" >"$WORK/list"

# Libraries: 8 codesign processes at a time. xargs exits non-zero if any
# signing fails; codesign's chatter ("replacing existing signature") goes to a
# log that is shown only on failure.
if ! grep $'^lib\t' "$WORK/list" | cut -f2- | tr '\n' '\0' \
    | xargs -0 -n 16 -P 8 codesign $OPTS >"$WORK/libs.log" 2>&1; then
  grep -v "replacing existing signature" "$WORK/libs.log" >&2 || true
  echo "error: signing the runtime's libraries failed" >&2
  exit 1
fi

# Executables (python3.14, torch_shm_manager), after the libraries they load.
grep $'^exe\t' "$WORK/list" | cut -f2- >"$WORK/exes"
while IFS= read -r exe; do
  if [ "$FLAVOR" = sandboxed ]; then
    codesign $OPTS --entitlements "$ENTITLEMENTS" "$exe" 2>"$WORK/exe.log" || { cat "$WORK/exe.log" >&2; exit 1; }
  else
    codesign $OPTS "$exe" 2>"$WORK/exe.log" || { cat "$WORK/exe.log" >&2; exit 1; }
  fi
done <"$WORK/exes"

echo "Signed $(grep -c . "$WORK/list") Mach-O files ($FLAVOR, identity ${IDENTITY:0:8})"
```

The executable loop reads from a file, not a pipe, so its `exit 1` ends the script itself and not a pipeline subshell.

- [ ] **Step 2: Write the embed script**

`scripts/embed-python-runtime.sh`:

```bash
#!/bin/bash
# Xcode post-build phase: puts the bundled Python runtime into the app.
#
# Builds the runtime if needed (no-op when cached), signs a copy once per
# (runtime, flavor, identity, signing inputs) under OBJROOT, then rsyncs that
# copy into Contents/Resources/python. Later builds only rsync, which skips
# unchanged files. Signed copies of older runtimes are deleted.
set -euo pipefail

if [ "${BUNDLE_PYTHON_RUNTIME:-NO}" != "YES" ]; then
  echo "Python runtime: not bundled in $CONFIGURATION"
  exit 0
fi

"$SRCROOT/scripts/build-python-runtime.sh"
RUNTIME="$SRCROOT/build/python-runtime"
KEY=$(cat "$RUNTIME/cache-key")

FLAVOR=plain
if [ "${PYTHON_RUNTIME_SANDBOXED:-NO}" = "YES" ]; then FLAVOR=sandboxed; fi
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then IDENTITY=""; fi
SIGN_INPUTS=$(cat "$SRCROOT/scripts/sign-python-runtime.sh" "$SRCROOT/Resources/PythonRuntime-Sandboxed.entitlements" \
  | shasum -a 256 | cut -c1-8)

STAGES="$OBJROOT/PythonRuntimeSigned"
STAGE="$STAGES/$KEY-$FLAVOR-${IDENTITY:-unsigned}-$SIGN_INPUTS"
mkdir -p "$STAGES"
for old in "$STAGES"/*; do
  [ -e "$old" ] || continue
  case "$(basename "$old")" in
    "$KEY"-*) ;;          # current runtime: keep every flavor/identity
    *) rm -rf "$old" ;;   # an older runtime
  esac
done

if [ ! -f "$STAGE/.complete" ]; then
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  ditto "$RUNTIME/python" "$STAGE/python"
  if [ -n "$IDENTITY" ]; then
    "$SRCROOT/scripts/sign-python-runtime.sh" "$STAGE/python" "$IDENTITY" "$FLAVOR" "$CONFIGURATION"
  fi
  touch "$STAGE/.complete"  # last: a killed signing pass is redone next build
fi

DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/python"
mkdir -p "$DEST"
rsync -a --delete "$STAGE/python/" "$DEST/"
echo "Python runtime embedded ($KEY, $FLAVOR, ${IDENTITY:-unsigned})"
```

- [ ] **Step 3: Add the build phase**

In `project.yml`, in the app target after the `preBuildScripts:` list, add:

```yaml
    # Runs after resources are copied and before Xcode signs the app, so the
    # runtime is sealed into the app's signature. No-op unless
    # BUNDLE_PYTHON_RUNTIME=YES.
    postBuildScripts:
      - name: Embed Python runtime
        script: |
          "${SRCROOT}/scripts/embed-python-runtime.sh"
        basedOnDependencyAnalysis: false
```

Then:

```bash
chmod +x scripts/sign-python-runtime.sh scripts/embed-python-runtime.sh
xcodegen generate
git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
```

- [ ] **Step 4: Create the local team config and build the App Store flavor**

```bash
printf 'DEVELOPMENT_TEAM = 39TQC8LANW\n' > Config/Local.xcconfig   # never committed (.gitignore)
git status --short Config/   # expected: no Local.xcconfig line
time xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore build 2>&1 | grep -E "Python runtime|Signed .* Mach-O|BUILD (SUCCEEDED|FAILED)"
# Save the paths the later steps need (each step may run in a fresh shell).
SETTINGS=$(xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore -showBuildSettings 2>/dev/null)
{
  printf 'APP=%q\n' "$(echo "$SETTINGS" | sed -n 's/^ *CODESIGNING_FOLDER_PATH = //p' | head -1)"
  printf 'STAGE_DIR=%q\n' "$(echo "$SETTINGS" | sed -n 's/^ *OBJROOT = //p' | head -1)/PythonRuntimeSigned"
} > build/appstore-paths.env
cat build/appstore-paths.env
```

Expected:
- The build output includes `Python runtime up to date`, `Signed ~190 Mach-O files (sandboxed, identity …)`, `Python runtime embedded (…, sandboxed, …)` and `** BUILD SUCCEEDED **`.
- `APP` ends in `MLXBits Image Studio.app`.
- `STAGE_DIR` ends in `PythonRuntimeSigned`.

- [ ] **Step 5: Verify the signatures and entitlements**

```bash
source build/appstore-paths.env
codesign --verify --deep --strict "$APP" && echo "VERIFY OK"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -oE "com\.apple\.security\.[a-z.-]+" | sort | tr '\n' ' '; echo
codesign -d --entitlements - "$APP/Contents/Resources/python/bin/python3.14" 2>/dev/null | grep -oE "com\.apple\.security\.[a-z.-]+" | sort | tr '\n' ' '; echo
codesign -dv "$APP/Contents/Resources/python/lib/libpython3.14.dylib" 2>&1 | grep -E "TeamIdentifier|flags"
```

Expected:
- `VERIFY OK`
- The app has the five App Store entitlements.
- `python3.14` has exactly `com.apple.security.app-sandbox com.apple.security.inherit`.
- `libpython3.14.dylib` shows `TeamIdentifier=39TQC8LANW` and flags including `runtime`.

Then pin Review Focus 4: under macOS's bash 3.2, the plain flavor (no entitlements) must still sign cleanly.

```bash
T=$(mktemp -d)
ditto build/python-runtime/python "$T/python"
/bin/bash scripts/sign-python-runtime.sh "$T/python" "$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')" plain Debug
codesign -d --entitlements - "$T/python/bin/python3.14" 2>/dev/null | grep -c "com.apple.security" || true
rm -rf "$T"
```

Expected: `Signed … (plain, …)` and an entitlement count of `0`.

- [ ] **Step 6: Verify an ad-hoc plain copy still runs Python** (Review Focus 5)

```bash
T=$(mktemp -d)
ditto build/python-runtime/python "$T/python"
/bin/bash scripts/sign-python-runtime.sh "$T/python" - plain Debug
"$T/python/bin/python3.14" -c "import mlx.core, mflux; print('ad-hoc runtime OK')"
rm -rf "$T"
```

Expected: `ad-hoc runtime OK`.

- [ ] **Step 7: Verify a killed signing pass is redone** (Review Focus 2)

```bash
source build/appstore-paths.env
ls "$STAGE_DIR"
rm "$STAGE_DIR"/*/.complete
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore build 2>&1 | grep -E "Signed .* Mach-O|BUILD"
```

Expected: one stage folder before. After the build, `Signed … Mach-O files` reappears (it was re-signed) and `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Verify a runtime change replaces the embedded copy and prunes the old one** (Review Focus 3)

```bash
source build/appstore-paths.env
echo "# probe $(date +%s)" >> Runtime/tools.txt      # changes the cache key
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore build 2>&1 | grep -E "Building Python runtime|Signed|embedded|BUILD"
ls "$STAGE_DIR" | wc -l
git checkout -- Runtime/tools.txt
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore build -quiet && ls "$STAGE_DIR" | wc -l
```

Expected:
- The first build prints `Building Python runtime (<new key>)`, a fresh signing pass and `** BUILD SUCCEEDED **`, and the stage count is `1`: the old key's stage was deleted.
- After `tools.txt` is restored, the second build goes back to the original key (one more rebuild), and the count is still `1`.

- [ ] **Step 9: Verify an unchanged rebuild is fast**

```bash
time xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore build 2>&1 | grep -E "Python runtime|Signed|BUILD"
```

Expected: `Python runtime up to date`, `Python runtime embedded`, no `Signed` line, and `** BUILD SUCCEEDED **`. The embed phase adds only seconds, since it's an rsync of unchanged files.

- [ ] **Step 10: Launch the App Store build once**

This flavor has its own sandbox container, so it can't touch real data.

```bash
source build/appstore-paths.env
open -n "$APP"; sleep 8
ls -d ~/Library/Containers/com.mlxbits.image-studio.appstore && echo "sandbox container created"
osascript -e 'quit app id "com.mlxbits.image-studio.appstore"'
```

Expected: `sandbox container created`. The app window opens; the App Store flavor doesn't use the runtime yet (milestone 4), so its first-run screens behave as today, inside the sandbox.

- [ ] **Step 11: Commit**

```bash
git add scripts/sign-python-runtime.sh scripts/embed-python-runtime.sh Resources/PythonRuntime-Sandboxed.entitlements \
  project.yml "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "build: embed and sign the Python runtime in App Store builds"
```

---

### Task 11: CI compile job and docs

**Files:**
- Modify: `.github/workflows/ci.yml`, `README.md`, `AGENTS.md`

- [ ] **Step 1: Add the App Store compile job to `ci.yml`**

After the `test:` job, add:

```yaml
  appstore-build:
    name: App Store build (compile only)
    # Compiles the APP_STORE code paths so a broken #if fails the PR. No
    # signing (runners carry no identity) and no Python runtime (runtime.yml
    # builds and checks it when its inputs change).
    needs: lint
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7

      - name: Install SwiftLint
        run: brew install --quiet swiftlint

      - name: Build (Debug-AppStore)
        run: |
          set -o pipefail
          xcodebuild build \
            -project "$PROJECT" \
            -scheme "MLXBits Image Studio (App Store)" \
            -configuration Debug-AppStore \
            -destination "platform=macOS" \
            CODE_SIGNING_ALLOWED=NO \
            BUNDLE_PYTHON_RUNTIME=NO
```

In the `test:` job's `xcodebuild test` command, add a line after `CODE_SIGNING_ALLOWED=NO \`:

```yaml
            BUNDLE_PYTHON_RUNTIME=NO \
```

This is a no-op today, since the DMG configurations default to `NO`. It keeps the test job fast once milestone 4 turns DMG bundling on.

- [ ] **Step 2: Reproduce the CI compile job locally**

Without a team, as on CI:

```bash
xcodebuild build -project "MLXBits Image Studio.xcodeproj" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO BUNDLE_PYTHON_RUNTIME=NO \
  DEVELOPMENT_TEAM= -quiet && echo "COMPILE OK"
```

Expected: `COMPILE OK`. If xcodebuild still demands a signing identity, append `CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO` to both this command and the CI job, then re-run.

- [ ] **Step 3: Document it**

In `README.md`, under `## Building from source`, after the existing build instructions, add:

```markdown
### Python runtime and the App Store flavor

The App Store build bundles its own Python with mflux and every dependency,
pinned in `Runtime/`. `scripts/build-python-runtime.sh` builds it into
`build/python-runtime/` (it needs `uv`: `brew install uv`), and the
"Embed Python runtime" build phase runs it automatically when needed.

To build the App Store flavor locally, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and set your Team ID, then build the
**MLXBits Image Studio (App Store)** scheme. It runs sandboxed in its own
container (`~/Library/Containers/com.mlxbits.image-studio.appstore`), so it
never touches the DMG app's data.

To change a Python package version, edit `Runtime/requirements.in` and run
`scripts/lock-python-runtime.sh`. The runtime build refuses GPL-family
packages; a package without license metadata must be checked by hand and
recorded in `Runtime/license-overrides.json`.
```

In `AGENTS.md`, in the commands block near `xcodegen generate`, add:

```
scripts/build-python-runtime.sh          # bundled Python runtime → build/python-runtime/ (cached)
python3 -m unittest discover -s scripts/tests   # runtime build-script tests
```

Under "Do not search these", add:

```
- `build/python-runtime/` — the bundled Python runtime (~1.3 GB)
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml README.md AGENTS.md
git commit -m "ci: compile the App Store flavor on every PR; document the runtime"
```

---

### Task 12: Full verification and PR

- [ ] **Step 1: Lint gates**

```bash
swiftformat --lint --config .swiftformat .
swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict
```

Expected: both exit 0. No Swift changed, so there should be no new findings.

- [ ] **Step 2: Unit tests (Python)**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: 23 tests, all PASS.

- [ ] **Step 3: Swift test suite (DMG flavor)**

Run: `xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio" test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` with the same test count as `main` (249 at v0.15.0). The TestHost guard keeps the run off real data.

- [ ] **Step 4: Confirm nothing untracked or secret is staged**

```bash
git status --short
git log --oneline main..HEAD
git log main..HEAD --format=%B | grep -ciE "co-authored|generated with|claude" || true
```

Expected:
- a clean tree; `Config/Local.xcconfig` doesn't appear because it's ignored
- the docs commits plus about 11 task commits
- an attribution count of `0`

- [ ] **Step 5: Push and open the PR** (ask the user first; pushing is outward-facing)

```bash
git push -u origin feature/app-store-runtime
gh pr create --base main --title "build: bundled Python runtime and App Store build configuration" --body "$(cat <<'EOF'
Milestones 1–2 of the App Store build (docs/specs/2026-10-03-app-store-build-design.md, plan in docs/plans/).

- `Runtime/`: pinned standalone CPython 3.14.7 and a hashed package lock (mflux 0.21.0, mlx-lm, mlx-vlm, transformers 5.12), with opencv removed because its FFmpeg/x264 build is GPL.
- `scripts/build-python-runtime.sh`: builds, trims and precompiles the runtime, runs the license guard, writes acknowledgements and a manifest, and smoke-tests all 11 tools the app runs.
- `Resources/run_tool.py`: runs a bundled tool by name, so the app never depends on launcher scripts with absolute paths.
- New `Debug-AppStore` / `Release-AppStore` configurations and an "(App Store)" scheme: separate bundle ID, sandbox entitlements, `APP_STORE` flag. A build phase embeds and signs the runtime (sandbox-inherit entitlements on its executables).
- CI: runtime workflow (when its inputs change) and a compile-only App Store job.

The DMG build is unchanged: its configurations don't bundle the runtime until milestone 4.
EOF
)"
```

Expected: the PR URL. Then watch the checks with `gh pr checks --watch`: Format & lint, Test, Duplication, App Store build, and Runtime all pass. If the Runtime job fails on `import mlx.core` because the runner has no Metal device, apply the Task 7 note.
