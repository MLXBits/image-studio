"""Tests for scripts/runtime_tools.py. Stdlib only: python3 -m unittest discover -s scripts/tests"""

from __future__ import annotations

import hashlib
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

    # Spellings and metadata layouts found by the final review: each one slipped
    # past a guard that matched only "GPL"/"LGPL" as whole words in one field.
    def test_versioned_gpl_spellings_are_copyleft(self):
        for i, text in enumerate(("GPLv3+", "GPL2", "AGPLv3", "LGPLv2+", "GNU General Public License v3")):
            add_package(self.prefix, f"pkg{i}", license_field=text)
        verdicts = {p.name: rt.classify(p, {})[0] for p in rt.read_licenses(rt.site_packages(self.prefix))}
        self.assertEqual(set(verdicts.values()), {"copyleft"}, verdicts)

    def test_gpl_notice_after_a_copyright_line_is_copyleft(self):
        notice = ("Copyright (C) 2020 Somebody\n        This program is free software: you can redistribute it"
                  " and/or modify it under the terms of the GNU General Public License as published by the"
                  " Free Software Foundation.")
        add_package(self.prefix, "headerpkg", license_field=notice)
        self.assertEqual(self.verdict()[0], "copyleft")

    def test_gpl_free_text_beside_a_bare_classifier_is_copyleft(self):
        add_package(self.prefix, "bareclass", license_field="GPLv3", classifiers=("OSI Approved",))
        self.assertEqual(self.verdict()[0], "copyleft")

    def test_gpl_classifier_beside_a_permissive_expression_is_copyleft(self):
        add_package(self.prefix, "mixed", expression="MIT",
                    classifiers=("OSI Approved :: GNU General Public License v2 (GPLv2)",))
        self.assertEqual(self.verdict()[0], "copyleft")

    def test_gpl_compatible_wording_is_not_copyleft(self):
        add_package(self.prefix, "bsdish", license_field="BSD (GPL-compatible)",
                    classifiers=("OSI Approved :: BSD License",))
        self.assertEqual(self.verdict()[0], "ok")

    def test_override_wins_over_copyleft_metadata(self):
        # A human-verified dual license ("MIT OR GPL-2.0-only", distributed under MIT).
        add_package(self.prefix, "dualpkg", expression="MIT OR GPL-2.0-only")
        self.assertEqual(self.verdict({"dualpkg": "MIT"}), ("ok", "MIT"))


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

    def test_finds_standalone_ffmpeg_executables(self):
        # imageio-ffmpeg ships an x264-enabled ffmpeg under BSD package metadata.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "imageio_ffmpeg/binaries").mkdir(parents=True)
            for name in ("ffmpeg-macos-aarch64-v7.1", "ffprobe", "ffmpy.py"):
                (root / "imageio_ffmpeg/binaries" / name).write_bytes(b"")
            found = sorted(p.name for p in rt.forbidden_binaries(root))
            self.assertEqual(found, ["ffmpeg-macos-aarch64-v7.1", "ffprobe"])


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


if __name__ == "__main__":
    unittest.main()


def build_dylib(tmp: Path, name: str, calls: str) -> Path:
    """A tiny dylib that calls `calls` (left undefined, resolved at load time)."""
    src = tmp / f"{name}.c"
    src.write_text(f"extern void {calls}(void);\nvoid entry(void) {{ {calls}(); }}\n")
    out = tmp / f"{name}.dylib"
    subprocess.run(["clang", "-dynamiclib", "-undefined", "dynamic_lookup", "-o", str(out), str(src)], check=True)
    return out


class PrivateSymbolTests(unittest.TestCase):
    """App Review rejected 0.17.0 (354.7) for these imports (pyarrow, scipy)."""

    def test_a_binary_importing_a_listed_symbol_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            build_dylib(tmp, "bad", "sgemm")
            build_dylib(tmp, "good", "cblas_sgemm")
            problems = rt.private_symbol_uses(tmp, {"_sgemm", "_CCCryptorGCMSetIV"})
            self.assertEqual(problems, ["bad.dylib imports _sgemm"])

    def test_a_binary_nm_cannot_read_fails_the_check(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            # A Mach-O header (64-bit dylib) with nothing valid after it.
            (tmp / "broken.dylib").write_bytes(rt.MH_MAGIC_64 + bytes(8) + (6).to_bytes(4, "little") + bytes(64))
            problems = rt.private_symbol_uses(tmp, {"_sgemm"})
            self.assertEqual(len(problems), 1)
            self.assertTrue(problems[0].startswith("broken.dylib could not be scanned"), problems[0])

    def test_the_denylist_file_has_apples_list(self):
        listed = rt.load_symbols(ROOT / "Runtime" / "private-symbols.txt")
        self.assertIn("_CCCryptorGCMSetIV", listed)
        self.assertIn("_sgemm", listed)
        self.assertIn("_xerbla_array__", listed)
        self.assertEqual(len(listed), 46)
