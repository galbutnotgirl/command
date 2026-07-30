import Foundation

public enum DictationInsertProbeStatus: String, Codable, Equatable, Sendable {
    case passed
    case accessibilityUnavailable
    case receiverUnavailable
    case pipelineSuppressed
    case clipboardWriteFailed
    case targetInactive
    case pasteEventFailed
    case pasteTimedOut
    case clipboardRestoreFailed
    case previousAppRestoreFailed
    case failed
}

public struct DictationInsertProbeResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let status: DictationInsertProbeStatus
    public let pipelineStatus: String
    public let rawCharacters: Int
    public let processedCharacters: Int
    public let clipboardWritten: Bool
    public let targetActive: Bool
    public let pasteEventPosted: Bool
    public let receiverMatched: Bool
    public let clipboardRestored: Bool
    public let previousAppRestored: Bool
    public let durationMilliseconds: Int
    public let failure: String?

    public init(
        status: DictationInsertProbeStatus,
        pipelineStatus: String = "unknown",
        rawCharacters: Int = 0,
        processedCharacters: Int = 0,
        clipboardWritten: Bool = false,
        targetActive: Bool = false,
        pasteEventPosted: Bool = false,
        receiverMatched: Bool = false,
        clipboardRestored: Bool = false,
        previousAppRestored: Bool = false,
        durationMilliseconds: Int = 0,
        failure: String? = nil
    ) {
        self.ok = status == .passed
        self.status = status
        self.pipelineStatus = pipelineStatus
        self.rawCharacters = max(0, rawCharacters)
        self.processedCharacters = max(0, processedCharacters)
        self.clipboardWritten = clipboardWritten
        self.targetActive = targetActive
        self.pasteEventPosted = pasteEventPosted
        self.receiverMatched = receiverMatched
        self.clipboardRestored = clipboardRestored
        self.previousAppRestored = previousAppRestored
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.failure = failure
    }
}

public enum DictationInsertProbeCoding {
    public static func encode(_ result: DictationInsertProbeResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    public static func decode(_ data: Data) throws -> DictationInsertProbeResult {
        try JSONDecoder().decode(DictationInsertProbeResult.self, from: data)
    }
}
