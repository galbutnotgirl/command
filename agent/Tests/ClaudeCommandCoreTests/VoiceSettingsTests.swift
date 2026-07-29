import XCTest
@testable import ClaudeCommandCore

final class VoiceSettingsTests: XCTestCase {
    func testVoiceSettingsKeysStayStableForPersistenceAndImportExport() {
        XCTAssertEqual(VoiceSettingsKeys.fillerRemoval, "proc_filler")
        XCTAssertEqual(VoiceSettingsKeys.smartFormatting, "proc_format")
        XCTAssertEqual(VoiceSettingsKeys.aiCleanup, "proc_ai")
        XCTAssertEqual(VoiceSettingsKeys.aiCleanupMigration, "proc_ai_v3")
        XCTAssertEqual(VoiceSettingsKeys.soundsEnabled, "soundsEnabled")
        XCTAssertEqual(VoiceSettingsKeys.soundVolume, "soundVolume")
        XCTAssertEqual(VoiceSettingsKeys.startSound, "startSound")
        XCTAssertEqual(VoiceSettingsKeys.stopSound, "stopSound")
        XCTAssertEqual(VoiceSettingsKeys.dictationEnabled, "dictationEnabled")
        XCTAssertEqual(VoiceSettingsKeys.minDictationDuration, "minDictationDuration")
        XCTAssertEqual(VoiceSettingsKeys.dictationAssistantProvider, "dictationAssistantProvider")
        XCTAssertEqual(VoiceSettingsKeys.dictationAssistant2Provider, "dictationAssistant2Provider")
    }

    func testProcessingSettingsArePartOfVoicePersistenceContract() {
        XCTAssertEqual(
            Set([VoiceSettingsKeys.fillerRemoval, VoiceSettingsKeys.smartFormatting, VoiceSettingsKeys.aiCleanup]),
            Set(["proc_filler", "proc_format", "proc_ai"])
        )
    }

    func testVoiceSettingsDefaultsStayUserFriendly() {
        XCTAssertTrue(VoiceSettingsDefaults.fillerRemoval)
        XCTAssertTrue(VoiceSettingsDefaults.smartFormatting)
        XCTAssertTrue(VoiceSettingsDefaults.aiCleanup)
        XCTAssertTrue(VoiceSettingsDefaults.soundsEnabled)
        XCTAssertEqual(VoiceSettingsDefaults.soundVolume, 0.35, accuracy: 0.0001)
        XCTAssertEqual(VoiceSettingsDefaults.startSound, "Purr")
        XCTAssertEqual(VoiceSettingsDefaults.stopSound, "Purr")
        XCTAssertFalse(VoiceSettingsDefaults.dictationEnabled)
        XCTAssertEqual(VoiceSettingsDefaults.minDictationDuration, 0.2, accuracy: 0.0001)
        XCTAssertEqual(VoiceSettingsDefaults.dictationAssistantProvider, "default")
        XCTAssertEqual(VoiceSettingsDefaults.dictationAssistant2Provider, "codex")
    }

    func testDictationActivityGateDropsShortOrEmptyResults() {
        let gate = DictationActivityGate(minimumDuration: 0.2)
        XCTAssertFalse(gate.shouldDispatch(text: "", recordedSeconds: 1.0))
        XCTAssertFalse(gate.shouldDispatch(text: "hey", recordedSeconds: 0.19))
        XCTAssertTrue(gate.shouldDispatch(text: "hey", recordedSeconds: 0.2))
    }

    func testDictationActivityGateKeepsValidTranscriptWhenRMSMissesSpeech() {
        let gate = DictationActivityGate(minimumDuration: 0.2)
        let transcript = String(repeating: "spoken words ", count: 31)
        XCTAssertEqual(transcript.count, 403)
        XCTAssertTrue(gate.shouldDispatch(text: transcript, recordedSeconds: 34.1))
    }

    func testDictationActivityGateUsesAdaptiveNoiseFloor() {
        let gate = DictationActivityGate(minimumDuration: 0.2, minimumRMS: 0.006, noiseMultiplier: 3.0)
        XCTAssertEqual(gate.threshold(noiseFloor: 0.001), 0.006, accuracy: 0.0001)
        XCTAssertEqual(gate.threshold(noiseFloor: 0.004), 0.012, accuracy: 0.0001)
    }

    func testDictationDefaultsUseFnAndAssistantUnbound() {
        let byAction = Dictionary(uniqueKeysWithValues: DEFAULT_BINDINGS.map { ($0.action, (keycode: $0.keycode, mods: $0.mods)) })
        XCTAssertEqual(byAction["dictate"]?.keycode, 63)
        XCTAssertEqual(byAction["dictate"]?.mods, 0)
        XCTAssertEqual(byAction["dictateadd"]?.keycode, 0)
        XCTAssertEqual(byAction["dictateadd"]?.mods, 0)
        XCTAssertEqual(byAction["dictateadd2"]?.keycode, 0)
        XCTAssertEqual(byAction["dictateadd2"]?.mods, 0)
        XCTAssertEqual(HotkeyBinding(action: "dictate", keycode: 63, mods: 0, enabled: true).human, "fn")
        XCTAssertEqual(HotkeyBinding(action: "dictateadd", keycode: 0, mods: 0, enabled: true).human, "—")
        XCTAssertEqual(HotkeyBinding(action: "dictateadd2", keycode: 0, mods: 0, enabled: true).human, "—")
    }

    func testDictationStopTailPolicyKeepsFastQuietStopsAndLongerActiveTail() {
        let policy = DEFAULT_DICTATION_STOP_TAIL_POLICY
        XCTAssertEqual(policy.activeAudioLevelThreshold, 0.035, accuracy: 0.0001)
        XCTAssertEqual(policy.recentSpeechWindowSeconds, 0.45, accuracy: 0.0001)
        XCTAssertEqual(policy.quietTailNanoseconds, 150_000_000)
        XCTAssertEqual(policy.settledSpeechTailNanoseconds, 300_000_000)
        XCTAssertEqual(policy.activeTailNanoseconds, 500_000_000)
        XCTAssertEqual(policy.tailNanoseconds(for: 0.0), 150_000_000)
        XCTAssertEqual(policy.tailNanoseconds(for: 0.035), 150_000_000)
        XCTAssertEqual(policy.tailNanoseconds(for: 0.036), 500_000_000)
    }

    func testDictationStopTailProtectsSpeechBeforeQuietReleaseFrame() {
        let policy = DEFAULT_DICTATION_STOP_TAIL_POLICY
        XCTAssertEqual(
            policy.tailNanoseconds(for: 0.0, secondsSinceActiveSpeech: 0.10),
            500_000_000
        )
        XCTAssertEqual(
            policy.tailNanoseconds(for: 0.0, secondsSinceActiveSpeech: 0.45),
            500_000_000
        )
        XCTAssertEqual(
            policy.tailNanoseconds(for: 0.0, secondsSinceActiveSpeech: 0.46),
            150_000_000
        )
    }

    func testDictationStopTailProtectsSoftFinalWordsAfterPause() {
        let policy = DEFAULT_DICTATION_STOP_TAIL_POLICY
        XCTAssertEqual(
            policy.tailNanoseconds(
                for: 0.026,
                secondsSinceActiveSpeech: 1.3,
                capturedSpeechSeconds: 0.8
            ),
            300_000_000
        )
        XCTAssertEqual(
            policy.tailNanoseconds(
                for: 0.0,
                secondsSinceActiveSpeech: .infinity,
                capturedSpeechSeconds: 0
            ),
            150_000_000
        )
    }

    func testDictationCapturePhaseBlocksRestartWhileFinishing() {
        XCTAssertTrue(DictationCapturePhase.idle.canStart)
        XCTAssertTrue(DictationCapturePhase.error.canStart)
        XCTAssertTrue(DictationCapturePhase.starting.canStop)
        XCTAssertTrue(DictationCapturePhase.listening.canStop)
        XCTAssertFalse(DictationCapturePhase.finishing.canStart)
        XCTAssertFalse(DictationCapturePhase.finishing.canStop)
    }

    func testDictationTriggerHealthResetsDriftAndBlocksFinishing() {
        XCTAssertEqual(
            dictationTriggerHealthAction(triggerIsIdle: false, overlayVisible: false, capturePhase: .idle),
            .resetStaleTrigger
        )
        XCTAssertEqual(
            dictationTriggerHealthAction(triggerIsIdle: true, overlayVisible: true, capturePhase: .idle),
            .resetStaleOverlay
        )
        XCTAssertEqual(
            dictationTriggerHealthAction(triggerIsIdle: true, overlayVisible: false, capturePhase: .finishing),
            .waitForFinishing
        )
        XCTAssertEqual(
            dictationTriggerHealthAction(triggerIsIdle: false, overlayVisible: true, capturePhase: .listening),
            .proceed
        )
    }

    func testDictationCaptureWatchdogOnlyFlagsActiveCaptureWithoutBuffers() {
        let policy = DictationCaptureWatchdogPolicy()
        XCTAssertEqual(policy.warningDelayNanoseconds, 1_500_000_000)
        XCTAssertEqual(policy.recoveryDelayNanoseconds, 6_000_000_000)
        XCTAssertTrue(policy.shouldWarn(phase: .starting, capturedBufferCount: 0))
        XCTAssertTrue(policy.shouldRecover(phase: .listening, capturedBufferCount: 0))
        XCTAssertFalse(policy.shouldWarn(phase: .listening, capturedBufferCount: 1))
        XCTAssertFalse(policy.shouldRecover(phase: .finishing, capturedBufferCount: 0))
        XCTAssertFalse(policy.shouldWarn(phase: .idle, capturedBufferCount: 0))
    }

    func testPreferredTranscriptKeepsLongerTail() {
        XCTAssertEqual(
            preferredDictationTranscript(final: "finish this", lastPartial: "finish this sentence"),
            "finish this sentence"
        )
        XCTAssertEqual(
            preferredDictationTranscript(final: "finish this sentence cleanly", lastPartial: "finish this"),
            "finish this sentence cleanly"
        )
    }

    func testStartAndStopCuesNeverSharePreparedPlayer() {
        XCTAssertNotEqual(
            DictationCueRole.start.cacheKey(soundName: "Purr"),
            DictationCueRole.stop.cacheKey(soundName: "Purr")
        )
        XCTAssertEqual(DictationCueRole.preview.cacheKey(soundName: "Purr"), "preview:Purr")
    }
}
