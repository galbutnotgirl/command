import Foundation

public enum VoiceSettingsKeys {
    public static let fillerRemoval = "proc_filler"
    public static let smartFormatting = "proc_format"
    public static let aiCleanup = "proc_ai"
    public static let aiCleanupMigration = "proc_ai_v3"
    public static let soundsEnabled = "soundsEnabled"
    public static let soundVolume = "soundVolume"
    public static let startSound = "startSound"
    public static let stopSound = "stopSound"
    public static let dictationEnabled = "dictationEnabled"
    public static let minDictationDuration = "minDictationDuration"
    public static let dictationAssistantProvider = "dictationAssistantProvider"
    public static let dictationAssistant2Provider = "dictationAssistant2Provider"
}

public enum VoiceSettingsDefaults {
    public static let fillerRemoval = true
    public static let smartFormatting = true
    public static let aiCleanup = true
    public static let soundsEnabled = true
    public static let soundVolume = 0.35
    public static let startSound = "Purr"
    public static let stopSound = "Purr"
    public static let dictationEnabled = false
    public static let minDictationDuration = 0.2
    public static let dictationAssistantProvider = "default"
    public static let dictationAssistant2Provider = "codex"
}

public enum DictationCapturePhase: String, Equatable, Sendable {
    case idle, loading, starting, listening, finishing, error

    public var canStart: Bool { self == .idle || self == .error }
    public var canStop: Bool { self == .starting || self == .listening }
}

public func preferredDictationTranscript(final: String, lastPartial: String) -> String {
    final.count >= lastPartial.count ? final : lastPartial
}

public enum DictationCueRole: String, Equatable, Sendable {
    case start, stop, preview

    public func cacheKey(soundName: String) -> String { "\(rawValue):\(soundName)" }
}

public struct DictationActivityGate: Equatable, Sendable {
    public let minimumDuration: Double
    public let minimumRMS: Float
    public let noiseMultiplier: Float

    public init(
        minimumDuration: Double = VoiceSettingsDefaults.minDictationDuration,
        minimumRMS: Float = 0.006,
        noiseMultiplier: Float = 3.0
    ) {
        self.minimumDuration = max(0, minimumDuration)
        self.minimumRMS = minimumRMS
        self.noiseMultiplier = noiseMultiplier
    }

    public func threshold(noiseFloor: Float) -> Float {
        max(minimumRMS, noiseFloor * noiseMultiplier)
    }

    public func shouldDispatch(text: String, activeSpeechSeconds: Double) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && activeSpeechSeconds >= minimumDuration
    }
}

public struct DictationStopTailPolicy: Equatable, Sendable {
    public let activeAudioLevelThreshold: Float
    public let recentSpeechWindowSeconds: Double
    public let quietTailNanoseconds: UInt64
    public let activeTailNanoseconds: UInt64

    public init(
        activeAudioLevelThreshold: Float = 0.035,
        recentSpeechWindowSeconds: Double = 0.45,
        quietTailNanoseconds: UInt64 = 250_000_000,
        activeTailNanoseconds: UInt64 = 850_000_000
    ) {
        self.activeAudioLevelThreshold = activeAudioLevelThreshold
        self.recentSpeechWindowSeconds = recentSpeechWindowSeconds
        self.quietTailNanoseconds = quietTailNanoseconds
        self.activeTailNanoseconds = activeTailNanoseconds
    }

    public func tailNanoseconds(for audioLevel: Float, secondsSinceActiveSpeech: Double = .infinity) -> UInt64 {
        let speechIsCurrent = audioLevel > activeAudioLevelThreshold
        let speechWasRecent = secondsSinceActiveSpeech <= recentSpeechWindowSeconds
        return speechIsCurrent || speechWasRecent ? activeTailNanoseconds : quietTailNanoseconds
    }
}

public let DEFAULT_DICTATION_STOP_TAIL_POLICY = DictationStopTailPolicy()
