import Foundation

public enum DictationTriggerMode: String, Equatable, Sendable {
    case idle
    case pushToTalk
    case awaitingSecondTap
    case locked
}

public enum DictationTriggerAction: Equatable, Sendable {
    case none
    case startRecording
    case lockRecording
    case stopRecording
    case deferStop(seconds: TimeInterval)
}

public struct DictationTriggerCoordinator: Equatable, Sendable {
    public private(set) var mode: DictationTriggerMode = .idle
    public let doubleTapWindow: TimeInterval
    public let quickTapMaximum: TimeInterval

    private var pressStartedAt: TimeInterval?

    public init(
        doubleTapWindow: TimeInterval = 0.35,
        quickTapMaximum: TimeInterval = 0.25
    ) {
        self.doubleTapWindow = max(0, doubleTapWindow)
        self.quickTapMaximum = min(max(0, quickTapMaximum), max(0, doubleTapWindow))
    }

    public mutating func press(at time: TimeInterval) -> DictationTriggerAction {
        switch mode {
        case .idle:
            mode = .pushToTalk
            pressStartedAt = time
            return .startRecording
        case .pushToTalk, .awaitingSecondTap:
            mode = .locked
            pressStartedAt = nil
            return .lockRecording
        case .locked:
            reset()
            return .stopRecording
        }
    }

    public mutating func release(at time: TimeInterval) -> DictationTriggerAction {
        guard mode == .pushToTalk else { return .none }
        let heldFor = max(0, time - (pressStartedAt ?? time))
        pressStartedAt = nil

        if heldFor <= quickTapMaximum {
            let remaining = max(0, doubleTapWindow - heldFor)
            if remaining > 0 {
                mode = .awaitingSecondTap
                return .deferStop(seconds: remaining)
            }
        }

        mode = .idle
        return .stopRecording
    }

    public mutating func deferredStopFired() -> DictationTriggerAction {
        guard mode == .awaitingSecondTap else { return .none }
        mode = .idle
        return .stopRecording
    }

    public mutating func reset() {
        mode = .idle
        pressStartedAt = nil
    }
}
