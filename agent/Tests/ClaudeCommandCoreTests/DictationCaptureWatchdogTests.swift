import XCTest
@testable import ClaudeCommandCore

final class DictationCaptureWatchdogTests: XCTestCase {
    private let policy = DictationCaptureWatchdogPolicy(
        warningDelayNanoseconds: 1_500,
        recoveryDelayNanoseconds: 6_000
    )

    func testStartupWithoutCaptureWarnsThenResets() {
        var watchdog = DictationCaptureWatchdog(policy: policy)

        XCTAssertEqual(watchdog.observe(nowNanoseconds: 0, phase: .starting, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 1_499, phase: .starting, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 1_500, phase: .starting, capturedBufferCount: 0), .warn)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 2_000, phase: .starting, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 6_000, phase: .starting, capturedBufferCount: 0), .resetCapture)
    }

    func testBufferProgressRecoversWarningAndRestartsDeadline() {
        var watchdog = DictationCaptureWatchdog(policy: policy)

        XCTAssertEqual(watchdog.observe(nowNanoseconds: 0, phase: .starting, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 1_500, phase: .starting, capturedBufferCount: 0), .warn)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 2_000, phase: .listening, capturedBufferCount: 1), .recovered)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 3_499, phase: .listening, capturedBufferCount: 1), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 3_500, phase: .listening, capturedBufferCount: 1), .warn)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 8_000, phase: .listening, capturedBufferCount: 1), .resetCapture)
    }

    func testContinuousBuffersNeverWarn() {
        var watchdog = DictationCaptureWatchdog(policy: policy)

        XCTAssertEqual(watchdog.observe(nowNanoseconds: 0, phase: .starting, capturedBufferCount: 0), .none)
        for index in 1...20 {
            XCTAssertEqual(
                watchdog.observe(
                    nowNanoseconds: UInt64(index * 1_000),
                    phase: .listening,
                    capturedBufferCount: index
                ),
                .none
            )
        }
    }

    func testFinishingDisarmsPendingWarning() {
        var watchdog = DictationCaptureWatchdog(policy: policy)

        XCTAssertEqual(watchdog.observe(nowNanoseconds: 0, phase: .starting, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 1_500, phase: .starting, capturedBufferCount: 0), .warn)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 2_000, phase: .finishing, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 9_000, phase: .finishing, capturedBufferCount: 0), .none)
    }

    func testNewCaptureAfterIdleStartsFreshDeadline() {
        var watchdog = DictationCaptureWatchdog(policy: policy)

        XCTAssertEqual(watchdog.observe(nowNanoseconds: 0, phase: .starting, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 6_000, phase: .starting, capturedBufferCount: 0), .resetCapture)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 7_000, phase: .idle, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 8_000, phase: .starting, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 9_499, phase: .starting, capturedBufferCount: 0), .none)
        XCTAssertEqual(watchdog.observe(nowNanoseconds: 9_500, phase: .starting, capturedBufferCount: 0), .warn)
    }
}
