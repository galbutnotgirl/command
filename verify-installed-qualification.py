#!/usr/bin/env python3
"""Verify installed runtime qualification before public release publication."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


EXPECTED_STEPS = [
    "Full release gates and signed build",
    "Capture durable state baseline",
    "Incremental install",
    "Durable state after install",
    "Installed build identity",
    "Hotkey input before restart",
    "Microphone capture before restart",
    "Restart installed app",
    "Hotkey input after restart",
    "Microphone capture after restart",
    "Installed runtime soak",
    "Final-word model fixtures",
    "Durable state after qualification",
]


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def git_value(repo: Path, *args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(repo), *args], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        fail(f"could not read git {' '.join(args)} from {repo}")


def parse_timestamp(value: object, field: str) -> datetime:
    if not isinstance(value, str):
        fail(f"qualification {field} must be an ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"qualification {field} is not a valid ISO-8601 timestamp")
    if parsed.tzinfo is None:
        fail(f"qualification {field} must include timezone")
    return parsed.astimezone(timezone.utc)


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=root)
    parser.add_argument("--report", type=Path, default=root / "dist/installed-qualification.json")
    parser.add_argument("--version-file", type=Path, default=root / "VERSION")
    parser.add_argument("--max-age-hours", type=float, default=24.0)
    parser.add_argument("--now", help="Fixed ISO-8601 clock for deterministic tests")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not math.isfinite(args.max_age_hours) or args.max_age_hours <= 0:
        fail("max qualification age must be positive")
    if not args.report.is_file():
        fail(
            f"installed qualification report missing at {args.report}; "
            "run time ./qualify-installed-build.sh on this exact commit before publishing"
        )
    if not args.version_file.is_file():
        fail(f"version file missing at {args.version_file}")

    try:
        report = json.loads(args.report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"installed qualification report is unreadable: {error}")
    if not isinstance(report, dict):
        fail("installed qualification report root must be an object")

    head = git_value(args.repo, "rev-parse", "HEAD")
    branch = git_value(args.repo, "rev-parse", "--abbrev-ref", "HEAD")
    version = args.version_file.read_text(encoding="utf-8").strip()

    expected_values = [
        ("schemaVersion", 1, int),
        ("commit", head, str),
        ("branch", branch, str),
        ("version", version, str),
        ("result", "passed", str),
        ("failedStep", None, type(None)),
        ("exitCode", 0, int),
        ("installMode", "incremental", str),
        ("publicReleasePublished", False, bool),
    ]
    for field, expected, expected_type in expected_values:
        value = report.get(field)
        if type(value) is not expected_type or value != expected:
            fail(f"qualification {field} is {report.get(field)!r}; expected {expected!r}")

    steps = report.get("steps")
    if not isinstance(steps, list):
        fail("qualification steps must be an array")
    names = [step.get("name") if isinstance(step, dict) else None for step in steps]
    if names != EXPECTED_STEPS:
        fail("qualification steps do not match required ordered runtime checks")
    for index, step in enumerate(steps):
        if step.get("status") != "passed":
            fail(f"qualification step {index + 1} did not pass")
        duration = step.get("durationSeconds")
        if (not isinstance(duration, (int, float)) or isinstance(duration, bool)
                or not math.isfinite(duration) or duration < 0):
            fail(f"qualification step {index + 1} has invalid duration")

    started = parse_timestamp(report.get("startedAt"), "startedAt")
    completed = parse_timestamp(report.get("completedAt"), "completedAt")
    if completed < started:
        fail("qualification completedAt precedes startedAt")
    now = parse_timestamp(args.now, "--now") if args.now else datetime.now(timezone.utc)
    if completed > now + timedelta(minutes=5):
        fail("qualification completion time is implausibly in future")
    age = now - completed
    if age > timedelta(hours=args.max_age_hours):
        fail(
            f"qualification is {age.total_seconds() / 3600:.1f} hours old; "
            f"maximum is {args.max_age_hours:g} hours"
        )

    print("installed qualification report passed")
    print(f"  commit: {head}")
    print(f"  version: {version}")
    print(f"  age: {age.total_seconds() / 3600:.2f} hours")
    print(f"  steps: {len(steps)}/{len(EXPECTED_STEPS)}")


if __name__ == "__main__":
    main()
