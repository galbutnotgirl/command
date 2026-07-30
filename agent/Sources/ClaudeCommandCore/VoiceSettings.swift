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

public enum DictationTriggerHealthAction: Equatable, Sendable {
    case proceed
    case resetStaleTrigger
    case resetStaleOverlay
    case waitForFinishing
}

public func dictationTriggerHealthAction(
    triggerIsIdle: Bool,
    overlayVisible: Bool,
    capturePhase: DictationCapturePhase
) -> DictationTriggerHealthAction {
    if capturePhase == .finishing { return .waitForFinishing }
    if !overlayVisible && !triggerIsIdle { return .resetStaleTrigger }
    if overlayVisible && (capturePhase == .idle || capturePhase == .error) {
        return .resetStaleOverlay
    }
    return .proceed
}

public struct DictationCaptureWatchdogPolicy: Equatable, Sendable {
    public let warningDelayNanoseconds: UInt64
    public let recoveryDelayNanoseconds: UInt64

    public init(
        warningDelayNanoseconds: UInt64 = 1_500_000_000,
        recoveryDelayNanoseconds: UInt64 = 6_000_000_000
    ) {
        self.warningDelayNanoseconds = warningDelayNanoseconds
        self.recoveryDelayNanoseconds = max(recoveryDelayNanoseconds, warningDelayNanoseconds)
    }

    public func shouldWarn(phase: DictationCapturePhase, capturedBufferCount: Int) -> Bool {
        capturedBufferCount == 0 && (phase == .starting || phase == .listening)
    }

    public func shouldRecover(phase: DictationCapturePhase, capturedBufferCount: Int) -> Bool {
        shouldWarn(phase: phase, capturedBufferCount: capturedBufferCount)
    }
}

public let DEFAULT_DICTATION_CAPTURE_WATCHDOG_POLICY = DictationCaptureWatchdogPolicy()

public enum DictationCaptureWatchdogAction: Equatable, Sendable {
    case none
    case warn
    case recovered
    case resetCapture
}

public struct DictationCaptureWatchdog: Equatable, Sendable {
    public let policy: DictationCaptureWatchdogPolicy

    private var lastBufferCount = 0
    private var lastProgressAtNanoseconds: UInt64?
    private var warningIssued = false

    public init(policy: DictationCaptureWatchdogPolicy = DEFAULT_DICTATION_CAPTURE_WATCHDOG_POLICY) {
        self.policy = policy
    }

    public mutating func observe(
        nowNanoseconds: UInt64,
        phase: DictationCapturePhase,
        capturedBufferCount: Int
    ) -> DictationCaptureWatchdogAction {
        guard phase == .starting || phase == .listening else {
            reset(capturedBufferCount: capturedBufferCount)
            return .none
        }

        let bufferCount = max(0, capturedBufferCount)
        if lastProgressAtNanoseconds == nil || bufferCount != lastBufferCount {
            let recovered = warningIssued && bufferCount > lastBufferCount
            lastBufferCount = bufferCount
            lastProgressAtNanoseconds = nowNanoseconds
            warningIssued = false
            return recovered ? .recovered : .none
        }

        let lastProgress = lastProgressAtNanoseconds ?? nowNanoseconds
        let elapsed = nowNanoseconds >= lastProgress ? nowNanoseconds - lastProgress : 0
        if elapsed >= policy.recoveryDelayNanoseconds {
            return .resetCapture
        }
        if elapsed >= policy.warningDelayNanoseconds, !warningIssued {
            warningIssued = true
            return .warn
        }
        return .none
    }

    public mutating func reset(
        nowNanoseconds: UInt64? = nil,
        capturedBufferCount: Int = 0
    ) {
        lastBufferCount = max(0, capturedBufferCount)
        lastProgressAtNanoseconds = nowNanoseconds
        warningIssued = false
    }
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

    public func shouldDispatch(text: String, recordedSeconds: Double) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && recordedSeconds >= minimumDuration
    }
}

public struct DictationStopTailPolicy: Equatable, Sendable {
    public let activeAudioLevelThreshold: Float
    public let recentSpeechWindowSeconds: Double
    public let quietTailNanoseconds: UInt64
    public let settledSpeechTailNanoseconds: UInt64
    public let activeTailNanoseconds: UInt64

    public init(
        activeAudioLevelThreshold: Float = 0.035,
        recentSpeechWindowSeconds: Double = 0.45,
        quietTailNanoseconds: UInt64 = 150_000_000,
        settledSpeechTailNanoseconds: UInt64 = 300_000_000,
        activeTailNanoseconds: UInt64 = 500_000_000
    ) {
        self.activeAudioLevelThreshold = activeAudioLevelThreshold
        self.recentSpeechWindowSeconds = recentSpeechWindowSeconds
        self.quietTailNanoseconds = quietTailNanoseconds
        self.settledSpeechTailNanoseconds = settledSpeechTailNanoseconds
        self.activeTailNanoseconds = activeTailNanoseconds
    }

    public func tailNanoseconds(
        for audioLevel: Float,
        secondsSinceActiveSpeech: Double = .infinity,
        capturedSpeechSeconds: Double = 0
    ) -> UInt64 {
        let speechIsCurrent = audioLevel > activeAudioLevelThreshold
        let speechWasRecent = secondsSinceActiveSpeech <= recentSpeechWindowSeconds
        let recordingContainsSpeech = capturedSpeechSeconds > 0
        if speechIsCurrent || speechWasRecent { return activeTailNanoseconds }
        if recordingContainsSpeech { return settledSpeechTailNanoseconds }
        return quietTailNanoseconds
    }
}

public let DEFAULT_DICTATION_STOP_TAIL_POLICY = DictationStopTailPolicy()
