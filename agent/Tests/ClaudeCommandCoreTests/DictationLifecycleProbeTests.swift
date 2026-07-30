import XCTest
@testable import ClaudeCommandCore

final class DictationLifecycleProbeTests: XCTestCase {
    func testPassedLifecycleCarriesProductionMetrics() {
        let result = DictationLifecycleProbeResult(
            status: .passed,
            sessionID: 42,
            modelStatus: "ready",
            capturePhase: "idle",
            terminalStage: "empty",
            capturedBuffers: 8,
            transcriptionUpdates: 0,
            finalCharacters: 0,
            inputDevice: "MacBook Microphone",
            durationMilliseconds: 1_200
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.sessionID, 42)
        XCTAssertEqual(result.capturedBuffers, 8)
        XCTAssertEqual(result.terminalStage, "empty")
    }

    func testFailureStatusesNeverReportSuccess() {
        for status in [
            DictationLifecycleProbeStatus.modelUnavailable,
            .recorderBusy,
            .startRejected,
            .captureTimedOut,
            .finishTimedOut,
            .failed,
        ] {
            XCTAssertFalse(DictationLifecycleProbeResult(status: status).ok)
        }
    }

    func testLifecycleMetricsCannotBecomeNegative() {
        let result = DictationLifecycleProbeResult(
            status: .failed,
            sessionID: -1,
            capturedBuffers: -2,
            transcriptionUpdates: -3,
            finalCharacters: -4,
            durationMilliseconds: -5
        )

        XCTAssertEqual(result.sessionID, 0)
        XCTAssertEqual(result.capturedBuffers, 0)
        XCTAssertEqual(result.transcriptionUpdates, 0)
        XCTAssertEqual(result.finalCharacters, 0)
        XCTAssertEqual(result.durationMilliseconds, 0)
    }

    func testLifecycleResultRoundTripsAsSingleLineJSON() throws {
        let result = DictationLifecycleProbeResult(
            status: .passed,
            sessionID: 7,
            modelStatus: "ready",
            capturePhase: "idle",
            terminalStage: "completed",
            capturedBuffers: 12,
            transcriptionUpdates: 2,
            finalCharacters: 24,
            inputDevice: "USB Microphone",
            durationMilliseconds: 1_500
        )

        let data = try DictationLifecycleProbeCoding.encode(result)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"))
        XCTAssertEqual(try DictationLifecycleProbeCoding.decode(data), result)
    }

    func testLifecycleFailureKeepsStableTerminalStageField() throws {
        let data = try DictationLifecycleProbeCoding.encode(
            DictationLifecycleProbeResult(status: .startRejected)
        )
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(json.contains("\"terminalStage\":\"none\""))
    }
}
