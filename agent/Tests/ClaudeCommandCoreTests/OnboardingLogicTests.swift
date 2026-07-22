import XCTest
@testable import ClaudeCommandCore

final class OnboardingLogicTests: XCTestCase {
    func testFreshInstallStartsAtWelcomeEvenWhenSystemPermissionsAlreadyExist() {
        let progress = OnboardingProgress(
            primaryAssistantSelected: false,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            microphoneStepCompleted: false,
            clipboardStepCompleted: false
        )
        XCTAssertEqual(progress.resumeStep, .welcome)
    }

    func testResumeStopsAtFirstIncompletePermissionOrChoice() {
        XCTAssertEqual(progress(false, false, false, false).resumeStep, .accessibility)
        XCTAssertEqual(progress(true, false, false, false).resumeStep, .screenRecording)
        XCTAssertEqual(progress(true, true, false, false).resumeStep, .microphone)
        XCTAssertEqual(progress(true, true, true, false).resumeStep, .clipboard)
        XCTAssertEqual(progress(true, true, true, true).resumeStep, .done)
    }

    func testLaterCompletionFlagsNeverSkipEarlierRequiredStep() {
        let progress = OnboardingProgress(
            primaryAssistantSelected: true,
            accessibilityGranted: false,
            screenRecordingGranted: true,
            microphoneStepCompleted: true,
            clipboardStepCompleted: true
        )
        XCTAssertEqual(progress.resumeStep, .accessibility)
    }

    func testIncompleteOnboardingAlwaysShowsWizard() {
        XCTAssertEqual(
            initialWindowRoute(
                onboardingCompleted: false,
                postOnboardingOpenShortcuts: true,
                accessibilityGranted: false,
                screenRecordingGranted: false
            ),
            .onboarding
        )
    }

    func testCompletionRestartOpensShortcutsBeforePermissionFallback() {
        let route = initialWindowRoute(
            onboardingCompleted: true,
            postOnboardingOpenShortcuts: true,
            accessibilityGranted: false,
            screenRecordingGranted: false
        )
        XCTAssertEqual(route, .shortcuts)
        XCTAssertTrue(route.consumesPostOnboardingShortcutRequest)
    }

    func testMissingRequiredPermissionOpensSetup() {
        XCTAssertEqual(
            initialWindowRoute(
                onboardingCompleted: true,
                postOnboardingOpenShortcuts: false,
                accessibilityGranted: false,
                screenRecordingGranted: true
            ),
            .setup
        )
        XCTAssertEqual(
            initialWindowRoute(
                onboardingCompleted: true,
                postOnboardingOpenShortcuts: false,
                accessibilityGranted: true,
                screenRecordingGranted: false
            ),
            .setup
        )
    }

    func testHealthySubsequentLaunchStaysMenuBarOnly() {
        let route = initialWindowRoute(
            onboardingCompleted: true,
            postOnboardingOpenShortcuts: false,
            accessibilityGranted: true,
            screenRecordingGranted: true
        )
        XCTAssertEqual(route, .none)
        XCTAssertFalse(route.consumesPostOnboardingShortcutRequest)
    }

    private func progress(
        _ accessibility: Bool,
        _ screenRecording: Bool,
        _ microphone: Bool,
        _ clipboard: Bool
    ) -> OnboardingProgress {
        OnboardingProgress(
            primaryAssistantSelected: true,
            accessibilityGranted: accessibility,
            screenRecordingGranted: screenRecording,
            microphoneStepCompleted: microphone,
            clipboardStepCompleted: clipboard
        )
    }
}
