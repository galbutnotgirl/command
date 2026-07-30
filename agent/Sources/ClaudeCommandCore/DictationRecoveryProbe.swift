import Foundation

public enum DictationRecoveryProbeStatus: String, Codable, Equatable, Sendable {
    case passed
    case modelUnavailable
    case recorderBusy
    case failureNotObserved
    case cleanupTimedOut
    case recoveryFailed
    case failed
}

public struct DictationCaptureResourceSnapshot: Codable, Equatable, Sendable {
    public let capturePhase: String
    public let overlayVisible: Bool
    public let captureStartupBegan: Bool
    public let audioEngineActive: Bool
    public let audioTapActive: Bool
    public let streamTaskActive: Bool
    public let audioContinuationActive: Bool
    public let bufferFeederActive: Bool
    public let managerActive: Bool
    public let silenceTimerActive: Bool
    public let fullyReleased: Bool

    public init(
        capturePhase: String,
        overlayVisible: Bool,
        captureStartupBegan: Bool,
        audioEngineActive: Bool,
        audioTapActive: Bool,
        streamTaskActive: Bool,
        audioContinuationActive: Bool,
        bufferFeederActive: Bool,
        managerActive: Bool,
        silenceTimerActive: Bool
    ) {
        self.capturePhase = capturePhase
        self.overlayVisible = overlayVisible
        self.captureStartupBegan = captureStartupBegan
        self.audioEngineActive = audioEngineActive
        self.audioTapActive = audioTapActive
        self.streamTaskActive = streamTaskActive
        self.audioContinuationActive = audioContinuationActive
        self.bufferFeederActive = bufferFeederActive
        self.managerActive = managerActive
        self.silenceTimerActive = silenceTimerActive
        self.fullyReleased = !overlayVisible
            && !captureStartupBegan
            && !audioEngineActive
            && !audioTapActive
            && !streamTaskActive
            && !audioContinuationActive
            && !bufferFeederActive
            && !managerActive
            && !silenceTimerActive
    }
}

public struct DictationRecoveryProbeResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let status: DictationRecoveryProbeStatus
    public let injectedSessionID: Int
    public let injectedBuffers: Int
    public let injectedTerminalStage: String
    public let cleanup: DictationCaptureResourceSnapshot
    public let recovery: DictationLifecycleProbeResult?
    public let durationMilliseconds: Int
    public let failure: String?

    public init(
        status: DictationRecoveryProbeStatus,
        injectedSessionID: Int = 0,
        injectedBuffers: Int = 0,
        injectedTerminalStage: String = "none",
        cleanup: DictationCaptureResourceSnapshot,
        recovery: DictationLifecycleProbeResult? = nil,
        durationMilliseconds: Int = 0,
        failure: String? = nil
    ) {
        self.ok = status == .passed
        self.status = status
        self.injectedSessionID = max(0, injectedSessionID)
        self.injectedBuffers = max(0, injectedBuffers)
        self.injectedTerminalStage = injectedTerminalStage
        self.cleanup = cleanup
        self.recovery = recovery
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.failure = failure
    }
}

public enum DictationRecoveryProbeCoding {
    public static func encode(_ result: DictationRecoveryProbeResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    public static func decode(_ data: Data) throws -> DictationRecoveryProbeResult {
        try JSONDecoder().decode(DictationRecoveryProbeResult.self, from: data)
    }
}
