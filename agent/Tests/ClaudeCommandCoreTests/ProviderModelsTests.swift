import XCTest
@testable import ClaudeCommandCore

final class ProviderModelsTests: XCTestCase {
    func testProviderChoiceResolutionOrderInputs() {
        XCTAssertEqual(AIProviderChoice.default.resolve(default: .claude), .claude)
        XCTAssertEqual(AIProviderChoice.default.resolve(default: .codex), .codex)
        XCTAssertEqual(AIProviderChoice.claude.resolve(default: .codex), .claude)
    }

    func testCustomActionProviderInheritanceAndTriggerOverride() {
        var action = CustomAction.makeNew(name: "n", prompt: "p", kind: .text)
        action.provider = .codex
        var trigger = action.triggers[0]
        XCTAssertEqual(action.effectiveProvider(for: trigger, default: .claude), .codex)
        trigger.providerOverride = .claude
        XCTAssertEqual(action.effectiveProvider(for: trigger, default: .codex), .claude)
    }

    func testCapabilitiesAreProviderSpecific() {
        XCTAssertTrue(ProviderCapabilities(provider: .claude).destinations)
        XCTAssertFalse(ProviderCapabilities(provider: .claude).workspace)
        XCTAssertTrue(ProviderCapabilities(provider: .codex).destinations)
        XCTAssertTrue(ProviderCapabilities(provider: .codex).workspace)
        XCTAssertEqual(AIProvider.codex.label, "ChatGPT")
        XCTAssertEqual(ClaudeDestination.available(for: .claude), [.default, .recent, .chat, .cowork, .code])
        XCTAssertEqual(ClaudeDestination.available(for: .codex), [.default, .chat, .code])
        XCTAssertFalse(ClaudeDestination.available(for: .codex).contains(.cowork))
        XCTAssertEqual(ClaudeDestination.chat.label(for: .codex), "Chat")
        XCTAssertEqual(ClaudeDestination.code.label(for: .codex), "Codex")
        XCTAssertEqual(ClaudeDestination.chat.label(for: .claude), "Chat")
    }

    func testSkillInvocationSyntax() {
        XCTAssertEqual(AIProvider.claude.skillInvocation("/triage"), "/triage")
        XCTAssertEqual(AIProvider.codex.skillInvocation("$triage"), "$triage")
    }

    func testCodexExecutionPresetsNeverUseDangerFullAccess() {
        for preset in CodexExecutionPreset.allCases {
            XCTAssertFalse(preset.arguments.contains("danger-full-access"))
            XCTAssertFalse(preset.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        }
    }

    func testPrimaryAssistantPreferenceMapsToProviderAndDestination() {
        XCTAssertEqual(PrimaryAssistantPreference.claude.provider, .claude)
        XCTAssertEqual(PrimaryAssistantPreference.claude.destination, .recent)
        XCTAssertEqual(PrimaryAssistantPreference.chatgpt.provider, .codex)
        XCTAssertEqual(PrimaryAssistantPreference.chatgpt.destination, .chat)
        XCTAssertEqual(PrimaryAssistantPreference.codex.provider, .codex)
        XCTAssertEqual(PrimaryAssistantPreference.codex.destination, .code)
    }

    func testRecentIsClaudeOnlyAndFirstExplicitDestination() {
        XCTAssertEqual(ClaudeDestination.available(for: .claude, includeDefault: false).first, .recent)
        XCTAssertFalse(ClaudeDestination.available(for: .codex).contains(.recent))
        XCTAssertEqual(ClaudeDestination.recent.label(for: .claude), "Recent")
    }
}
