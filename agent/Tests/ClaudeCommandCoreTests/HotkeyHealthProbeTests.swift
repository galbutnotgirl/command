import XCTest
@testable import ClaudeCommandCore

final class HotkeyHealthProbeTests: XCTestCase {
    func testPassedProbeCarriesInstalledInputMetrics() {
        let result = HotkeyHealthProbeResult(
            status: .passed,
            accessibilityTrusted: true,
            eventTapInstalled: true,
            eventTapEnabled: true,
            expectedCarbonRegistrations: 4,
            actualCarbonRegistrations: 4,
            expectedEventTapAliases: 2,
            configuredVoiceAliases: 3,
            expectedCarbonVoiceAliases: 2,
            expectedEventTapVoiceAliases: 1,
            validatedCarbonVoiceAliases: 2,
            requestedEvents: 100,
            deliveredEvents: 100,
            durationMilliseconds: 25
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.expectedCarbonRegistrations, result.actualCarbonRegistrations)
        XCTAssertEqual(result.validatedCarbonVoiceAliases, result.expectedCarbonVoiceAliases)
        XCTAssertEqual(result.requestedEvents, result.deliveredEvents)
    }

    func testFailureStatusesNeverReportSuccess() {
        for status in [
            HotkeyHealthProbeStatus.accessibilityUnavailable,
            .eventTapMissing,
            .eventTapDisabled,
            .registrationMismatch,
            .probeBusy,
            .eventCreationFailed,
            .eventDeliveryTimedOut,
        ] {
            XCTAssertFalse(HotkeyHealthProbeResult(status: status).ok)
        }
    }

    func testProbeMetricsCannotBecomeNegative() {
        let result = HotkeyHealthProbeResult(
            status: .registrationMismatch,
            expectedCarbonRegistrations: -1,
            actualCarbonRegistrations: -2,
            registrationFailures: -3,
            expectedEventTapAliases: -4,
            configuredVoiceAliases: -5,
            expectedCarbonVoiceAliases: -6,
            expectedEventTapVoiceAliases: -7,
            validatedCarbonVoiceAliases: -8,
            requestedEvents: -9,
            deliveredEvents: -10,
            durationMilliseconds: -11
        )

        XCTAssertEqual(result.expectedCarbonRegistrations, 0)
        XCTAssertEqual(result.actualCarbonRegistrations, 0)
        XCTAssertEqual(result.registrationFailures, 0)
        XCTAssertEqual(result.expectedEventTapAliases, 0)
        XCTAssertEqual(result.configuredVoiceAliases, 0)
        XCTAssertEqual(result.expectedCarbonVoiceAliases, 0)
        XCTAssertEqual(result.expectedEventTapVoiceAliases, 0)
        XCTAssertEqual(result.validatedCarbonVoiceAliases, 0)
        XCTAssertEqual(result.requestedEvents, 0)
        XCTAssertEqual(result.deliveredEvents, 0)
        XCTAssertEqual(result.durationMilliseconds, 0)
    }

    func testProbeResultRoundTripsAsSingleLineJSON() throws {
        let result = HotkeyHealthProbeResult(
            status: .eventDeliveryTimedOut,
            accessibilityTrusted: true,
            eventTapInstalled: true,
            eventTapEnabled: true,
            requestedEvents: 10,
            deliveredEvents: 9,
            durationMilliseconds: 2_000,
            failure: "Tagged event did not reach callback."
        )

        let data = try HotkeyHealthProbeCoding.encode(result)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"))
        XCTAssertEqual(try HotkeyHealthProbeCoding.decode(data), result)
    }
}
