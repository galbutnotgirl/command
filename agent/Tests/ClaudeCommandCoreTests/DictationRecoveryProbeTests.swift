import XCTest
@testable import ClaudeCommandCore

final class DictationRecoveryProbeTests: XCTestCase {
    private func resources(
        phase: String = "error",
        overlay: Bool = false,
        engine: Bool = false,
        tap: Bool = false,
        stream: Bool = false,
        continuation: Bool = false,
        feeder: Bool = false,
        manager: Bool = false,
        timer: Bool = false,
        startup: Bool = false
    ) -> DictationCaptureResourceSnapshot {
        DictationCaptureResourceSnapshot(
            capturePhase: phase,
            overlayVisible: overlay,
            captureStartupBegan: startup,
            audioEngineActive: engine,
            audioTapActive: tap,
            streamTaskActive: stream,
            audioContinuationActive: continuation,
            bufferFeederActive: feeder,
            managerActive: manager,
            silenceTimerActive: timer
        )
    }

    func testReleasedSnapshotRequiresEveryCaptureResourceToBeIdle() {
        XCTAssertTrue(resources().fullyReleased)
        XCTAssertFalse(resources(overlay: true).fullyReleased)
        XCTAssertFalse(resources(engine: true).fullyReleased)
        XCTAssertFalse(resources(tap: true).fullyReleased)
        XCTAssertFalse(resources(stream: true).fullyReleased)
        XCTAssertFalse(resources(continuation: true).fullyReleased)
        XCTAssertFalse(resources(feeder: true).fullyReleased)
        XCTAssertFalse(resources(manager: true).fullyReleased)
        XCTAssertFalse(resources(timer: true).fullyReleased)
        XCTAssertFalse(resources(startup: true).fullyReleased)
    }

    func testPassedRecoveryCarriesFailureAndRetryEvidence() {
        let recovery = DictationLifecycleProbeResult(
            status: .passed,
            sessionID: 9,
            modelStatus: "ready",
            capturePhase: "idle",
            terminalStage: "empty",
            capturedBuffers: 5,
            durationMilliseconds: 900
        )
        let result = DictationRecoveryProbeResult(
            status: .passed,
            injectedSessionID: 8,
            injectedBuffers: 2,
            injectedTerminalStage: "failed",
            cleanup: resources(),
            recovery: recovery,
            durationMilliseconds: 1_500
        )

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.cleanup.fullyReleased)
        XCTAssertEqual(result.recovery?.sessionID, 9)
        XCTAssertEqual(result.recovery?.capturedBuffers, 5)
    }

    func testFailureStatusesNeverReportSuccess() {
        for status in [
            DictationRecoveryProbeStatus.modelUnavailable,
            .recorderBusy,
            .failureNotObserved,
            .cleanupTimedOut,
            .recoveryFailed,
            .failed,
        ] {
            XCTAssertFalse(DictationRecoveryProbeResult(status: status, cleanup: resources()).ok)
        }
    }

    func testRecoveryMetricsCannotBecomeNegative() {
        let result = DictationRecoveryProbeResult(
            status: .failed,
            injectedSessionID: -1,
            injectedBuffers: -2,
            cleanup: resources(),
            durationMilliseconds: -3
        )

        XCTAssertEqual(result.injectedSessionID, 0)
        XCTAssertEqual(result.injectedBuffers, 0)
        XCTAssertEqual(result.durationMilliseconds, 0)
    }

    func testRecoveryResultRoundTripsAsSingleLineJSON() throws {
        let result = DictationRecoveryProbeResult(
            status: .recoveryFailed,
            injectedSessionID: 4,
            injectedBuffers: 3,
            injectedTerminalStage: "failed",
            cleanup: resources(),
            recovery: DictationLifecycleProbeResult(status: .captureTimedOut),
            durationMilliseconds: 12,
            failure: "retry failed"
        )

        let data = try DictationRecoveryProbeCoding.encode(result)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"))
        XCTAssertEqual(try DictationRecoveryProbeCoding.decode(data), result)
    }
}
