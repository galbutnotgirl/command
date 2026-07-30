import Foundation

public enum DictationWatchdogProbeStatus: String, Codable, Equatable, Sendable {
    case passed
    case modelUnavailable
    case recorderBusy
    case startRejected
    case watchdogNotObserved
    case cleanupTimedOut
    case recoveryFailed
    case failed
}

public struct DictationWatchdogProbeResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let status: DictationWatchdogProbeStatus
    public let stalledSessionID: Int
    public let stalledTerminalStage: String
    public let warningCount: Int
    public let resetCount: Int
    public let releasedDuringStartup: Bool
    public let cleanup: DictationCaptureResourceSnapshot
    public let recovery: DictationLifecycleProbeResult?
    public let durationMilliseconds: Int
    public let failure: String?

    public init(
        status: DictationWatchdogProbeStatus,
        stalledSessionID: Int = 0,
        stalledTerminalStage: String = "none",
        warningCount: Int = 0,
        resetCount: Int = 0,
        releasedDuringStartup: Bool = false,
        cleanup: DictationCaptureResourceSnapshot,
        recovery: DictationLifecycleProbeResult? = nil,
        durationMilliseconds: Int = 0,
        failure: String? = nil
    ) {
        self.ok = status == .passed
        self.status = status
        self.stalledSessionID = max(0, stalledSessionID)
        self.stalledTerminalStage = stalledTerminalStage
        self.warningCount = max(0, warningCount)
        self.resetCount = max(0, resetCount)
        self.releasedDuringStartup = releasedDuringStartup
        self.cleanup = cleanup
        self.recovery = recovery
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.failure = failure
    }
}

public enum DictationWatchdogProbeCoding {
    public static func encode(_ result: DictationWatchdogProbeResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    public static func decode(_ data: Data) throws -> DictationWatchdogProbeResult {
        try JSONDecoder().decode(DictationWatchdogProbeResult.self, from: data)
    }
}
