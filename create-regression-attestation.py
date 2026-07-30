#!/usr/bin/env python3
"""Create commit-bound proof that full local regression suite passed."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


SCHEMA_VERSION = 1
SUITE = "command-full-regression-v1"
REQUIRED_GATES = [
    "regression-impact",
    "regression-contracts",
    "swift",
    "clipboard-watcher",
    "node",
    "assistant-contract",
    "shell",
    "build-transaction",
    "release-transaction",
    "install-state",
    "uninstall",
    "updater-swap",
    "restart",
    "release-policy",
    "qualification-orchestration",
    "qualification-report",
    "regression-attestation",
    "static-analysis",
    "docs",
    "pages",
    "string-review",
    "dictation-model",
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


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=root)
    parser.add_argument("--version-file", type=Path, default=root / "VERSION")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--now", help="Fixed ISO-8601 timestamp for deterministic tests")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    repo = args.repo.resolve()
    if git_value(repo, "status", "--porcelain"):
        fail("working tree must be clean before regression attestation")
    commit = git_value(repo, "rev-parse", "HEAD")
    branch = git_value(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if len(commit) != 40 or any(character not in "0123456789abcdef" for character in commit):
        fail("git commit must be a full lowercase SHA-1")
    if not branch or branch == "HEAD":
        fail("regression attestation requires a named branch")
    if not args.version_file.is_file():
        fail(f"version file missing at {args.version_file}")
    version = args.version_file.read_text(encoding="utf-8").strip()
    if not version:
        fail("version cannot be empty")
    generated_at = args.now or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    try:
        parsed = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
    except ValueError:
        fail("--now must be a valid ISO-8601 timestamp")
    if parsed.tzinfo is None:
        fail("--now must include timezone")

    document = {
        "schemaVersion": SCHEMA_VERSION,
        "result": "passed",
        "suite": SUITE,
        "commit": commit,
        "branch": branch,
        "version": version,
        "generatedAt": generated_at,
        "requiredGates": REQUIRED_GATES,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{args.output.name}.", dir=args.output.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"regression attestation created: {args.output}")
    print(f"  commit: {commit}")
    print(f"  gates: {len(REQUIRED_GATES)}")


if __name__ == "__main__":
    main()
