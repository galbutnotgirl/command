import Foundation

public enum VoiceDispatchProbeStatus: String, Codable, Equatable, Sendable {
    case passed
    case modelUnavailable
    case recorderBusy
    case accessibilityUnavailable
    case eventTapMissing
    case eventTapDisabled
    case probeBusy
    case eventCreationFailed
    case eventDeliveryTimedOut
    case startRejected
    case captureTimedOut
    case failed
    case finishTimedOut
}

public struct VoiceDispatchProbeResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let status: VoiceDispatchProbeStatus
    public let eventTapDeliveredEvents: Int
    public let configuredVoiceAliases: Int
    public let sessionID: Int
    public let capturedBuffers: Int
    public let terminalStage: String
    public let capturePhase: String
    public let resourcesReleased: Bool
    public let durationMilliseconds: Int
    public let failure: String?

    public init(
        status: VoiceDispatchProbeStatus,
        eventTapDeliveredEvents: Int = 0,
        configuredVoiceAliases: Int = 0,
        sessionID: Int = 0,
        capturedBuffers: Int = 0,
        terminalStage: String = "none",
        capturePhase: String = "unknown",
        resourcesReleased: Bool = false,
        durationMilliseconds: Int = 0,
        failure: String? = nil
    ) {
        self.ok = status == .passed
        self.status = status
        self.eventTapDeliveredEvents = max(0, eventTapDeliveredEvents)
        self.configuredVoiceAliases = max(0, configuredVoiceAliases)
        self.sessionID = max(0, sessionID)
        self.capturedBuffers = max(0, capturedBuffers)
        self.terminalStage = terminalStage
        self.capturePhase = capturePhase
        self.resourcesReleased = resourcesReleased
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.failure = failure
    }
}

public enum VoiceDispatchProbeCoding {
    public static func encode(_ result: VoiceDispatchProbeResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    public static func decode(_ data: Data) throws -> VoiceDispatchProbeResult {
        try JSONDecoder().decode(VoiceDispatchProbeResult.self, from: data)
    }
}
