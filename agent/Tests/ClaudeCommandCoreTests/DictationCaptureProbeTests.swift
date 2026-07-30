import XCTest
@testable import ClaudeCommandCore

final class DictationCaptureProbeTests: XCTestCase {
    func testCompletedProbePassesWhenAudioBuffersArrive() {
        let result = DictationCaptureProbeResult.completed(
            authorization: "authorized",
            capturedBuffers: 8,
            inputDevice: "MacBook Microphone",
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 800
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(result.capturedBuffers, 8)
        XCTAssertNil(result.failure)
    }

    func testCompletedProbeFailsWhenEngineDeliversNoBuffers() {
        let result = DictationCaptureProbeResult.completed(
            authorization: "authorized",
            capturedBuffers: 0,
            inputDevice: "MacBook Microphone",
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 800
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .noAudioBuffers)
        XCTAssertNotNil(result.failure)
    }

    func testFailureStatusesNeverReportSuccess() {
        for status in [
            DictationCaptureProbeStatus.microphoneDenied,
            .recorderBusy,
            .inputUnavailable,
            .engineStartFailed,
            .noAudioBuffers,
            .timedOut,
        ] {
            XCTAssertFalse(DictationCaptureProbeResult(
                status: status,
                authorization: "denied"
            ).ok)
        }
    }

    func testProbeResultRoundTripsAsSingleLineJSON() throws {
        let result = DictationCaptureProbeResult.completed(
            authorization: "authorized",
            capturedBuffers: 10,
            inputDevice: "USB Microphone",
            sampleRate: 44_100,
            channelCount: 2,
            durationMilliseconds: 750
        )

        let data = try DictationCaptureProbeCoding.encode(result)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"))
        XCTAssertEqual(try DictationCaptureProbeCoding.decode(data), result)
    }
}
