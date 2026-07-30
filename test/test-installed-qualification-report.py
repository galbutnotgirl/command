#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "verify-installed-qualification.py"
NOW = "2026-07-30T08:00:00Z"
STEPS = [
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


class InstalledQualificationReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", "-b", "main", self.repo], check=True)
        subprocess.run(["git", "-C", self.repo, "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", self.repo, "config", "user.email", "test@example.com"], check=True)
        (self.repo / "VERSION").write_text("1.2.0-test\n", encoding="utf-8")
        (self.repo / "tracked").write_text("fixture\n", encoding="utf-8")
        subprocess.run(["git", "-C", self.repo, "add", "VERSION", "tracked"], check=True)
        subprocess.run(["git", "-C", self.repo, "commit", "-qm", "fixture"], check=True)
        self.head = subprocess.check_output(
            ["git", "-C", self.repo, "rev-parse", "HEAD"], text=True
        ).strip()
        self.report_path = self.repo / "qualification.json"
        self.report = {
            "schemaVersion": 1,
            "commit": self.head,
            "branch": "main",
            "version": "1.2.0-test",
            "startedAt": "2026-07-30T07:29:00Z",
            "completedAt": "2026-07-30T07:30:00Z",
            "result": "passed",
            "failedStep": None,
            "exitCode": 0,
            "installMode": "incremental",
            "publicReleasePublished": False,
            "steps": [
                {"name": name, "status": "passed", "durationSeconds": 1.0}
                for name in STEPS
            ],
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_verifier(self, report: dict | None = None) -> subprocess.CompletedProcess[str]:
        if report is not None:
            self.report_path.write_text(json.dumps(report), encoding="utf-8")
        return subprocess.run(
            [
                "python3",
                str(VERIFIER),
                "--repo",
                str(self.repo),
                "--report",
                str(self.report_path),
                "--version-file",
                str(self.repo / "VERSION"),
                "--now",
                NOW,
            ],
            text=True,
            capture_output=True,
        )

    def assert_rejected(self, report: dict, expected: str) -> None:
        result = self.run_verifier(report)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stderr)

    def test_accepts_exact_recent_thirteen_step_report(self) -> None:
        result = self.run_verifier(self.report)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("steps: 13/13", result.stdout)

    def test_rejects_missing_report(self) -> None:
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("report missing", result.stderr)

    def test_rejects_stale_commit(self) -> None:
        report = deepcopy(self.report)
        report["commit"] = "0" * 40
        self.assert_rejected(report, "qualification commit")

    def test_rejects_wrong_branch_or_version(self) -> None:
        report = deepcopy(self.report)
        report["branch"] = "feature"
        self.assert_rejected(report, "qualification branch")
        report = deepcopy(self.report)
        report["version"] = "0.0.0"
        self.assert_rejected(report, "qualification version")

    def test_rejects_failed_or_published_report(self) -> None:
        report = deepcopy(self.report)
        report.update(result="failed", failedStep="Restart installed app", exitCode=1)
        self.assert_rejected(report, "qualification result")
        report = deepcopy(self.report)
        report["publicReleasePublished"] = True
        self.assert_rejected(report, "publicReleasePublished")

    def test_rejects_nonincremental_install(self) -> None:
        report = deepcopy(self.report)
        report["installMode"] = "clean"
        self.assert_rejected(report, "installMode")

    def test_rejects_missing_reordered_or_failed_step(self) -> None:
        report = deepcopy(self.report)
        report["steps"].pop()
        self.assert_rejected(report, "required ordered runtime checks")
        report = deepcopy(self.report)
        report["steps"][0], report["steps"][1] = report["steps"][1], report["steps"][0]
        self.assert_rejected(report, "required ordered runtime checks")
        report = deepcopy(self.report)
        report["steps"][4]["status"] = "failed"
        self.assert_rejected(report, "step 5 did not pass")

    def test_rejects_stale_or_future_report(self) -> None:
        report = deepcopy(self.report)
        report["startedAt"] = "2026-07-28T07:29:00Z"
        report["completedAt"] = "2026-07-28T07:30:00Z"
        self.assert_rejected(report, "hours old")
        report = deepcopy(self.report)
        report["completedAt"] = "2026-07-30T08:10:00Z"
        self.assert_rejected(report, "implausibly in future")

    def test_rejects_invalid_timestamps_and_durations(self) -> None:
        report = deepcopy(self.report)
        report["startedAt"] = "not-a-date"
        self.assert_rejected(report, "not a valid ISO-8601")
        report = deepcopy(self.report)
        report["steps"][0]["durationSeconds"] = -1
        self.assert_rejected(report, "invalid duration")
        report = deepcopy(self.report)
        report["steps"][0]["durationSeconds"] = float("nan")
        self.assert_rejected(report, "invalid duration")

    def test_rejects_bool_values_that_compare_equal_to_integers(self) -> None:
        report = deepcopy(self.report)
        report["schemaVersion"] = True
        self.assert_rejected(report, "schemaVersion")
        report = deepcopy(self.report)
        report["exitCode"] = False
        self.assert_rejected(report, "exitCode")
        report = deepcopy(self.report)
        report["publicReleasePublished"] = 0
        self.assert_rejected(report, "publicReleasePublished")


if __name__ == "__main__":
    unittest.main()
