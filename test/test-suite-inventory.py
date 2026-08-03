#!/usr/bin/env python3
"""Fail when critical test coverage disappears during routine edits."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "test" / "suite-inventory.json"
SWIFT_TESTS = ROOT / "agent" / "Tests" / "ClaudeCommandCoreTests"
NODE_TESTS = ROOT / "vendor" / "claude-command-capture" / "test"
SWIFT_PATTERN = re.compile(r"\bfunc\s+test\w+\s*\(")
NODE_PATTERN = re.compile(r"(?m)^test\(")


def validate_inventory(document: object, root: Path = ROOT) -> tuple[list[str], int, int]:
    failures: list[str] = []
    if not isinstance(document, dict):
        return ["suite inventory must be an object"], 0, 0
    if document.get("schemaVersion") != 1:
        failures.append("suite inventory schemaVersion must be 1")

    suites = document.get("swiftSuites")
    if not isinstance(suites, dict) or not suites:
        return failures + ["swiftSuites must be a non-empty object"], 0, 0

    swift_root = root / "agent" / "Tests" / "ClaudeCommandCoreTests"
    swift_total = 0
    for filename, minimum in suites.items():
        if not isinstance(filename, str) or Path(filename).name != filename:
            failures.append(f"invalid Swift suite name: {filename}")
            continue
        if not isinstance(minimum, int) or isinstance(minimum, bool) or minimum < 1:
            failures.append(f"invalid minimum for {filename}: {minimum}")
            continue
        path = swift_root / filename
        if not path.is_file():
            failures.append(f"required Swift suite is missing: {filename}")
            continue
        count = len(SWIFT_PATTERN.findall(path.read_text(encoding="utf-8")))
        swift_total += count
        if count < minimum:
            failures.append(f"{filename} has {count} tests; requires at least {minimum}")

    minimum_swift = document.get("minimumSwiftTests")
    if not isinstance(minimum_swift, int) or isinstance(minimum_swift, bool) or minimum_swift < 1:
        failures.append("minimumSwiftTests must be a positive integer")
    elif swift_total < minimum_swift:
        failures.append(f"Swift inventory has {swift_total} tests; requires at least {minimum_swift}")

    node_root = root / "vendor" / "claude-command-capture" / "test"
    node_total = sum(
        len(NODE_PATTERN.findall(path.read_text(encoding="utf-8")))
        for path in node_root.rglob("*.js")
    ) if node_root.is_dir() else 0
    minimum_node = document.get("minimumNodeTests")
    if not isinstance(minimum_node, int) or isinstance(minimum_node, bool) or minimum_node < 1:
        failures.append("minimumNodeTests must be a positive integer")
    elif node_total < minimum_node:
        failures.append(f"Node inventory has {node_total} tests; requires at least {minimum_node}")

    return failures, swift_total, node_total


def main() -> int:
    try:
        document = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"not ok - cannot read suite inventory: {error}")
        return 1

    failures, swift_total, node_total = validate_inventory(document)
    if failures:
        for failure in failures:
            print(f"not ok - {failure}")
        return 1
    print(f"suite inventory: {swift_total} Swift tests, {node_total} Node tests, no coverage loss")
    return 0


if __name__ == "__main__":
    sys.exit(main())
