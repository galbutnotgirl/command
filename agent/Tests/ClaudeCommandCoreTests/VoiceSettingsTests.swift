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
        XCTAssertEqual(VoiceSettingsKeys.dictationAssistantProvider, "dictationAssistantProvider")
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
        XCTAssertEqual(VoiceSettingsDefaults.dictationAssistantProvider, "default")
    }

    func testDictationDefaultsUseHomeAndOptionHome() {
        let byAction = Dictionary(uniqueKeysWithValues: DEFAULT_BINDINGS.map { ($0.action, (keycode: $0.keycode, mods: $0.mods)) })
        XCTAssertEqual(byAction["dictate"]?.keycode, 115)
        XCTAssertEqual(byAction["dictate"]?.mods, 0)
        XCTAssertEqual(byAction["dictateadd"]?.keycode, 115)
        XCTAssertEqual(byAction["dictateadd"]?.mods, 2048)
        XCTAssertEqual(HotkeyBinding(action: "dictate", keycode: 115, mods: 0, enabled: true).human, "Home")
        XCTAssertEqual(HotkeyBinding(action: "dictateadd", keycode: 115, mods: 2048, enabled: true).human, "⌥Home")
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
