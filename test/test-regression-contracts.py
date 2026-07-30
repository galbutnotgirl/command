#!/usr/bin/env python3
"""Verify critical regression records still point at real executable evidence."""

from __future__ import annotations

import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "test" / "regression-contracts.json"


def fail(message: str) -> None:
    print(f"not ok - {message}")


def main() -> int:
    try:
        document = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read regression manifest: {error}")
        return 1

    failures: list[str] = []
    regressions = document.get("regressions", [])
    ids = [entry.get("id", "") for entry in regressions]
    if document.get("schemaVersion") != 1:
        failures.append("schemaVersion must remain 1 until a migration exists")
    if len(regressions) < 5:
        failures.append("manifest lost critical dictation regression coverage")
    if any(not identifier for identifier in ids) or len(ids) != len(set(ids)):
        failures.append("regression IDs must be present and unique")

    evidence_count = 0
    for regression in regressions:
        identifier = regression.get("id", "missing-id")
        if not regression.get("risk"):
            failures.append(f"{identifier}: missing risk description")
        if not regression.get("runtimeEvidence"):
            failures.append(f"{identifier}: missing runtime evidence contract")
        evidence = regression.get("automatedEvidence", [])
        if not evidence:
            failures.append(f"{identifier}: missing automated evidence")
        for proof in evidence:
            evidence_count += 1
            relative = proof.get("file", "")
            marker = proof.get("contains", "")
            path = ROOT / relative
            if not relative or not path.is_file():
                failures.append(f"{identifier}: evidence file missing: {relative}")
                continue
            if not marker or marker not in path.read_text(encoding="utf-8"):
                failures.append(f"{identifier}: evidence marker missing from {relative}: {marker}")

    for gate in document.get("requiredGates", []):
        relative = gate.get("file", "")
        marker = gate.get("contains", "")
        path = ROOT / relative
        if not relative or not path.is_file():
            failures.append(f"release gate file missing: {relative}")
            continue
        if not marker or marker not in path.read_text(encoding="utf-8"):
            failures.append(f"release gate marker missing from {relative}: {marker}")

    if failures:
        for message in failures:
            fail(message)
        print(f"regression contracts: {len(regressions)} tracked, {evidence_count} evidence links, {len(failures)} failed")
        return 1

    print(f"regression contracts: {len(regressions)} tracked, {evidence_count} evidence links, 0 failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
