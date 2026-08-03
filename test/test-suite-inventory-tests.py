#!/usr/bin/env python3

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "suite_inventory",
    ROOT / "test" / "test-suite-inventory.py",
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SuiteInventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.document = json.loads((ROOT / "test" / "suite-inventory.json").read_text())

    def testCurrentInventoryPasses(self) -> None:
        failures, swift_total, node_total = MODULE.validate_inventory(self.document, ROOT)
        self.assertEqual(failures, [])
        self.assertGreaterEqual(swift_total, 242)
        self.assertGreaterEqual(node_total, 58)

    def testMissingCriticalSuiteFails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            failures, _, _ = MODULE.validate_inventory(self.document, Path(temporary))
        self.assertTrue(any("required Swift suite is missing" in failure for failure in failures))

    def testLoweredObservedCountFailsMinimum(self) -> None:
        document = copy.deepcopy(self.document)
        document["swiftSuites"]["StateFileTransactionTests.swift"] = 99
        failures, _, _ = MODULE.validate_inventory(document, ROOT)
        self.assertTrue(any("StateFileTransactionTests.swift has 5 tests" in failure for failure in failures))

    def testTotalFloorsCannotExceedObservedCoverage(self) -> None:
        document = copy.deepcopy(self.document)
        document["minimumSwiftTests"] = 999
        document["minimumNodeTests"] = 999
        failures, _, _ = MODULE.validate_inventory(document, ROOT)
        self.assertTrue(any("Swift inventory has" in failure for failure in failures))
        self.assertTrue(any("Node inventory has" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
