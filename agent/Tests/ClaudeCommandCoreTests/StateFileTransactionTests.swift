import XCTest
@testable import ClaudeCommandCore

final class StateFileTransactionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-state-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTransactionWritesAndVerifiesEveryMutation() throws {
        let first = directory.appendingPathComponent("nested/first.json")
        let second = directory.appendingPathComponent("second.json")
        let firstData = Data("{\"value\":1}".utf8)
        let secondData = Data("{\"value\":2}".utf8)

        try applyStateFileMutations([
            StateFileMutation(url: first, data: firstData),
            StateFileMutation(url: second, data: secondData),
        ])

        XCTAssertEqual(try Data(contentsOf: first), firstData)
        XCTAssertEqual(try Data(contentsOf: second), secondData)
    }

    func testDuplicateDestinationFailsBeforeWriting() throws {
        let target = directory.appendingPathComponent("settings.json")
        let original = Data("old".utf8)
        try original.write(to: target)

        XCTAssertThrowsError(try applyStateFileMutations([
            StateFileMutation(url: target, data: Data("one".utf8)),
            StateFileMutation(url: target, data: Data("two".utf8)),
        ])) { error in
            guard case StateFileTransactionError.duplicateDestination = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testLaterWriteFailureRollsBackEveryExistingFile() throws {
        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")
        let oldFirst = Data("old-first".utf8)
        let oldSecond = Data("old-second".utf8)
        try oldFirst.write(to: first)
        try oldSecond.write(to: second)

        XCTAssertThrowsError(try applyStateFileMutations([
            StateFileMutation(url: first, data: Data("new-first".utf8)),
            StateFileMutation(url: second, data: Data("new-second".utf8)),
        ], writer: { data, url in
            try data.write(to: url, options: .atomic)
            if url == second { throw TestFailure.injected }
        }))

        XCTAssertEqual(try Data(contentsOf: first), oldFirst)
        XCTAssertEqual(try Data(contentsOf: second), oldSecond)
    }

    func testFailedTransactionRemovesNewFiles() throws {
        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")

        XCTAssertThrowsError(try applyStateFileMutations([
            StateFileMutation(url: first, data: Data("first".utf8)),
            StateFileMutation(url: second, data: Data("second".utf8)),
        ], writer: { data, url in
            try data.write(to: url, options: .atomic)
            if url == second { throw TestFailure.injected }
        }))

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testReadBackMismatchRestoresPreviousFile() throws {
        let target = directory.appendingPathComponent("settings.json")
        let original = Data("old".utf8)
        try original.write(to: target)

        XCTAssertThrowsError(try applyStateFileMutations([
            StateFileMutation(url: target, data: Data("expected".utf8)),
        ], writer: { _, url in
            try Data("different".utf8).write(to: url, options: .atomic)
        })) { error in
            guard case StateFileTransactionError.verificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    private enum TestFailure: Error {
        case injected
    }
}
