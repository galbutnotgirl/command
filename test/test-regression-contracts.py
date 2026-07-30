#!/usr/bin/env python3
"""Verify critical feature contracts point at release-executed evidence."""

from __future__ import annotations

import fnmatch
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "test" / "regression-contracts.json"
IMPACT_CONFIG = ROOT / "test" / "regression-impact.json"


def fail(message: str) -> None:
    print(f"not ok - {message}")


def release_executes_evidence(relative: str, release_source: str) -> bool:
    if fnmatch.fnmatchcase(relative, "agent/Tests/**/*.swift"):
        return "swift test" in release_source
    if (fnmatch.fnmatchcase(relative, "vendor/claude-command-capture/test/*.js") or
            fnmatch.fnmatchcase(relative, "vendor/claude-command-capture/test/**/*.js")):
        return "node --test" in release_source
    if relative.startswith("test/test-") and relative.endswith(".sh"):
        return f'/test/{Path(relative).name}' in release_source
    if relative == "test/test-regression-contracts.py":
        return "/test/test-regression-contracts.py" in release_source
    return False


def validate_contracts(document: dict, impact: dict, root: Path = ROOT) -> tuple[list[str], int]:
    failures: list[str] = []
    if not isinstance(document, dict):
        return ["regression manifest must be an object"], 0
    if not isinstance(impact, dict):
        return ["regression impact configuration must be an object"], 0
    raw_regressions = document.get("regressions", [])
    if not isinstance(raw_regressions, list):
        failures.append("regressions must be a list")
        raw_regressions = []
    regressions = [entry for entry in raw_regressions if isinstance(entry, dict)]
    if len(regressions) != len(raw_regressions):
        failures.append("every regression must be an object")
    ids = [entry.get("id", "") for entry in regressions]

    raw_impact_areas = impact.get("areas", [])
    if not isinstance(raw_impact_areas, list):
        failures.append("regression impact areas must be a list")
        raw_impact_areas = []
    impact_by_name = {
        entry.get("name", ""): entry
        for entry in raw_impact_areas
        if isinstance(entry, dict) and isinstance(entry.get("name"), str)
    }
    impact_areas = set(impact_by_name)
    requirements = document.get("coverageRequirements", {})
    if not isinstance(requirements, dict):
        failures.append("coverageRequirements must be an object")
        requirements = {}
    required_areas = set(requirements)
    if document.get("schemaVersion") != 2:
        failures.append("schemaVersion must be 2")
    if impact.get("schemaVersion") != 1 or not impact_areas or "" in impact_areas:
        failures.append("regression impact areas are missing or invalid")
    for area in sorted(impact_areas - required_areas):
        failures.append(f"missing feature area coverage requirement: {area}")
    for area in sorted(required_areas - impact_areas):
        failures.append(f"unknown feature area coverage requirement: {area}")
    for area, minimum in requirements.items():
        if not isinstance(minimum, int) or isinstance(minimum, bool) or minimum < 1:
            failures.append(f"invalid minimum contract count for {area}: {minimum}")
    if any(not identifier for identifier in ids) or len(ids) != len(set(ids)):
        failures.append("regression IDs must be present and unique")

    root = root.resolve()
    release_path = root / "release.sh"
    try:
        release_source = release_path.read_text(encoding="utf-8")
    except OSError:
        release_source = ""
        failures.append("release.sh is missing or unreadable")
    evidence_count = 0
    area_counts = {area: 0 for area in impact_areas}
    for regression in regressions:
        identifier = regression.get("id", "missing-id")
        if not regression.get("risk"):
            failures.append(f"{identifier}: missing risk description")
        if not regression.get("runtimeEvidence"):
            failures.append(f"{identifier}: missing runtime evidence contract")
        areas = regression.get("areas", [])
        if not isinstance(areas, list) or not areas:
            failures.append(f"{identifier}: missing feature areas")
            areas = []
        if any(not isinstance(area, str) or not area for area in areas):
            failures.append(f"{identifier}: feature areas must be non-empty strings")
            areas = [area for area in areas if isinstance(area, str) and area]
        if len(areas) != len(set(areas)):
            failures.append(f"{identifier}: duplicate feature areas")
        for area in areas:
            if area not in impact_areas:
                failures.append(f"{identifier}: unknown feature area: {area}")
            else:
                area_counts[area] += 1
        evidence = regression.get("automatedEvidence", [])
        if not isinstance(evidence, list) or len(evidence) < 2:
            failures.append(f"{identifier}: needs at least two automated evidence links")
            evidence = evidence if isinstance(evidence, list) else []
        area_evidence = {area: False for area in areas if area in impact_areas}
        for proof in evidence:
            evidence_count += 1
            if not isinstance(proof, dict):
                failures.append(f"{identifier}: automated evidence must be an object")
                continue
            relative = proof.get("file", "")
            marker = proof.get("contains", "")
            if not isinstance(relative, str) or not relative:
                failures.append(f"{identifier}: evidence file missing: {relative}")
                continue
            path = (root / relative).resolve()
            try:
                path.relative_to(root)
            except ValueError:
                failures.append(f"{identifier}: evidence path escapes repository: {relative}")
                continue
            if not relative or not path.is_file():
                failures.append(f"{identifier}: evidence file missing: {relative}")
                continue
            try:
                source = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError):
                failures.append(f"{identifier}: evidence file unreadable: {relative}")
                continue
            if not isinstance(marker, str) or not marker or marker not in source:
                failures.append(f"{identifier}: evidence marker missing from {relative}: {marker}")
            if relative and not release_executes_evidence(relative, release_source):
                failures.append(f"{identifier}: evidence is not executed by release gate: {relative}")
            for area in area_evidence:
                impact_area = impact_by_name[area]
                if any(fnmatch.fnmatchcase(relative, pattern) for pattern in impact_area.get("evidence", [])):
                    area_evidence[area] = True
        for area, covered in area_evidence.items():
            if not covered:
                failures.append(f"{identifier}: no evidence accepted by feature area: {area}")

    for area, minimum in requirements.items():
        if isinstance(minimum, int) and not isinstance(minimum, bool) and area_counts.get(area, 0) < minimum:
            failures.append(
                f"feature area {area} has {area_counts.get(area, 0)} contracts; requires {minimum}"
            )

    raw_gates = document.get("requiredGates", [])
    if not isinstance(raw_gates, list):
        failures.append("requiredGates must be a list")
        raw_gates = []
    for gate in raw_gates:
        if not isinstance(gate, dict):
            failures.append("release gate must be an object")
            continue
        relative = gate.get("file", "")
        marker = gate.get("contains", "")
        if not isinstance(relative, str) or not relative:
            failures.append(f"release gate file missing: {relative}")
            continue
        path = (root / relative).resolve()
        try:
            path.relative_to(root)
        except ValueError:
            failures.append(f"release gate path escapes repository: {relative}")
            continue
        if not relative or not path.is_file():
            failures.append(f"release gate file missing: {relative}")
            continue
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            failures.append(f"release gate file unreadable: {relative}")
            continue
        if not isinstance(marker, str) or not marker or marker not in source:
            failures.append(f"release gate marker missing from {relative}: {marker}")

    return failures, evidence_count


def main() -> int:
    try:
        document = json.loads(MANIFEST.read_text(encoding="utf-8"))
        impact = json.loads(IMPACT_CONFIG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read regression configuration: {error}")
        return 1

    failures, evidence_count = validate_contracts(document, impact)
    regressions = document.get("regressions", [])
    if failures:
        for message in failures:
            fail(message)
        print(f"regression contracts: {len(regressions)} tracked, {evidence_count} evidence links, {len(failures)} failed")
        return 1

    print(f"regression contracts: {len(regressions)} tracked, {evidence_count} evidence links, 0 failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
