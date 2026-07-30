import Foundation

public enum DictationLifecycleProbeStatus: String, Codable, Equatable, Sendable {
    case passed
    case modelUnavailable
    case recorderBusy
    case startRejected
    case captureTimedOut
    case finishTimedOut
    case failed
}

public struct DictationLifecycleProbeResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let status: DictationLifecycleProbeStatus
    public let sessionID: Int
    public let modelStatus: String
    public let capturePhase: String
    public let terminalStage: String
    public let capturedBuffers: Int
    public let transcriptionUpdates: Int
    public let finalCharacters: Int
    public let inputDevice: String
    public let durationMilliseconds: Int
    public let failure: String?

    public init(
        status: DictationLifecycleProbeStatus,
        sessionID: Int = 0,
        modelStatus: String = "unknown",
        capturePhase: String = "unknown",
        terminalStage: String = "none",
        capturedBuffers: Int = 0,
        transcriptionUpdates: Int = 0,
        finalCharacters: Int = 0,
        inputDevice: String = "unknown",
        durationMilliseconds: Int = 0,
        failure: String? = nil
    ) {
        self.ok = status == .passed
        self.status = status
        self.sessionID = max(0, sessionID)
        self.modelStatus = modelStatus
        self.capturePhase = capturePhase
        self.terminalStage = terminalStage
        self.capturedBuffers = max(0, capturedBuffers)
        self.transcriptionUpdates = max(0, transcriptionUpdates)
        self.finalCharacters = max(0, finalCharacters)
        self.inputDevice = inputDevice
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.failure = failure
    }
}

public enum DictationLifecycleProbeCoding {
    public static func encode(_ result: DictationLifecycleProbeResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    public static func decode(_ data: Data) throws -> DictationLifecycleProbeResult {
        try JSONDecoder().decode(DictationLifecycleProbeResult.self, from: data)
    }
}
