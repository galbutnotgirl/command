import XCTest
@testable import ClaudeCommandCore

final class RegressionAttestationTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)

    private func data(
        result: String = "passed",
        suite: String = regressionAttestationSuite,
        commit: String? = nil,
        version: String = "1.2.3",
        generatedAt: String = "2026-07-30T10:00:00Z",
        gates: [String] = requiredRegressionGateIDs
    ) throws -> Data {
        try JSONEncoder().encode(RegressionAttestation(
            schemaVersion: regressionAttestationSchemaVersion,
            result: result,
            suite: suite,
            commit: commit ?? self.commit,
            branch: "main",
            version: version,
            generatedAt: generatedAt,
            requiredGates: gates
        ))
    }

    func testAcceptsExactQualifiedBuildAndFutureExtraGate() throws {
        var gates = requiredRegressionGateIDs
        gates.append("future-gate")
        XCTAssertNil(regressionAttestationValidationFailure(
            data: try data(gates: gates),
            expectedVersion: "1.2.3",
            expectedBuildMarker: "main@aaaaaaa"
        ))
    }

    func testRejectsUnqualifiedOrUnknownSuite() throws {
        XCTAssertEqual(
            regressionAttestationValidationFailure(
                data: try data(result: "unqualified"),
                expectedVersion: "1.2.3",
                expectedBuildMarker: "main@aaaaaaa"
            ),
            "Build did not pass required regression gates."
        )
        XCTAssertNotNil(regressionAttestationValidationFailure(
            data: try data(suite: "other-suite"),
            expectedVersion: "1.2.3",
            expectedBuildMarker: "main@aaaaaaa"
        ))
    }

    func testRejectsVersionAndCommitMarkerMismatch() throws {
        XCTAssertNotNil(regressionAttestationValidationFailure(
            data: try data(version: "9.9.9"),
            expectedVersion: "1.2.3",
            expectedBuildMarker: "main@aaaaaaa"
        ))
        XCTAssertNotNil(regressionAttestationValidationFailure(
            data: try data(),
            expectedVersion: "1.2.3",
            expectedBuildMarker: "main@bbbbbbb"
        ))
    }

    func testRejectsInvalidCommitTimestampAndMissingGate() throws {
        XCTAssertNotNil(regressionAttestationValidationFailure(
            data: try data(commit: "short"),
            expectedVersion: "1.2.3",
            expectedBuildMarker: "main@short"
        ))
        XCTAssertNotNil(regressionAttestationValidationFailure(
            data: try data(generatedAt: "not-a-date"),
            expectedVersion: "1.2.3",
            expectedBuildMarker: "main@aaaaaaa"
        ))
        XCTAssertNotNil(regressionAttestationValidationFailure(
            data: try data(gates: Array(requiredRegressionGateIDs.dropLast())),
            expectedVersion: "1.2.3",
            expectedBuildMarker: "main@aaaaaaa"
        ))
    }

    func testRejectsDuplicateGateAndMalformedJSON() throws {
        var gates = requiredRegressionGateIDs
        gates.append(gates[0])
        XCTAssertNotNil(regressionAttestationValidationFailure(
            data: try data(gates: gates),
            expectedVersion: "1.2.3",
            expectedBuildMarker: "main@aaaaaaa"
        ))
        XCTAssertEqual(
            regressionAttestationValidationFailure(
                data: Data("not-json".utf8),
                expectedVersion: "1.2.3",
                expectedBuildMarker: "main@aaaaaaa"
            ),
            "Regression attestation is unreadable."
        )
    }
}
