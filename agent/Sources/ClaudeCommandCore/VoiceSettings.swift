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
    public static let dictationAssistantProvider = "dictationAssistantProvider"
}

public enum VoiceSettingsDefaults {
    public static let fillerRemoval = true
    public static let smartFormatting = true
    public static let aiCleanup = true
    public static let soundsEnabled = true
    public static let soundVolume = 0.35
    public static let startSound = "Purr"
    public static let stopSound = "Purr"
    public static let dictationAssistantProvider = "default"
}

public struct DictationStopTailPolicy: Equatable, Sendable {
    public let activeAudioLevelThreshold: Float
    public let quietTailNanoseconds: UInt64
    public let activeTailNanoseconds: UInt64

    public init(
        activeAudioLevelThreshold: Float = 0.035,
        quietTailNanoseconds: UInt64 = 250_000_000,
        activeTailNanoseconds: UInt64 = 850_000_000
    ) {
        self.activeAudioLevelThreshold = activeAudioLevelThreshold
        self.quietTailNanoseconds = quietTailNanoseconds
        self.activeTailNanoseconds = activeTailNanoseconds
    }

    public func tailNanoseconds(for audioLevel: Float) -> UInt64 {
        audioLevel > activeAudioLevelThreshold ? activeTailNanoseconds : quietTailNanoseconds
    }
}

public let DEFAULT_DICTATION_STOP_TAIL_POLICY = DictationStopTailPolicy()
