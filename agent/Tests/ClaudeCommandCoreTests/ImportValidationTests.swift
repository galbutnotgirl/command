import XCTest
@testable import ClaudeCommandCore

final class ImportValidationTests: XCTestCase {
    func testShortcutBindingsRequireTypedActionKeyAndModifiers() {
        XCTAssertTrue(isValidImportPayload([
            ["action": "go", "keycode": 100, "mods": 0, "enabled": true]
        ], for: .shortcutBindings))
        XCTAssertFalse(isValidImportPayload([
            ["action": "go", "keycode": "F8", "mods": 0]
        ], for: .shortcutBindings))
    }

    func testContextRulesRejectUnknownMatchType() {
        XCTAssertTrue(isValidImportPayload([
            ["match": "host", "pattern": "example.com", "text": "Context"]
        ], for: .contextRules))
        XCTAssertFalse(isValidImportPayload([
            ["match": "window-title", "pattern": "Example", "text": "Context"]
        ], for: .contextRules))
    }

    func testVocabularyRejectsMalformedReplacement() {
        XCTAssertTrue(isValidImportPayload([
            "replacements": [["wrong": "codec", "correct": "Codex"]],
            "vocab": ["Contentstack"],
            "fillers": [["phrase": "um"]]
        ], for: .vocabulary))
        XCTAssertFalse(isValidImportPayload([
            "replacements": [["wrong": "codec"]]
        ], for: .vocabulary))
    }

    func testAppPreferencesRejectInvalidProviderAndRetention() {
        XCTAssertTrue(isValidImportPayload([
            "defaultProvider": "codex",
            "claudeDestination": "recent",
            "clipRetentionDays": 7,
            VoiceSettingsKeys.soundVolume: 0.75
        ], for: .appPreferences))
        XCTAssertFalse(isValidImportPayload([
            "defaultProvider": "unknown"
        ], for: .appPreferences))
        XCTAssertFalse(isValidImportPayload([
            "clipRetentionDays": 0
        ], for: .appPreferences))
    }

    func testJSONSerializationBridgedNumbersPassExpectedSchemas() throws {
        let data = Data(#"{"hotkeys":[{"action":"go","keycode":100,"mods":0}],"prefs":{"soundVolume":0.5}}"#.utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(isValidImportPayload(try XCTUnwrap(root["hotkeys"]), for: .shortcutBindings))
        XCTAssertTrue(isValidImportPayload(try XCTUnwrap(root["prefs"]), for: .appPreferences))
    }
}
