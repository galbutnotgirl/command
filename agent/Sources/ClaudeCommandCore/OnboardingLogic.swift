public enum OnboardingResumeStep: Equatable, Sendable {
    case welcome
    case accessibility
    case screenRecording
    case microphone
    case clipboard
    case done
}

public struct OnboardingProgress: Equatable, Sendable {
    public var primaryAssistantSelected: Bool
    public var accessibilityGranted: Bool
    public var screenRecordingGranted: Bool
    public var microphoneStepCompleted: Bool
    public var clipboardStepCompleted: Bool

    public init(
        primaryAssistantSelected: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        microphoneStepCompleted: Bool,
        clipboardStepCompleted: Bool
    ) {
        self.primaryAssistantSelected = primaryAssistantSelected
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.microphoneStepCompleted = microphoneStepCompleted
        self.clipboardStepCompleted = clipboardStepCompleted
    }

    public var resumeStep: OnboardingResumeStep {
        guard primaryAssistantSelected else { return .welcome }
        guard accessibilityGranted else { return .accessibility }
        guard screenRecordingGranted else { return .screenRecording }
        guard microphoneStepCompleted else { return .microphone }
        guard clipboardStepCompleted else { return .clipboard }
        return .done
    }
}

public enum InitialWindowRoute: Equatable, Sendable {
    case onboarding
    case shortcuts
    case setup
    case none

    public var consumesPostOnboardingShortcutRequest: Bool {
        self == .shortcuts
    }
}

public func initialWindowRoute(
    onboardingCompleted: Bool,
    postOnboardingOpenShortcuts: Bool,
    accessibilityGranted: Bool,
    screenRecordingGranted: Bool
) -> InitialWindowRoute {
    guard onboardingCompleted else { return .onboarding }
    if postOnboardingOpenShortcuts { return .shortcuts }
    guard accessibilityGranted, screenRecordingGranted else { return .setup }
    return .none
}
