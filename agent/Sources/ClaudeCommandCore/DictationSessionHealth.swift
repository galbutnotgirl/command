import Foundation

public enum DictationSessionStage: String, Codable, Equatable, Sendable {
    case starting
    case loadingModel
    case listening
    case capturing
    case finishing
    case completed
    case empty
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .empty, .failed, .cancelled: return true
        default: return false
        }
    }
}

public struct DictationSessionHealth: Codable, Equatable, Sendable {
    public let sessionID: Int
    public let mode: String
    public let startedAt: Date
    public private(set) var updatedAt: Date
    public private(set) var stage: DictationSessionStage
    public private(set) var inputDevice: String
    public private(set) var capturedBuffers: Int
    public private(set) var transcriptionUpdates: Int
    public private(set) var finalCharacters: Int
    public private(set) var failure: String?

    public init(sessionID: Int, mode: String, now: Date = Date()) {
        self.sessionID = sessionID
        self.mode = mode
        self.startedAt = now
        self.updatedAt = now
        self.stage = .starting
        self.inputDevice = "unknown"
        self.capturedBuffers = 0
        self.transcriptionUpdates = 0
        self.finalCharacters = 0
        self.failure = nil
    }

    public mutating func transition(
        to stage: DictationSessionStage,
        now: Date = Date(),
        inputDevice: String? = nil,
        capturedBuffers: Int? = nil,
        transcriptionUpdates: Int? = nil,
        finalCharacters: Int? = nil,
        failure: String? = nil
    ) {
        self.stage = stage
        self.updatedAt = now
        if let inputDevice { self.inputDevice = inputDevice }
        if let capturedBuffers { self.capturedBuffers = max(0, capturedBuffers) }
        if let transcriptionUpdates { self.transcriptionUpdates = max(0, transcriptionUpdates) }
        if let finalCharacters { self.finalCharacters = max(0, finalCharacters) }
        self.failure = failure
    }

    public mutating func updateMetrics(
        now: Date = Date(),
        inputDevice: String? = nil,
        capturedBuffers: Int? = nil,
        transcriptionUpdates: Int? = nil
    ) {
        updatedAt = now
        if let inputDevice { self.inputDevice = inputDevice }
        if let capturedBuffers { self.capturedBuffers = max(0, capturedBuffers) }
        if let transcriptionUpdates { self.transcriptionUpdates = max(0, transcriptionUpdates) }
    }

    public var indicatesInterruptedCapture: Bool { !stage.isTerminal }

    public var diagnosticSummary: String {
        let failureText = failure.map { " failure=\($0)" } ?? ""
        return "session=\(sessionID) mode=\(mode) stage=\(stage.rawValue) buffers=\(capturedBuffers) updates=\(transcriptionUpdates) finalChars=\(finalCharacters) device=\(inputDevice.debugDescription)\(failureText)"
    }
}

public enum DictationSessionHealthCoding {
    public static func encode(_ health: DictationSessionHealth) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(health)
    }

    public static func decode(_ data: Data) throws -> DictationSessionHealth {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DictationSessionHealth.self, from: data)
    }
}
