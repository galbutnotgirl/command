#!/usr/bin/env python3
"""Round-trip tests for tools/string_review.py using an isolated fixture repo."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import re
import sys
import tempfile
import unittest


TOOL = pathlib.Path(__file__).resolve().parents[1] / "tools" / "string_review.py"
SPEC = importlib.util.spec_from_file_location("command_string_review", TOOL)
assert SPEC and SPEC.loader
string_review = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = string_review
SPEC.loader.exec_module(string_review)


class StringReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        (self.root / "agent").mkdir()
        (self.root / "outputs").mkdir()
        self.source = self.root / "agent" / "Fixture.swift"
        self.source.write_text('Text("Current label")\nText("Keep this")\n', encoding="utf-8")
        self.old_root = string_review.ROOT
        self.old_review = string_review.REVIEW_PATH
        string_review.ROOT = self.root
        string_review.REVIEW_PATH = self.root / "outputs" / "STRING_REVIEW.md"

    def tearDown(self) -> None:
        string_review.ROOT = self.old_root
        string_review.REVIEW_PATH = self.old_review
        self.tmp.cleanup()

    def test_export_and_apply_round_trip(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()):
            string_review.export_review()
        review = string_review.REVIEW_PATH.read_text(encoding="utf-8")
        self.assertIn("Current label", review)
        self.assertIn("Keep this", review)

        current_block = re.compile(
            r"(Current:\n~~~text\nCurrent label\n~~~\n\nReplacement:\n~~~text\n)\n(~~~)"
        )
        edited, count = current_block.subn(r"\1Updated label\n\2", review, count=1)
        self.assertEqual(count, 1)
        string_review.REVIEW_PATH.write_text(edited, encoding="utf-8")

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            string_review.apply_review()
        self.assertIn("requested 1, applied 1, skipped 0", output.getvalue())
        self.assertEqual(
            self.source.read_text(encoding="utf-8"),
            'Text("Updated label")\nText("Keep this")\n',
        )

    def test_stale_source_is_not_guessed(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()):
            string_review.export_review()
        review = string_review.REVIEW_PATH.read_text(encoding="utf-8")
        edited = review.replace(
            "Current:\n~~~text\nCurrent label\n~~~\n\nReplacement:\n~~~text\n\n~~~",
            "Current:\n~~~text\nCurrent label\n~~~\n\nReplacement:\n~~~text\nUpdated label\n~~~",
            1,
        )
        string_review.REVIEW_PATH.write_text(edited, encoding="utf-8")
        self.source.write_text('Text("Changed elsewhere")\nText("Keep this")\n', encoding="utf-8")

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            string_review.apply_review()
        self.assertIn("applied 0, skipped 1", output.getvalue())
        self.assertIn("expected one source literal match", output.getvalue())
        self.assertIn("Changed elsewhere", self.source.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
