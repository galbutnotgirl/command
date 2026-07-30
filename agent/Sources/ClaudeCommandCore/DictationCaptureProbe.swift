import Foundation

public enum DictationCaptureProbeStatus: String, Codable, Equatable, Sendable {
    case passed
    case microphoneDenied
    case recorderBusy
    case inputUnavailable
    case engineStartFailed
    case noAudioBuffers
    case timedOut
}

public struct DictationCaptureProbeResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let status: DictationCaptureProbeStatus
    public let authorization: String
    public let capturedBuffers: Int
    public let inputDevice: String
    public let sampleRate: Double
    public let channelCount: Int
    public let durationMilliseconds: Int
    public let failure: String?

    public init(
        status: DictationCaptureProbeStatus,
        authorization: String,
        capturedBuffers: Int = 0,
        inputDevice: String = "unknown",
        sampleRate: Double = 0,
        channelCount: Int = 0,
        durationMilliseconds: Int = 0,
        failure: String? = nil
    ) {
        self.ok = status == .passed
        self.status = status
        self.authorization = authorization
        self.capturedBuffers = max(0, capturedBuffers)
        self.inputDevice = inputDevice
        self.sampleRate = max(0, sampleRate)
        self.channelCount = max(0, channelCount)
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.failure = failure
    }

    public static func completed(
        authorization: String,
        capturedBuffers: Int,
        inputDevice: String,
        sampleRate: Double,
        channelCount: Int,
        durationMilliseconds: Int
    ) -> DictationCaptureProbeResult {
        let status: DictationCaptureProbeStatus = capturedBuffers > 0 ? .passed : .noAudioBuffers
        return DictationCaptureProbeResult(
            status: status,
            authorization: authorization,
            capturedBuffers: capturedBuffers,
            inputDevice: inputDevice,
            sampleRate: sampleRate,
            channelCount: channelCount,
            durationMilliseconds: durationMilliseconds,
            failure: status == .noAudioBuffers ? "Microphone engine ran but delivered no audio buffers." : nil
        )
    }
}

public enum DictationCaptureProbeCoding {
    public static func encode(_ result: DictationCaptureProbeResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    public static func decode(_ data: Data) throws -> DictationCaptureProbeResult {
        try JSONDecoder().decode(DictationCaptureProbeResult.self, from: data)
    }
}
