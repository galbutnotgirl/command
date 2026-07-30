import XCTest
@testable import ClaudeCommandCore

final class DictationTriggerCoordinatorTests: XCTestCase {
    func testHeldDictationStartsAndStopsImmediatelyOnRelease() {
        var coordinator = DictationTriggerCoordinator()

        XCTAssertEqual(coordinator.press(at: 10), .startRecording)
        XCTAssertEqual(coordinator.mode, .pushToTalk)
        XCTAssertEqual(coordinator.release(at: 11), .stopRecording)
        XCTAssertEqual(coordinator.mode, .idle)
    }

    func testQuickTapDefersOnlyRemainingDoubleTapWindow() {
        var coordinator = DictationTriggerCoordinator()

        XCTAssertEqual(coordinator.press(at: 20), .startRecording)
        guard case .deferStop(let delay) = coordinator.release(at: 20.1) else {
            return XCTFail("Expected deferred stop after quick tap")
        }
        XCTAssertEqual(delay, 0.25, accuracy: 0.0001)
        XCTAssertEqual(coordinator.mode, .awaitingSecondTap)
        XCTAssertEqual(coordinator.deferredStopFired(), .stopRecording)
        XCTAssertEqual(coordinator.mode, .idle)
    }

    func testSecondTapLocksExistingRecordingAndCancelsDeferredStop() {
        var coordinator = DictationTriggerCoordinator()

        XCTAssertEqual(coordinator.press(at: 30), .startRecording)
        guard case .deferStop(let delay) = coordinator.release(at: 30.1) else {
            return XCTFail("Expected deferred stop after quick tap")
        }
        XCTAssertEqual(delay, 0.25, accuracy: 0.0001)
        XCTAssertEqual(coordinator.press(at: 30.2), .lockRecording)
        XCTAssertEqual(coordinator.mode, .locked)
        XCTAssertEqual(coordinator.release(at: 30.25), .none)
        XCTAssertEqual(coordinator.deferredStopFired(), .none)
        XCTAssertEqual(coordinator.mode, .locked)
    }

    func testTapWhileLockedStopsRecording() {
        var coordinator = DictationTriggerCoordinator()
        _ = coordinator.press(at: 40)
        _ = coordinator.release(at: 40.1)
        _ = coordinator.press(at: 40.2)

        XCTAssertEqual(coordinator.press(at: 41), .stopRecording)
        XCTAssertEqual(coordinator.mode, .idle)
    }

    func testSecondPressBeforeReleaseAlsoLocks() {
        var coordinator = DictationTriggerCoordinator()

        XCTAssertEqual(coordinator.press(at: 50), .startRecording)
        XCTAssertEqual(coordinator.press(at: 50.1), .lockRecording)
        XCTAssertEqual(coordinator.release(at: 50.2), .none)
        XCTAssertEqual(coordinator.mode, .locked)
    }

    func testFailedStartResetPreventsNextPressBecomingLock() {
        var coordinator = DictationTriggerCoordinator()
        _ = coordinator.press(at: 60)
        coordinator.reset()

        XCTAssertEqual(coordinator.press(at: 60.1), .startRecording)
        XCTAssertEqual(coordinator.mode, .pushToTalk)
    }

    func testRapidRetryAfterCompletedDeferredStopStartsFreshRecording() {
        var coordinator = DictationTriggerCoordinator()
        _ = coordinator.press(at: 70)
        _ = coordinator.release(at: 70.05)
        XCTAssertEqual(coordinator.deferredStopFired(), .stopRecording)

        XCTAssertEqual(coordinator.press(at: 70.4), .startRecording)
        XCTAssertEqual(coordinator.mode, .pushToTalk)
    }

    func testThresholdBoundaryDefersButLongerHoldStopsImmediately() {
        var boundary = DictationTriggerCoordinator()
        _ = boundary.press(at: 80)
        guard case .deferStop(let delay) = boundary.release(at: 80.25) else {
            return XCTFail("Expected threshold boundary to defer")
        }
        XCTAssertEqual(delay, 0.10, accuracy: 0.0001)

        var longer = DictationTriggerCoordinator()
        _ = longer.press(at: 90)
        XCTAssertEqual(longer.release(at: 90.251), .stopRecording)
    }
}
