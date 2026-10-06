#!/usr/bin/env python3
"""Build-time helpers for the Python runtime bundled into MLXBits Image Studio.

    runtime_tools.py guard <prefix> --overrides FILE
        Exit 1 if any installed package is GPL-family licensed or has no license
        metadata (and no entry in FILE), or if a GPL-family native library
        (FFmpeg, x264) is anywhere under <prefix>.

    runtime_tools.py acknowledgements <prefix> <out> --overrides FILE [--python-version V]
        Write CPython's license and every package's license texts to <out>.

    runtime_tools.py manifest <prefix> <lock> <out> --overrides FILE [--python-version V]
        Write runtime-manifest.json: Python version, lock hash, package versions and licenses.

    runtime_tools.py macho <dir>
        Print "exe<TAB>path" or "lib<TAB>path" for every Mach-O file under <dir>.

Stdlib only. The runtime build runs this with the bundled interpreter; the unit
tests run it with any python3 >= 3.10.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import struct
import subprocess
import sys
from dataclasses import dataclass
from email.parser import BytesParser
from email.policy import compat32
from pathlib import Path

# Any GPL-family spelling: GPL, GPLv3+, GPL2, AGPLv3, LGPLv2+, "GNU General Public
# License", "General Public License v3". "GPL-compatible" (a permissive license
# describing itself) is not a match.
COPYLEFT = re.compile(
    r"\b[AL]?GPL(?:v?\d[\d.+]*)?\b(?![-\s]*compatible)"
    r"|GNU (?:AFFERO |LESSER |LIBRARY )?GENERAL PUBLIC"
    r"|\bGeneral Public License\b",
    re.IGNORECASE,
)
# FFmpeg's libraries and the x264/x265 encoders, plus standalone ffmpeg/ffprobe
# executables (imageio-ffmpeg ships one built with x264). libavif (BSD) is fine.
FORBIDDEN_BINARY = re.compile(
    r"^(?:lib(?:av(?:codec|format|util|device|filter)|sw(?:scale|resample)|postproc|x264|x265)\b"
    r"|ff(?:mpeg|probe)\b)"
)
# A License field longer than this is license *text*, not a license name.
MAX_LICENSE_NAME = 80


@dataclass(frozen=True)
class PackageLicense:
    name: str
    version: str
    license: str  # best-effort license name; "" when the metadata has none
    dist_info: Path
    # Every license-bearing metadata value (expression, each License classifier,
    # the whole License field); the guard checks all of them, not just `license`.
    texts: tuple[str, ...] = ()


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
        texts = tuple(t for t in [field("License-Expression"), free_text,
                                  *(str(c) for c in msg.get_all("Classifier") or [] if str(c).startswith("License ::"))]
                      if t)
        packages.append(PackageLicense(field("Name"), field("Version"), best, meta.parent, texts))
    return packages


def classify(pkg: PackageLicense, overrides: dict[str, str]) -> tuple[str, str]:
    override = overrides.get(normalize(pkg.name))
    if override is not None:  # verified by hand; replaces everything the metadata says
        return ("copyleft" if COPYLEFT.search(override) else "ok"), override
    for text in pkg.texts:
        match = COPYLEFT.search(text)
        if match:
            return "copyleft", pkg.license if COPYLEFT.search(pkg.license) else match.group(0)
    if not pkg.license:
        return "unknown", ""
    return "ok", pkg.license


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


def load_symbols(path: Path) -> set[str]:
    """One symbol per line; blank lines and # comments ignored."""
    lines = (line.strip() for line in path.read_text().splitlines())
    return {line for line in lines if line and not line.startswith("#")}


def private_symbol_uses(root: Path, denylist: set[str]) -> list[str]:
    """Every bundled binary that imports a symbol App Review rejects."""
    problems = []
    for _, path in macho_files(root):
        result = subprocess.run(["nm", "-u", str(path)], capture_output=True, text=True)
        if result.returncode != 0:
            # An unreadable binary is a failure, never a pass: it was not checked.
            detail = result.stderr.strip().splitlines()[:1] or ["nm failed"]
            problems.append(f"{path.relative_to(root)} could not be scanned: {detail[0]}")
            continue
        for symbol in sorted(denylist.intersection(result.stdout.split())):
            problems.append(f"{path.relative_to(root)} imports {symbol}")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_guard = sub.add_parser("guard")
    p_guard.add_argument("prefix", type=Path)
    p_guard.add_argument("--overrides", type=Path, required=True)
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
    p_apis = sub.add_parser("apis")
    p_apis.add_argument("prefix", type=Path)
    p_apis.add_argument("--denylist", type=Path, required=True)
    p_macho = sub.add_parser("macho")
    p_macho.add_argument("root", type=Path)
    args = parser.parse_args(argv)

    if args.command == "guard":
        problems = guard(args.prefix, args.overrides)
        for line in problems:
            print(f"license guard: {line}", file=sys.stderr)
        return 1 if problems else 0
    if args.command == "apis":
        problems = private_symbol_uses(args.prefix, load_symbols(args.denylist))
        for line in problems:
            print(f"App Store API check: {line}", file=sys.stderr)
        return 1 if problems else 0
    if args.command == "acknowledgements":
        args.out.write_text(acknowledgements(args.prefix, args.python_version, load_overrides(args.overrides)))
        return 0
    if args.command == "manifest":
        data = manifest(args.prefix, args.lock, args.python_version, load_overrides(args.overrides))
        args.out.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        return 0
    if args.command == "macho":
        for kind, path in macho_files(args.root):
            print(f"{kind}\t{path}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
