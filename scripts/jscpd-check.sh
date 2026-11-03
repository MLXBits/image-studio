#!/usr/bin/env bash
# Local pre-PR duplication check — mirrors the CI "Duplication" job so you can
# catch a jscpd regression before opening (or pushing to) a PR.
#
# Scans the working tree (head) and the PR base with jscpd, and fails if the
# duplicated-token share rises by more than MAX_RISE percentage points (0.1 by
# default, matching CI).
#
# Usage:
#   scripts/jscpd-check.sh              # base = open PR's base, else origin/main
#   scripts/jscpd-check.sh origin/main  # explicit base ref
#   MAX_RISE=0.2 scripts/jscpd-check.sh # override the limit
set -euo pipefail

MAX_RISE="${MAX_RISE:-0.1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Base ref: explicit arg, else the open PR's base sha, else origin/main.
base_ref="${1:-}"
if [ -z "$base_ref" ]; then
  base_ref="$(gh pr view --json baseRefOid --jq .baseRefOid 2>/dev/null || true)"
fi
base_ref="${base_ref:-origin/main}"

# Run jscpd in a dir and print its duplicated-token percentage.
scan() {
  local dir="$1"
  (cd "$dir" && npx --yes jscpd@4 --reporters console,json . > jscpd.txt 2>&1 || true)
  jq -r '.statistics.total.percentageTokens' "$dir/.jscpd-report/jscpd-report.json"
}

# Head = the working tree (includes uncommitted changes — what you want to check
# before pushing).
head_pct="$(scan "$REPO_ROOT")"

# Base = the base ref, extracted into a temp dir (tracked files only).
base_dir="$(mktemp -d)"
trap 'rm -rf "$base_dir"' EXIT
git archive "$base_ref" | tar -x -C "$base_dir"
base_pct="$(scan "$base_dir")"

rise="$(echo "$head_pct - $base_pct" | bc -l)"
echo "Duplicated tokens: base ${base_pct}% → head ${head_pct}% (${rise} pts; limit +${MAX_RISE})"

if [ "$(echo "$rise > $MAX_RISE" | bc -l)" = 1 ]; then
  echo ""
  echo "FAIL: duplication rose ${rise} pts, over the +${MAX_RISE} limit."
  echo ""
  echo "Clones (head):"
  tail -40 "$REPO_ROOT/jscpd.txt"
  exit 1
fi

echo "OK: within the +${MAX_RISE} limit."
