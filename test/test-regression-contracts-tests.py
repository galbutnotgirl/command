#!/usr/bin/env python3
"""Negative tests proving feature contract validation fails closed."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR_PATH = ROOT / "test" / "test-regression-contracts.py"
SPEC = importlib.util.spec_from_file_location("regression_contract_validator", VALIDATOR_PATH)
assert SPEC and SPEC.loader
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class RegressionContractValidatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = json.loads((ROOT / "test" / "regression-contracts.json").read_text())
        cls.impact = json.loads((ROOT / "test" / "regression-impact.json").read_text())

    def failures(self, document: dict, impact: dict | None = None) -> list[str]:
        failures, _ = VALIDATOR.validate_contracts(document, impact or self.impact, ROOT)
        return failures

    def testCurrentFeatureContractsPass(self) -> None:
        self.assertEqual(self.failures(copy.deepcopy(self.document)), [])

    def testMissingOwnershipAreaRequirementFails(self) -> None:
        document = copy.deepcopy(self.document)
        del document["coverageRequirements"]["clipboard-history"]
        self.assertTrue(any("missing feature area coverage requirement" in item for item in self.failures(document)))

    def testUnknownOwnershipAreaFails(self) -> None:
        document = copy.deepcopy(self.document)
        document["regressions"][0]["areas"].append("imaginary-feature")
        self.assertTrue(any("unknown feature area" in item for item in self.failures(document)))

    def testMissingAreaContractFailsMinimum(self) -> None:
        document = copy.deepcopy(self.document)
        document["regressions"] = [
            entry for entry in document["regressions"]
            if "background-actions" not in entry["areas"]
        ]
        self.assertTrue(any("feature area background-actions" in item for item in self.failures(document)))

    def testSingleEvidenceLinkFails(self) -> None:
        document = copy.deepcopy(self.document)
        document["regressions"][0]["automatedEvidence"] = document["regressions"][0]["automatedEvidence"][:1]
        self.assertTrue(any("at least two automated evidence" in item for item in self.failures(document)))

    def testStaleEvidenceMarkerFails(self) -> None:
        document = copy.deepcopy(self.document)
        document["regressions"][0]["automatedEvidence"][0]["contains"] = "missing-marker"
        self.assertTrue(any("evidence marker missing" in item for item in self.failures(document)))

    def testNonReleaseEvidenceFails(self) -> None:
        document = copy.deepcopy(self.document)
        document["regressions"][0]["automatedEvidence"][0] = {
            "file": "README.md",
            "contains": "Command",
        }
        self.assertTrue(any("not executed by release gate" in item for item in self.failures(document)))

    def testDuplicateIDFails(self) -> None:
        document = copy.deepcopy(self.document)
        document["regressions"][1]["id"] = document["regressions"][0]["id"]
        self.assertTrue(any("IDs must be present and unique" in item for item in self.failures(document)))

    def testMalformedRegressionListFailsWithoutCrashing(self) -> None:
        document = copy.deepcopy(self.document)
        document["regressions"] = {"not": "a list"}
        self.assertTrue(any("regressions must be a list" in item for item in self.failures(document)))

    def testEvidenceCannotEscapeRepository(self) -> None:
        document = copy.deepcopy(self.document)
        document["regressions"][0]["automatedEvidence"][0] = {
            "file": "../outside.txt",
            "contains": "anything",
        }
        self.assertTrue(any("evidence path escapes repository" in item for item in self.failures(document)))

    def testManifestRootMustBeObject(self) -> None:
        self.assertEqual(
            self.failures(["not", "an", "object"]),
            ["regression manifest must be an object"],
        )

    def testAreaMinimumCannotBeLowered(self) -> None:
        document = copy.deepcopy(self.document)
        document["coverageRequirements"]["dictation"] = 1
        self.assertTrue(any("cannot drop below 10" in item for item in self.failures(document)))

    def testInstalledInputCoverageMinimumsCannotBeLowered(self) -> None:
        document = copy.deepcopy(self.document)
        document["coverageRequirements"]["app-runtime"] = 4
        self.assertTrue(any("app-runtime cannot drop below 5" in item for item in self.failures(document)))
        document = copy.deepcopy(self.document)
        document["coverageRequirements"]["shortcuts-and-input"] = 2
        self.assertTrue(any("shortcuts-and-input cannot drop below 3" in item for item in self.failures(document)))

    def testMandatoryGateDeclarationCannotBeRemoved(self) -> None:
        document = copy.deepcopy(self.document)
        document["requiredGates"] = []
        self.assertTrue(any("mandatory release gate declaration missing" in item for item in self.failures(document)))


if __name__ == "__main__":
    unittest.main()
