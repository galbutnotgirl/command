import XCTest
@testable import ClaudeCommandCore

final class ImportValidationTests: XCTestCase {
    func testCurrentBundlePayloadsAreDetectedAtNestedPaths() {
        let hotkeys: [[String: Any]] = [["action": "add", "keycode": 100, "mods": 0]]
        let templates = ["add": "Review this"]
        let object: [String: Any] = [
            "shortcuts": ["hotkeys": hotkeys],
            "templates": ["commandTemplates": templates],
            "appPreferences": ["defaultProvider": "codex"]
        ]

        XCTAssertEqual((importPayload(.shortcutBindings, from: object) as? [[String: Any]])?.count, 1)
        XCTAssertEqual(importPayload(.commandTemplates, from: object) as? [String: String], templates)
        XCTAssertEqual(
            availableImportPayloadSections(in: object),
            [.shortcutBindings, .commandTemplates, .appPreferences]
        )
    }

    func testLegacyTopLevelPayloadsRemainImportable() {
        let object: [String: Any] = [
            "hotkeys": [["action": "add", "keycode": 100, "mods": 0]],
            "customActions": [["id": "one", "name": "One", "prompt": "Do one"]],
            "builtInComposeSettings": ["autoSubmitDefault": false, "autoSubmitOverrides": [:]],
            "commandTemplates": ["add": "Review this"],
            "enrichRules": [["match": "host", "pattern": "example.com", "text": "Example"]]
        ]

        XCTAssertEqual(
            availableImportPayloadSections(in: object),
            [.shortcutBindings, .customActions, .builtInCompose, .commandTemplates, .contextRules]
        )
        for section in availableImportPayloadSections(in: object) {
            XCTAssertTrue(isValidImportPayload(importPayload(section, from: object) as Any, for: section))
        }
    }

    func testLegacyVocabularyFileIsDetectedAsVocabularyOnly() {
        let object: [String: Any] = [
            "replacements": [["wrong": "clawed", "correct": "Claude"]],
            "vocab": ["Contentstack"]
        ]

        XCTAssertEqual(availableImportPayloadSections(in: object), [.vocabulary])
        XCTAssertTrue(isValidImportPayload(importPayload(.vocabulary, from: object) as Any, for: .vocabulary))
    }

    func testExportFilenameUsesLocalCalendarDate() {
        let date = Date(timeIntervalSince1970: 1_783_830_896)
        XCTAssertEqual(
            commandExportFilename(for: date, timeZone: TimeZone(secondsFromGMT: 0)!),
            "command-export-2026-07-12.json"
        )
    }

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
