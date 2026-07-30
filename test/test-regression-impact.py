#!/usr/bin/env python3
"""Require regression evidence whenever runtime-critical files change."""

from __future__ import annotations

import argparse
import fnmatch
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "test" / "regression-impact.json"


def matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def load_config() -> dict:
    document = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 1:
        raise ValueError("regression impact schemaVersion must be 1")
    if not document.get("areas"):
        raise ValueError("regression impact config has no ownership areas")
    return document


def git_changed_paths(base: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=ACMR", f"{base}...HEAD"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git diff failed for base {base}")
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def runtime_candidates(config: dict) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git ls-files failed")
    repository_files = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    candidates = {
        path for path in repository_files
        if matches(path, config["runtimeCandidates"])
    }
    ignored = config.get("ignoredRuntimeCandidates", [])
    return sorted(path for path in candidates if not matches(path, ignored))


def audit_ownership(config: dict) -> list[str]:
    area_patterns = [pattern for area in config["areas"] for pattern in area["runtime"]]
    return [path for path in runtime_candidates(config) if not matches(path, area_patterns)]


def impacted_areas(config: dict, changed: list[str]) -> list[dict]:
    return [
        area
        for area in config["areas"]
        if any(matches(path, area["runtime"]) for path in changed)
    ]


def missing_evidence(areas: list[dict], changed: list[str]) -> list[dict]:
    return [
        area
        for area in areas
        if not any(matches(path, area["evidence"]) for path in changed)
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--base", help="Git revision compared with HEAD")
    source.add_argument("--paths", nargs="*", help="Explicit changed paths for tests")
    parser.add_argument("--audit-only", action="store_true", help="Check ownership without diff evidence")
    args = parser.parse_args()

    try:
        config = load_config()
        uncovered = audit_ownership(config)
        if uncovered:
            print("not ok - runtime files missing regression ownership:")
            for path in uncovered:
                print(f"  {path}")
            return 1

        if args.audit_only:
            print(f"regression impact: {len(runtime_candidates(config))} runtime files owned across {len(config['areas'])} areas")
            return 0

        changed = args.paths if args.paths is not None else git_changed_paths(args.base or "HEAD^")
        areas = impacted_areas(config, changed)
        missing = missing_evidence(areas, changed)
        if missing:
            print("not ok - runtime changes lack matching regression evidence:")
            for area in missing:
                touched = sorted(path for path in changed if matches(path, area["runtime"]))
                print(f"  {area['name']}: {', '.join(touched)}")
                print(f"    add/update one of: {', '.join(area['evidence'])}")
            return 1

        names = ", ".join(area["name"] for area in areas) or "none"
        print(f"regression impact: {len(changed)} changed paths; covered areas: {names}")
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"not ok - regression impact audit failed: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
