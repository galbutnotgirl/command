import XCTest
@testable import ClaudeCommandCore

final class DictationTriggerCoordinatorTests: XCTestCase {
    private enum Operation: CaseIterable {
        case press
        case quickRelease
        case heldRelease
        case deferredStop
        case reset
    }

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

    func testEverySixStepTriggerSequencePreservesActionStateInvariants() {
        var sequence: [Operation] = []
        exerciseSequences(remaining: 6, sequence: &sequence)
    }

    private func exerciseSequences(remaining: Int, sequence: inout [Operation]) {
        if remaining == 0 {
            assertInvariants(for: sequence)
            return
        }
        for operation in Operation.allCases {
            sequence.append(operation)
            exerciseSequences(remaining: remaining - 1, sequence: &sequence)
            sequence.removeLast()
        }
    }

    private func assertInvariants(for sequence: [Operation], file: StaticString = #filePath, line: UInt = #line) {
        var coordinator = DictationTriggerCoordinator()
        var time: TimeInterval = 100

        for operation in sequence {
            let previousMode = coordinator.mode
            let action: DictationTriggerAction?
            switch operation {
            case .press:
                action = coordinator.press(at: time)
                time += 0.05
            case .quickRelease:
                action = coordinator.release(at: time)
                time += 0.10
            case .heldRelease:
                time += 0.40
                action = coordinator.release(at: time)
            case .deferredStop:
                action = coordinator.deferredStopFired()
                time += 0.05
            case .reset:
                coordinator.reset()
                action = nil
                time += 0.05
            }

            guard let action else {
                XCTAssertEqual(coordinator.mode, .idle, file: file, line: line)
                continue
            }
            switch action {
            case .startRecording:
                XCTAssertEqual(coordinator.mode, .pushToTalk, file: file, line: line)
                XCTAssertEqual(previousMode, .idle, file: file, line: line)
            case .lockRecording:
                XCTAssertEqual(coordinator.mode, .locked, file: file, line: line)
                XCTAssertTrue(
                    previousMode == .pushToTalk || previousMode == .awaitingSecondTap,
                    file: file,
                    line: line
                )
            case .stopRecording:
                XCTAssertEqual(coordinator.mode, .idle, file: file, line: line)
            case .deferStop(let delay):
                XCTAssertEqual(coordinator.mode, .awaitingSecondTap, file: file, line: line)
                XCTAssertGreaterThan(delay, 0, file: file, line: line)
                XCTAssertLessThanOrEqual(delay, coordinator.doubleTapWindow, file: file, line: line)
            case .none:
                XCTAssertEqual(coordinator.mode, previousMode, file: file, line: line)
            }
        }
    }
}
