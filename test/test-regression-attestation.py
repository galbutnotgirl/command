#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "create-regression-attestation.py"
NOW = "2026-07-30T10:00:00Z"


class RegressionAttestationGeneratorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", "-b", "main", self.repo], check=True)
        subprocess.run(["git", "-C", self.repo, "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", self.repo, "config", "user.email", "test@example.com"], check=True)
        (self.repo / "VERSION").write_text("1.2.3-test\n", encoding="utf-8")
        (self.repo / "tracked").write_text("fixture\n", encoding="utf-8")
        subprocess.run(["git", "-C", self.repo, "add", "VERSION", "tracked"], check=True)
        subprocess.run(["git", "-C", self.repo, "commit", "-qm", "fixture"], check=True)
        self.output = self.repo / "output" / "attestation.json"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_generator(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(GENERATOR),
                "--repo",
                str(self.repo),
                "--version-file",
                str(self.repo / "VERSION"),
                "--output",
                str(self.output),
                "--now",
                NOW,
                *extra,
            ],
            text=True,
            capture_output=True,
        )

    def test_creates_exact_commit_bound_attestation(self) -> None:
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(self.output.read_text(encoding="utf-8"))
        head = subprocess.check_output(
            ["git", "-C", self.repo, "rev-parse", "HEAD"], text=True
        ).strip()
        self.assertEqual(document["commit"], head)
        self.assertEqual(document["branch"], "main")
        self.assertEqual(document["version"], "1.2.3-test")
        self.assertEqual(document["result"], "passed")
        self.assertEqual(document["suite"], "command-full-regression-v1")
        self.assertEqual(len(document["requiredGates"]), 22)
        self.assertEqual(len(set(document["requiredGates"])), 22)

        swift = (ROOT / "agent/Sources/ClaudeCommandCore/RegressionAttestation.swift").read_text()
        swift_block = swift.split("requiredRegressionGateIDs = [", 1)[1].split("]", 1)[0]
        swift_gates = re.findall(r'"([a-z-]+)"', swift_block)
        self.assertEqual(swift_gates, document["requiredGates"])

        verifier = (ROOT / "verify-regression-attestation.sh").read_text()
        shell_block = verifier.split("for gate in \\\n", 1)[1].split("; do", 1)[0]
        shell_gates = shell_block.replace("\\\n", " ").split()
        self.assertEqual(shell_gates, document["requiredGates"])

    def test_rejects_dirty_tree_without_replacing_prior_output(self) -> None:
        self.output.parent.mkdir(parents=True)
        self.output.write_text("sentinel\n", encoding="utf-8")
        (self.repo / "tracked").write_text("dirty\n", encoding="utf-8")
        result = self.run_generator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("working tree must be clean", result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "sentinel\n")

    def test_rejects_detached_head(self) -> None:
        subprocess.run(["git", "-C", self.repo, "checkout", "--detach", "-q"], check=True)
        result = self.run_generator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("named branch", result.stderr)

    def test_rejects_invalid_fixed_timestamp(self) -> None:
        command = [
            "python3",
            str(GENERATOR),
            "--repo",
            str(self.repo),
            "--version-file",
            str(self.repo / "VERSION"),
            "--output",
            str(self.output),
            "--now",
            "not-a-date",
        ]
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("valid ISO-8601", result.stderr)


if __name__ == "__main__":
    unittest.main()
