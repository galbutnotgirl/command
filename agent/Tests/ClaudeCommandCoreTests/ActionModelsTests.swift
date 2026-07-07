import XCTest
@testable import ClaudeCommandCore

final class ActionModelsTests: XCTestCase {
    // ---- CustomAction.actionID ----------------------------------------------
    // The hotkey dispatcher (main.swift) branches purely on this string prefix,
    // so a wrong prefix here silently routes a custom action to the wrong path.

    func testPlainCustomActionID() {
        let ca = CustomAction.makeNew(name: "Summarize", prompt: "p", isShot: false)
        XCTAssertEqual(ca.actionID, "custom:\(ca.id)")
    }

    func testScreenshotCustomActionID() {
        let ca = CustomAction.makeNew(name: "Screenshot it", prompt: "p", isShot: true)
        XCTAssertEqual(ca.actionID, "customshot:\(ca.id)")
    }

    func testTextHandoffActionID() {
        let ca = CustomAction.makeNew(name: "Triage", prompt: "p", isShot: false, isHandoff: true, skill: "triage")
        XCTAssertEqual(ca.actionID, "customhandoff:\(ca.id)")
    }

    func testScreenshotHandoffActionID() {
        let ca = CustomAction.makeNew(name: "Triage shot", prompt: "p", isShot: true, isHandoff: true, skill: "triage")
        XCTAssertEqual(ca.actionID, "customshothandoff:\(ca.id)")
    }

    func testDefaultsAreNonHandoffNonShot() {
        let ca = CustomAction.makeNew(name: "n", prompt: "p", isShot: false)
        XCTAssertFalse(ca.isHandoff)
        XCTAssertEqual(ca.skill, "")
        XCTAssertTrue(ca.includeSource)
        XCTAssertEqual(ca.sessionMode, "new")
    }

    // ---- CommandAction catalog lookups ---------------------------------------

    func testActionNameFallsBackToIDWhenUnknown() {
        XCTAssertEqual(actionName("not-a-real-action"), "not-a-real-action")
    }

    func testActionNameKnownID() {
        XCTAssertEqual(actionName("cliphistory"), "Clipboard History")
    }

    func testHandoffTextIsInHandoffActionIDs() {
        XCTAssertTrue(HANDOFF_ACTION_IDS.contains("handofftext"))
        // The old fixed Skill/Screenshot Handoff actions were folded into
        // user-configurable Custom Actions — they must not reappear here.
        XCTAssertFalse(HANDOFF_ACTION_IDS.contains("handoff"))
        XCTAssertFalse(HANDOFF_ACTION_IDS.contains("shothandoff"))
    }

    func testEveryDefaultBindingReferencesARealCatalogAction() {
        let ids = Set(COMMAND_ACTIONS.map(\.id))
        for def in DEFAULT_BINDINGS {
            XCTAssertTrue(ids.contains(def.action), "DEFAULT_BINDINGS has an action not in COMMAND_ACTIONS: \(def.action)")
        }
    }

    // ---- HotkeyBinding.human -------------------------------------------------

    func testUnboundHotkeyDisplaysAsDash() {
        let b = HotkeyBinding(action: "go", keycode: 0, mods: 0, enabled: true)
        XCTAssertEqual(b.human, "—")
    }

    func testBoundHotkeyDisplaysShortcut() {
        let b = HotkeyBinding(action: "add", keycode: 100, mods: 0, enabled: true)
        XCTAssertEqual(b.human, "F8")
    }
}
