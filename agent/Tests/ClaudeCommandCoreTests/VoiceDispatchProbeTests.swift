import XCTest
@testable import ClaudeCommandCore

final class VoiceDispatchProbeTests: XCTestCase {
    func testPassedProbeRequiresExplicitPassedStatus() {
        let result = VoiceDispatchProbeResult(
            status: .passed,
            eventTapDeliveredEvents: 2,
            configuredVoiceAliases: 4,
            sessionID: 9,
            capturedBuffers: 6,
            terminalStage: "completed",
            capturePhase: "idle",
            resourcesReleased: true,
            durationMilliseconds: 900
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.eventTapDeliveredEvents, 2)
        XCTAssertEqual(result.capturedBuffers, 6)
        XCTAssertTrue(result.resourcesReleased)
    }

    func testFailureStatusesNeverReportSuccess() {
        for status in [
            VoiceDispatchProbeStatus.modelUnavailable,
            .recorderBusy,
            .accessibilityUnavailable,
            .eventTapMissing,
            .eventTapDisabled,
            .probeBusy,
            .eventCreationFailed,
            .eventDeliveryTimedOut,
            .startRejected,
            .captureTimedOut,
            .failed,
            .finishTimedOut,
        ] {
            XCTAssertFalse(VoiceDispatchProbeResult(status: status).ok)
        }
    }

    func testMetricsCannotBecomeNegative() {
        let result = VoiceDispatchProbeResult(
            status: .failed,
            eventTapDeliveredEvents: -1,
            configuredVoiceAliases: -2,
            sessionID: -3,
            capturedBuffers: -4,
            durationMilliseconds: -5
        )

        XCTAssertEqual(result.eventTapDeliveredEvents, 0)
        XCTAssertEqual(result.configuredVoiceAliases, 0)
        XCTAssertEqual(result.sessionID, 0)
        XCTAssertEqual(result.capturedBuffers, 0)
        XCTAssertEqual(result.durationMilliseconds, 0)
    }

    func testProbeResultRoundTripsAsSingleLineJSON() throws {
        let result = VoiceDispatchProbeResult(
            status: .eventDeliveryTimedOut,
            eventTapDeliveredEvents: 1,
            configuredVoiceAliases: 2,
            sessionID: 4,
            capturedBuffers: 3,
            terminalStage: "capturing",
            capturePhase: "listening",
            durationMilliseconds: 12,
            failure: "release event missing"
        )

        let data = try VoiceDispatchProbeCoding.encode(result)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"))
        XCTAssertEqual(try VoiceDispatchProbeCoding.decode(data), result)
    }
}
