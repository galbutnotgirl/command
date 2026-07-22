import XCTest
@testable import ClaudeCommandCore

final class AssistantShortcutsTests: XCTestCase {
    func testNewTaskUsesCommandN() {
        XCTAssertEqual(
            assistantShortcut(forSocketCommand: "newtask"),
            AssistantAppShortcut(keycode: 45, command: true)
        )
    }

    func testQuickChatUsesCommandOptionN() {
        XCTAssertEqual(
            assistantShortcut(forSocketCommand: "newchat"),
            AssistantAppShortcut(keycode: 45, command: true, option: true)
        )
    }

    func testProjectlessCodexUsesCommandOptionO() {
        XCTAssertEqual(
            assistantShortcut(forSocketCommand: "newprojectless"),
            AssistantAppShortcut(keycode: 31, command: true, option: true)
        )
    }

    func testUnknownSocketCommandHasNoShortcut() {
        XCTAssertNil(assistantShortcut(forSocketCommand: "unknown"))
    }
}
