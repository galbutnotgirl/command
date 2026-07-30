import XCTest
@testable import ClaudeCommandCore

final class DictationWatchdogProbeTests: XCTestCase {
    private var released: DictationCaptureResourceSnapshot {
        DictationCaptureResourceSnapshot(
            capturePhase: "idle",
            overlayVisible: false,
            captureStartupBegan: false,
            audioEngineActive: false,
            audioTapActive: false,
            streamTaskActive: false,
            audioContinuationActive: false,
            bufferFeederActive: false,
            managerActive: false,
            silenceTimerActive: false
        )
    }

    func testPassedProbeCarriesStallWarningResetAndRetryEvidence() throws {
        let retry = DictationLifecycleProbeResult(
            status: .passed,
            sessionID: 12,
            modelStatus: "ready",
            capturePhase: "idle",
            terminalStage: "completed",
            capturedBuffers: 8,
            durationMilliseconds: 900
        )
        let result = DictationWatchdogProbeResult(
            status: .passed,
            stalledSessionID: 11,
            stalledTerminalStage: "cancelled",
            warningCount: 1,
            resetCount: 1,
            releasedDuringStartup: true,
            cleanup: released,
            recovery: retry,
            durationMilliseconds: 7_200
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.scenario, .startup)
        XCTAssertEqual(result.stalledSessionID, 11)
        XCTAssertEqual(result.stalledCapturedBuffers, 0)
        XCTAssertEqual(result.stalledTerminalStage, "cancelled")
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(result.resetCount, 1)
        XCTAssertTrue(result.releasedDuringStartup)
        XCTAssertTrue(result.cleanup.fullyReleased)
        XCTAssertEqual(result.recovery?.sessionID, 12)
        XCTAssertNil(result.failure)

        let decoded = try DictationWatchdogProbeCoding.decode(
            DictationWatchdogProbeCoding.encode(result)
        )
        XCTAssertEqual(decoded, result)
    }

    func testPassedMidstreamProbeCarriesLiveBufferStallEvidence() throws {
        let retry = DictationLifecycleProbeResult(
            status: .passed,
            sessionID: 22,
            modelStatus: "ready",
            capturePhase: "idle",
            terminalStage: "completed",
            capturedBuffers: 6,
            durationMilliseconds: 850
        )
        let result = DictationWatchdogProbeResult(
            status: .passed,
            scenario: .midstream,
            stalledSessionID: 21,
            stalledCapturedBuffers: 3,
            stalledTerminalStage: "cancelled",
            warningCount: 1,
            resetCount: 1,
            releasedDuringStartup: false,
            cleanup: released,
            recovery: retry,
            durationMilliseconds: 7_100
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.scenario, .midstream)
        XCTAssertEqual(result.stalledCapturedBuffers, 3)
        XCTAssertFalse(result.releasedDuringStartup)
        XCTAssertTrue(result.cleanup.fullyReleased)
        XCTAssertEqual(result.recovery?.sessionID, 22)
        XCTAssertEqual(
            try DictationWatchdogProbeCoding.decode(DictationWatchdogProbeCoding.encode(result)),
            result
        )
    }

    func testFailureStatusCannotReportSuccessAndClampsCounters() {
        let result = DictationWatchdogProbeResult(
            status: .watchdogNotObserved,
            stalledSessionID: -1,
            warningCount: -1,
            resetCount: -2,
            cleanup: released,
            durationMilliseconds: -3,
            failure: "watchdog missing"
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.scenario, .startup)
        XCTAssertEqual(result.stalledSessionID, 0)
        XCTAssertEqual(result.warningCount, 0)
        XCTAssertEqual(result.resetCount, 0)
        XCTAssertEqual(result.durationMilliseconds, 0)
        XCTAssertEqual(result.failure, "watchdog missing")
    }
}
