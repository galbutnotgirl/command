#!/usr/bin/env python3
"""Capture and compare Command-owned durable user state."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import sys
from typing import Any


DEFAULT_POLICY = pathlib.Path(__file__).with_name("installed-state-policy.json")


def load_policy(path: pathlib.Path) -> dict[str, Any]:
    policy = json.loads(path.read_text(encoding="utf-8"))
    if policy.get("schemaVersion") != 1:
        raise ValueError("unsupported installed-state policy schema")
    required = {
        "defaultsDomain",
        "ignoredDefaultsKeys",
        "ignoredDefaultsPrefixes",
        "artifacts",
    }
    missing = sorted(required - policy.keys())
    if missing:
        raise ValueError(f"installed-state policy missing: {', '.join(missing)}")
    if len(policy["artifacts"]) != len(set(policy["artifacts"])):
        raise ValueError("installed-state policy contains duplicate artifacts")
    return policy


def normalize(value: Any) -> Any:
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, bytes):
        return {"$data": base64.b64encode(value).decode("ascii")}
    if isinstance(value, (dt.datetime, dt.date)):
        return {"$date": value.isoformat()}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        return {str(key): normalize(value[key]) for key in sorted(value, key=str)}
    return {"$description": str(value)}


def read_defaults(domain: str, defaults_json: pathlib.Path | None) -> dict[str, Any]:
    if defaults_json is not None:
        value = json.loads(defaults_json.read_text(encoding="utf-8"))
    else:
        result = subprocess.run(
            ["defaults", "export", domain, "-"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"could not export {domain} defaults: {detail}")
        value = plistlib.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError("Command defaults must be a dictionary")
    return value


def filtered_defaults(value: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    ignored = set(policy["ignoredDefaultsKeys"])
    prefixes = tuple(policy["ignoredDefaultsPrefixes"])
    return {
        key: normalize(item)
        for key, item in sorted(value.items())
        if key not in ignored and not key.startswith(prefixes)
    }


def update_file_digest(hasher: Any, relative: str, path: pathlib.Path) -> None:
    if path.is_symlink():
        hasher.update(b"link\0")
        hasher.update(relative.encode("utf-8"))
        hasher.update(b"\0")
        hasher.update(os.readlink(path).encode("utf-8"))
        hasher.update(b"\0")
        return
    hasher.update(b"file\0")
    hasher.update(relative.encode("utf-8"))
    hasher.update(b"\0")
    if path.suffix.lower() == ".json":
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            canonical = json.dumps(
                value,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            hasher.update(canonical)
            hasher.update(b"\0")
            return
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            pass
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    hasher.update(b"\0")


def artifact_snapshot(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists() and not path.is_symlink():
        return {"kind": "missing"}
    hasher = hashlib.sha256()
    if path.is_file() or path.is_symlink():
        update_file_digest(hasher, path.name, path)
        return {"kind": "file", "files": 1, "sha256": hasher.hexdigest()}
    if not path.is_dir():
        return {"kind": "other"}

    file_count = 0
    directory_count = 1
    for root, directories, files in os.walk(path, followlinks=False):
        directories.sort()
        files.sort()
        root_path = pathlib.Path(root)
        relative_root = root_path.relative_to(path).as_posix()
        hasher.update(b"dir\0")
        hasher.update(relative_root.encode("utf-8"))
        hasher.update(b"\0")
        directory_count += len(directories)
        for name in files:
            child = root_path / name
            relative = child.relative_to(path).as_posix()
            update_file_digest(hasher, relative, child)
            file_count += 1
    return {
        "kind": "directory",
        "directories": directory_count,
        "files": file_count,
        "sha256": hasher.hexdigest(),
    }


def capture(policy_path: pathlib.Path, home: pathlib.Path,
            defaults_json: pathlib.Path | None) -> dict[str, Any]:
    policy = load_policy(policy_path)
    defaults = read_defaults(policy["defaultsDomain"], defaults_json)
    policy_digest = hashlib.sha256(policy_path.read_bytes()).hexdigest()
    artifacts = {
        relative: artifact_snapshot(home / relative)
        for relative in policy["artifacts"]
    }
    return {
        "schemaVersion": 1,
        "policySha256": policy_digest,
        "preferences": filtered_defaults(defaults, policy),
        "artifacts": artifacts,
    }


def compare(before: dict[str, Any], after: dict[str, Any]) -> list[str]:
    changes: list[str] = []
    if before.get("schemaVersion") != after.get("schemaVersion"):
        changes.append("snapshot schema changed")
    if before.get("policySha256") != after.get("policySha256"):
        changes.append("durable-state policy changed")

    before_preferences = before.get("preferences", {})
    after_preferences = after.get("preferences", {})
    for key in sorted(set(before_preferences) | set(after_preferences)):
        if key not in after_preferences:
            changes.append(f"preference removed: {key}")
        elif key not in before_preferences:
            changes.append(f"preference added: {key}")
        elif before_preferences[key] != after_preferences[key]:
            changes.append(f"preference changed: {key}")

    before_artifacts = before.get("artifacts", {})
    after_artifacts = after.get("artifacts", {})
    for path in sorted(set(before_artifacts) | set(after_artifacts)):
        if path not in after_artifacts:
            changes.append(f"artifact removed from snapshot: {path}")
        elif path not in before_artifacts:
            changes.append(f"artifact added to snapshot: {path}")
        elif before_artifacts[path] != after_artifacts[path]:
            old_kind = before_artifacts[path].get("kind", "unknown")
            new_kind = after_artifacts[path].get("kind", "unknown")
            changes.append(f"artifact changed: {path} ({old_kind} -> {new_kind})")
    return changes


def load_snapshot(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"snapshot is not a dictionary: {path}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", type=pathlib.Path, default=DEFAULT_POLICY)
    subparsers = parser.add_subparsers(dest="command", required=True)

    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--output", type=pathlib.Path, required=True)
    capture_parser.add_argument("--home", type=pathlib.Path,
                                default=pathlib.Path.home())
    capture_parser.add_argument("--defaults-json", type=pathlib.Path)

    compare_parser = subparsers.add_parser("compare")
    compare_parser.add_argument("--before", type=pathlib.Path, required=True)
    compare_parser.add_argument("--after", type=pathlib.Path, required=True)

    args = parser.parse_args()
    try:
        if args.command == "capture":
            document = capture(args.policy, args.home, args.defaults_json)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.output.with_suffix(args.output.suffix + ".tmp")
            temporary.write_text(
                json.dumps(document, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            os.chmod(temporary, 0o600)
            temporary.replace(args.output)
            print(
                "installed durable state captured: "
                f"{len(document['preferences'])} preferences, "
                f"{len(document['artifacts'])} artifacts"
            )
            return 0

        changes = compare(load_snapshot(args.before), load_snapshot(args.after))
        if changes:
            print("FAIL: installed durable state changed", file=sys.stderr)
            for change in changes:
                print(f"  {change}", file=sys.stderr)
            return 1
        print("installed durable state preserved")
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"FAIL: installed durable state check: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
