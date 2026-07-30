#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "test" / "installed-state-snapshot.py"
POLICY = ROOT / "test" / "installed-state-policy.json"


class InstalledStatePreservationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.defaults = self.root / "defaults.json"
        self.before = self.root / "before.json"
        self.after = self.root / "after.json"
        self.write_defaults({
            "defaultProvider": "codex",
            "dictationEnabled": True,
            "lastAutoUpdateCheckAt": 100,
            "lastSettingsTab": "shortcuts",
        })
        self.write_artifact(".claude/state/command-hotkeys.json", "hotkeys-v1")
        self.write_artifact(".claude/state/cliphistory/index.json", "history-v1")

    def tearDown(self):
        self.temporary.cleanup()

    def write_defaults(self, value):
        self.defaults.write_text(json.dumps(value), encoding="utf-8")

    def write_artifact(self, relative, value):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")

    def capture(self, output):
        return subprocess.run(
            [
                "python3", str(SCRIPT), "--policy", str(POLICY), "capture",
                "--output", str(output), "--home", str(self.home),
                "--defaults-json", str(self.defaults),
            ],
            text=True,
            capture_output=True,
        )

    def compare(self):
        return subprocess.run(
            [
                "python3", str(SCRIPT), "compare",
                "--before", str(self.before), "--after", str(self.after),
            ],
            text=True,
            capture_output=True,
        )

    def capture_pair(self):
        self.assertEqual(self.capture(self.before).returncode, 0)
        self.assertEqual(self.capture(self.after).returncode, 0)

    def test_identical_state_is_deterministic_and_passes(self):
        self.capture_pair()
        self.assertEqual(self.before.read_bytes(), self.after.read_bytes())
        self.assertEqual(os.stat(self.before).st_mode & 0o777, 0o600)
        result = self.compare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("durable state preserved", result.stdout)

    def test_changed_preference_fails_without_printing_value(self):
        self.assertEqual(self.capture(self.before).returncode, 0)
        self.write_defaults({"defaultProvider": "claude", "dictationEnabled": True})
        self.assertEqual(self.capture(self.after).returncode, 0)
        result = self.compare()
        self.assertEqual(result.returncode, 1)
        self.assertIn("preference changed: defaultProvider", result.stderr)
        self.assertNotIn("claude", result.stderr)

    def test_removed_preference_fails(self):
        self.assertEqual(self.capture(self.before).returncode, 0)
        self.write_defaults({"defaultProvider": "codex"})
        self.assertEqual(self.capture(self.after).returncode, 0)
        result = self.compare()
        self.assertEqual(result.returncode, 1)
        self.assertIn("preference removed: dictationEnabled", result.stderr)

    def test_changed_file_fails(self):
        self.assertEqual(self.capture(self.before).returncode, 0)
        self.write_artifact(".claude/state/command-hotkeys.json", "hotkeys-v2")
        self.assertEqual(self.capture(self.after).returncode, 0)
        result = self.compare()
        self.assertEqual(result.returncode, 1)
        self.assertIn("artifact changed: .claude/state/command-hotkeys.json", result.stderr)

    def test_json_key_order_and_whitespace_do_not_change_state(self):
        self.write_artifact(
            ".claude/state/command-hotkeys.json",
            '{"shortcuts":[{"mods":0,"keycode":100}],"version":2}',
        )
        self.assertEqual(self.capture(self.before).returncode, 0)
        self.write_artifact(
            ".claude/state/command-hotkeys.json",
            '{\n  "version": 2,\n  "shortcuts": [{"keycode": 100, "mods": 0}]\n}\n',
        )
        self.assertEqual(self.capture(self.after).returncode, 0)
        result = self.compare()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_removed_history_directory_fails(self):
        self.assertEqual(self.capture(self.before).returncode, 0)
        (self.home / ".claude/state/cliphistory/index.json").unlink()
        (self.home / ".claude/state/cliphistory").rmdir()
        self.assertEqual(self.capture(self.after).returncode, 0)
        result = self.compare()
        self.assertEqual(result.returncode, 1)
        self.assertIn("artifact changed: .claude/state/cliphistory", result.stderr)

    def test_added_history_item_fails(self):
        self.assertEqual(self.capture(self.before).returncode, 0)
        self.write_artifact(".claude/state/cliphistory/new.txt", "new clipboard item")
        self.assertEqual(self.capture(self.after).returncode, 0)
        result = self.compare()
        self.assertEqual(result.returncode, 1)
        self.assertIn("artifact changed: .claude/state/cliphistory", result.stderr)

    def test_operational_defaults_are_ignored(self):
        self.assertEqual(self.capture(self.before).returncode, 0)
        self.write_defaults({
            "defaultProvider": "codex",
            "dictationEnabled": True,
            "lastAutoUpdateCheckAt": 200,
            "lastSettingsTab": "about",
            "postOnboardingOpenShortcuts": False,
            "commandRestartTestSentinel123": "temporary",
            "NSWindow Frame Command Settings": "frame",
        })
        self.assertEqual(self.capture(self.after).returncode, 0)
        result = self.compare()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_policy_covers_all_owned_configuration_and_history(self):
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        artifacts = set(policy["artifacts"])
        self.assertIn(".claude/state/command-hotkeys.json", artifacts)
        self.assertIn(".claude/state/custom-actions.json", artifacts)
        self.assertIn(".claude/state/built-in-compose.json", artifacts)
        self.assertIn(".claude/state/command-templates.json", artifacts)
        self.assertIn(".claude/state/enrichment-rules.json", artifacts)
        self.assertIn(".claude/state/command-config.json", artifacts)
        self.assertIn(".claude/state/cliphistory", artifacts)
        self.assertIn("Library/Application Support/DictationLab/vocabulary.json", artifacts)
        self.assertIn("Library/Application Support/DictationLab/history.json", artifacts)
        self.assertIn("Library/Application Support/claude-command/settings.json", artifacts)
        self.assertIn("Library/Application Support/claude-command/command-history", artifacts)


if __name__ == "__main__":
    unittest.main()
