import Foundation

public let regressionAttestationSchemaVersion = 1
public let regressionAttestationSuite = "command-full-regression-v1"
public let requiredRegressionGateIDs = [
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

public struct RegressionAttestation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let result: String
    public let suite: String
    public let commit: String
    public let branch: String
    public let version: String
    public let generatedAt: String
    public let requiredGates: [String]

    public init(
        schemaVersion: Int,
        result: String,
        suite: String,
        commit: String,
        branch: String,
        version: String,
        generatedAt: String,
        requiredGates: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.result = result
        self.suite = suite
        self.commit = commit
        self.branch = branch
        self.version = version
        self.generatedAt = generatedAt
        self.requiredGates = requiredGates
    }
}

public func regressionAttestationValidationFailure(
    data: Data,
    expectedVersion: String,
    expectedBuildMarker: String
) -> String? {
    guard let attestation = try? JSONDecoder().decode(RegressionAttestation.self, from: data) else {
        return "Regression attestation is unreadable."
    }
    guard attestation.schemaVersion == regressionAttestationSchemaVersion else {
        return "Regression attestation schema is unsupported."
    }
    guard attestation.result == "passed", attestation.suite == regressionAttestationSuite else {
        return "Build did not pass required regression gates."
    }
    guard attestation.commit.count == 40,
          attestation.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
        return "Regression attestation commit is invalid."
    }
    guard !attestation.branch.isEmpty, !attestation.version.isEmpty else {
        return "Regression attestation identity is incomplete."
    }
    guard attestation.version == expectedVersion else {
        return "Regression attestation version does not match app metadata."
    }
    let marker = "\(attestation.branch)@\(attestation.commit.prefix(7))"
    guard marker == expectedBuildMarker else {
        return "Regression attestation commit does not match app metadata."
    }
    let formatter = ISO8601DateFormatter()
    guard formatter.date(from: attestation.generatedAt) != nil else {
        return "Regression attestation timestamp is invalid."
    }
    let gateSet = Set(attestation.requiredGates)
    guard gateSet.count == attestation.requiredGates.count,
          requiredRegressionGateIDs.allSatisfy(gateSet.contains) else {
        return "Regression attestation is missing required test gates."
    }
    return nil
}
