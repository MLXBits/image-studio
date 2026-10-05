#!/usr/bin/env python3
"""Checks App Store Connect field lengths in docs/appstore/listing.md.

A field is a `### <Name> (max <N>)` heading followed by a fenced text block.
App Store Connect counts characters, so this does too.
"""
import pathlib
import re
import sys

HEADING = re.compile(r"^### (?P<name>.+?) \(max (?P<limit>\d+)\)\s*$", re.M)
BLOCK = re.compile(r"\A\s*```text\n(?P<body>.*?)\n```", re.S)


def check(markdown: str) -> list[str]:
    problems = []
    for match in HEADING.finditer(markdown):
        name, limit = match["name"], int(match["limit"])
        block = BLOCK.match(markdown[match.end():])
        if not block:
            problems.append(f"{name}: no text block")
            continue
        body = block["body"]
        if len(body) > limit:
            problems.append(f"{name}: {len(body)} characters, max {limit}")
        if name == "Keywords" and ", " in body:
            problems.append("Keywords: space after a comma wastes a character")
    return problems


def main() -> int:
    path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "docs/appstore/listing.md")
    problems = check(path.read_text(encoding="utf-8"))
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
