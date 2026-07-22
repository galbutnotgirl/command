import XCTest
@testable import ClaudeCommandCore

final class ImportMergeTests: XCTestCase {
    func testMergeDictionaryArraysIncomingWinsByKeyAndKeepsOrder() {
        let current: [[String: Any]] = [
            ["action": "add", "keycode": 100],
            ["action": "go", "keycode": 0],
        ]
        let incoming: [[String: Any]] = [
            ["action": "go", "keycode": 101],
            ["action": "comment", "keycode": 98],
        ]

        let merged = mergeDictionaryArrays(current: current, incoming: incoming, key: "action")
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0]["action"] as? String, "add")
        XCTAssertEqual(merged[1]["action"] as? String, "go")
        XCTAssertEqual(merged[1]["keycode"] as? Int, 101)
        XCTAssertEqual(merged[2]["action"] as? String, "comment")
    }

    func testMergeDictionaryValuesIncomingWins() {
        let merged = mergeDictionaryValues(
            current: ["add": "{selection}", "go": "old"],
            incoming: ["go": "new", "comment": "comment"]
        )

        XCTAssertEqual(merged["add"] as? String, "{selection}")
        XCTAssertEqual(merged["go"] as? String, "new")
        XCTAssertEqual(merged["comment"] as? String, "comment")
    }

    func testMergeEnrichRulesKeepsSameHostDifferentPathPrefixesDistinct() {
        let current: [[String: Any]] = [
            ["match": "host", "pattern": "docs.google.com", "pathPrefix": "/document/", "text": "Docs"],
            ["match": "host", "pattern": "docs.google.com", "pathPrefix": "/spreadsheets/", "text": "Sheets"],
        ]
        let incoming: [[String: Any]] = [
            ["match": "host", "pattern": "docs.google.com", "pathPrefix": "/presentation/", "text": "Slides"],
            ["match": "host", "pattern": "docs.google.com", "pathPrefix": "/document/", "text": "Docs updated"],
        ]

        let merged = mergeEnrichRuleDictionaries(current: current, incoming: incoming)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0]["text"] as? String, "Docs updated")
        XCTAssertEqual(merged[1]["text"] as? String, "Sheets")
        XCTAssertEqual(merged[2]["text"] as? String, "Slides")
    }

    func testMergeVocabularyUnionsTermsAndIncomingCorrectionWins() {
        let current: [String: Any] = [
            "vocab": ["Contentstack", "AXP"],
            "replacements": [["wrong": "ax pea", "correct": "AXP"]],
            "fillers": [["phrase": "um", "enabled": true]],
        ]
        let incoming: [String: Any] = [
            "vocab": ["AXP", "Personalize"],
            "replacements": [["wrong": "ax pea", "correct": "AXP strategy"]],
            "fillers": [["phrase": "you know", "enabled": false]],
            "futureSchemaField": ["enabled": true],
        ]

        let merged = mergeVocabularyDictionaries(current: current, incoming: incoming)
        XCTAssertEqual(merged["vocab"] as? [String], ["AXP", "Contentstack", "Personalize"])
        let replacements = merged["replacements"] as? [[String: Any]]
        XCTAssertEqual(replacements?.count, 1)
        XCTAssertEqual(replacements?.first?["correct"] as? String, "AXP strategy")
        let fillers = merged["fillers"] as? [[String: Any]]
        XCTAssertEqual(fillers?.count, 2)
        XCTAssertEqual((merged["futureSchemaField"] as? [String: Bool])?["enabled"], true)
    }

    func testImportFileMutationsCommitAllFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.json")
        let second = root.appendingPathComponent("nested/second.json")

        try applyImportFileMutations([
            ImportFileMutation(url: first, data: Data("first".utf8)),
            ImportFileMutation(url: second, data: Data("second".utf8)),
        ])

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    func testImportFileMutationsRollBackExistingAndNewFilesAfterFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.json")
        let created = root.appendingPathComponent("created.json")
        try Data("original".utf8).write(to: existing)
        var writes = 0

        XCTAssertThrowsError(try applyImportFileMutations([
            ImportFileMutation(url: existing, data: Data("updated".utf8)),
            ImportFileMutation(url: created, data: Data("created".utf8)),
        ], writer: { data, url in
            writes += 1
            try data.write(to: url, options: .atomic)
            if writes == 2 { throw CocoaError(.fileWriteUnknown) }
        }))

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
    }

    func testImportFileMutationsRejectDuplicateDestinationBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("settings.json")
        var wrote = false

        XCTAssertThrowsError(try applyImportFileMutations([
            ImportFileMutation(url: destination, data: Data("one".utf8)),
            ImportFileMutation(url: destination, data: Data("two".utf8)),
        ], writer: { _, _ in wrote = true }))
        XCTAssertFalse(wrote)
    }

    func testEncodeImportJSONObjectRejectsUnsupportedValues() {
        XCTAssertThrowsError(try encodeImportJSONObject(["date": Date()]))
    }

    func testVocabularyPreviewCountsSameAddedUpdatedAndCurrentOnly() {
        let current: [String: Any] = [
            "vocab": ["AXP", "Contentstack"],
            "replacements": [
                ["wrong": "ax pea", "correct": "AXP"],
                ["wrong": "old", "correct": "Old"],
            ],
            "fillers": [
                ["phrase": "um", "enabled": true],
                ["phrase": "old filler", "enabled": true],
            ],
        ]
        let incoming: [String: Any] = [
            "vocab": ["Contentstack", "Personalize"],
            "replacements": [
                ["wrong": "ax pea", "correct": "AXP"],
                ["wrong": "old", "correct": "New"],
                ["wrong": "new", "correct": "New"],
            ],
            "fillers": [
                ["phrase": "um", "enabled": true],
                ["phrase": "new filler", "enabled": false],
            ],
        ]

        XCTAssertEqual(
            vocabularyImportPreviewCounts(current: current, incoming: incoming),
            ImportPreviewCounts(incoming: 7, current: 6, same: 3, added: 3, updated: 1, currentOnly: 2)
        )
    }
}
