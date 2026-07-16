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
        XCTAssertFalse(gate.shouldDispatch(text: "", activeSpeechSeconds: 1.0))
        XCTAssertFalse(gate.shouldDispatch(text: "hey", activeSpeechSeconds: 0.19))
        XCTAssertTrue(gate.shouldDispatch(text: "hey", activeSpeechSeconds: 0.2))
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
        XCTAssertEqual(HotkeyBinding(action: "dictate", keycode: 63, mods: 0, enabled: true).human, "Fn")
        XCTAssertEqual(HotkeyBinding(action: "dictateadd", keycode: 0, mods: 0, enabled: true).human, "—")
        XCTAssertEqual(HotkeyBinding(action: "dictateadd2", keycode: 0, mods: 0, enabled: true).human, "—")
    }

    func testDictationStopTailPolicyKeepsFastQuietStopsAndLongerActiveTail() {
        let policy = DEFAULT_DICTATION_STOP_TAIL_POLICY
        XCTAssertEqual(policy.activeAudioLevelThreshold, 0.035, accuracy: 0.0001)
        XCTAssertEqual(policy.quietTailNanoseconds, 250_000_000)
        XCTAssertEqual(policy.activeTailNanoseconds, 850_000_000)
        XCTAssertEqual(policy.tailNanoseconds(for: 0.0), 250_000_000)
        XCTAssertEqual(policy.tailNanoseconds(for: 0.035), 250_000_000)
        XCTAssertEqual(policy.tailNanoseconds(for: 0.036), 850_000_000)
    }
}
