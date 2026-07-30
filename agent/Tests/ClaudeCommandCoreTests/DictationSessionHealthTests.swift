import XCTest
@testable import ClaudeCommandCore

final class DictationSessionHealthTests: XCTestCase {
    func testHealthySessionRecordsEveryCriticalCaptureStage() {
        let started = Date(timeIntervalSince1970: 1_000)
        var health = DictationSessionHealth(sessionID: 7, mode: "insert", now: started)

        XCTAssertEqual(health.stage, .starting)
        XCTAssertTrue(health.indicatesInterruptedCapture)

        health.transition(to: .loadingModel, now: started.addingTimeInterval(0.1))
        health.transition(to: .listening, now: started.addingTimeInterval(0.2), inputDevice: "MacBook Pro Microphone")
        health.transition(to: .capturing, now: started.addingTimeInterval(0.3), capturedBuffers: 1)
        health.transition(
            to: .finishing,
            now: started.addingTimeInterval(1),
            capturedBuffers: 12,
            transcriptionUpdates: 3
        )
        health.transition(
            to: .completed,
            now: started.addingTimeInterval(1.5),
            capturedBuffers: 14,
            transcriptionUpdates: 4,
            finalCharacters: 52
        )

        XCTAssertFalse(health.indicatesInterruptedCapture)
        XCTAssertEqual(health.capturedBuffers, 14)
        XCTAssertEqual(health.transcriptionUpdates, 4)
        XCTAssertEqual(health.finalCharacters, 52)
        XCTAssertTrue(health.diagnosticSummary.contains("stage=completed"))
        XCTAssertTrue(health.diagnosticSummary.contains("device=\"MacBook Pro Microphone\""))
    }

    func testNonterminalSessionIdentifiesPriorInterruptedCapture() {
        var health = DictationSessionHealth(sessionID: 9, mode: "claude")
        health.transition(to: .listening, capturedBuffers: 0)

        XCTAssertTrue(health.indicatesInterruptedCapture)
        XCTAssertTrue(DictationSessionStage.completed.isTerminal)
        XCTAssertTrue(DictationSessionStage.failed.isTerminal)
        XCTAssertTrue(DictationSessionStage.cancelled.isTerminal)
    }

    func testFailureAndEmptySessionsPreserveUsefulDiagnostics() {
        var failed = DictationSessionHealth(sessionID: 10, mode: "insert")
        failed.transition(to: .failed, capturedBuffers: 0, failure: "engine.start failed")
        XCTAssertFalse(failed.indicatesInterruptedCapture)
        XCTAssertEqual(failed.failure, "engine.start failed")

        var empty = DictationSessionHealth(sessionID: 11, mode: "insert")
        empty.transition(to: .empty, capturedBuffers: 1, transcriptionUpdates: 0)
        XCTAssertFalse(empty.indicatesInterruptedCapture)
        XCTAssertEqual(empty.capturedBuffers, 1)
    }

    func testHealthSnapshotRoundTripsWithStableDates() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var health = DictationSessionHealth(sessionID: 12, mode: "custom", now: now)
        health.transition(to: .capturing, now: now, inputDevice: "USB Mic", capturedBuffers: 2)

        let data = try DictationSessionHealthCoding.encode(health)
        let decoded = try DictationSessionHealthCoding.decode(data)

        XCTAssertEqual(decoded, health)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"stage\" : \"capturing\""))
    }

    func testMetricUpdatesNeverOverwriteTerminalOrFinishingStage() {
        var health = DictationSessionHealth(sessionID: 13, mode: "insert")
        health.transition(to: .finishing)
        health.updateMetrics(capturedBuffers: 8, transcriptionUpdates: 2)

        XCTAssertEqual(health.stage, .finishing)
        XCTAssertEqual(health.capturedBuffers, 8)
        XCTAssertEqual(health.transcriptionUpdates, 2)
    }
}
