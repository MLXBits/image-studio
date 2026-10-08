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

INPUTS="Runtime/python.lock Runtime/requirements.lock Runtime/license-overrides.json Runtime/private-symbols.txt Runtime/tools.txt
scripts/build-python-runtime.sh scripts/runtime_tools.py Resources/run_tool.py Resources/hf_cache_probe.py"
KEY=$(cd "$ROOT" && for f in $INPUTS; do cat "$f"; done | shasum -a 256 | cut -c1-16)

lock_value() { sed -n "s/^$1=//p" "$ROOT/Runtime/python.lock"; }
VERSION=$(lock_value version)
MINOR=${VERSION%.*}
PY="$PREFIX/bin/python$MINOR"

if [ -f "$OUT/cache-key" ] && [ "$(cat "$OUT/cache-key")" = "$KEY" ] && [ -x "$PY" ]; then
  echo "Python runtime up to date ($KEY)"
  exit 0
fi

# Xcode.app launched from the Dock runs build phases with a bare PATH, so look
# where uv is usually installed too (Homebrew, uv's own installer).
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"
command -v uv >/dev/null || {
  echo "error: uv is required to build the Python runtime (brew install uv); looked in PATH=$PATH" >&2
  exit 1
}

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
  "$STDLIB/site-packages/torch/include" "$STDLIB"/site-packages/torch/bin/protoc* \
  "$STDLIB/site-packages/pip" "$STDLIB"/site-packages/pip-*.dist-info
# pip ships with the standalone CPython. The app installs nothing at runtime, and
# an installer in the bundle runs against App Store guideline 2.5.2's intent.
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

echo "→ App Store API check"
"$PY" "$TOOLS" apis "$PREFIX" --denylist "$ROOT/Runtime/private-symbols.txt"

echo "→ Smoke test"
"$PY" -c "import mflux, mlx.core, mlx_lm, mlx_vlm, torch"
grep -vE '^[[:space:]]*(#|$)' "$ROOT/Runtime/tools.txt" | while read -r tool; do
  if ! "$PY" "$ROOT/Resources/run_tool.py" "$tool" --help >/dev/null 2>"$WORK/err"; then
    echo "error: '$tool --help' failed:" >&2
    cat "$WORK/err" >&2
    exit 1
  fi
done
# The app's "downloaded" check calls a private mflux method (#19); a bump that
# renames it must fail here, not quietly leave the app on its size heuristic.
"$PY" "$ROOT/Resources/hf_cache_probe.py" --check

echo "→ $(du -sh "$PREFIX" | cut -f1) in $PREFIX"
echo "$KEY" >"$OUT/cache-key"
