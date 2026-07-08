import XCTest
@testable import ClaudeCommandCore

final class ActionModelsTests: XCTestCase {
    // ---- dual-ID trigger scheme -----------------------------------------------
    // The hotkey dispatcher (main.swift) parses this string to find both the
    // owning action and the exact trigger that fired — a wrong scheme here
    // silently routes a hotkey to the wrong (or no) trigger.

    func testActionIDEncodesBothActionAndTriggerID() {
        let ca = CustomAction.makeNew(name: "Summarize", prompt: "p", kind: .text)
        let trig = ca.triggers[0]
        XCTAssertEqual(ca.actionID(for: trig), "customtrigger:\(ca.id):\(trig.id)")
    }

    func testParseTriggerActionIDRoundTrips() {
        let ca = CustomAction.makeNew(name: "Summarize", prompt: "p", kind: .screenshot)
        let trig = ca.triggers[0]
        let parsed = parseTriggerActionID(ca.actionID(for: trig))
        XCTAssertEqual(parsed?.actionID, ca.id)
        XCTAssertEqual(parsed?.triggerID, trig.id)
    }

    func testParseTriggerActionIDRejectsUnrelatedStrings() {
        XCTAssertNil(parseTriggerActionID("custom:abc"))
        XCTAssertNil(parseTriggerActionID("dictate"))
        XCTAssertNil(parseTriggerActionID(""))
    }

    func testMakeNewSeedsExactlyOneTrigger() {
        let ca = CustomAction.makeNew(name: "n", prompt: "p", kind: .voice)
        XCTAssertEqual(ca.triggers.count, 1)
        XCTAssertEqual(ca.triggers[0].kind, .voice)
    }

    func testDefaultsAreNonHandoffText() {
        let ca = CustomAction.makeNew(name: "n", prompt: "p", kind: .text)
        XCTAssertFalse(ca.isHandoff)
        XCTAssertEqual(ca.triggers[0].kind, .text)
        XCTAssertEqual(ca.skill, "")
        XCTAssertTrue(ca.includeSource)
        XCTAssertEqual(ca.sessionMode, "new")
    }

    // ---- shared body, per-trigger overrides -----------------------------------

    func testTriggerWithNoOverrideInheritsActionDefault() {
        var ca = CustomAction.makeNew(name: "n", prompt: "p", kind: .text)
        ca.isAutoSubmit = true
        let trig = ca.triggers[0]
        XCTAssertTrue(ca.autoSubmit(for: trig))
    }

    func testTriggerOverrideWinsOverActionDefault() {
        var ca = CustomAction.makeNew(name: "n", prompt: "p", kind: .text)
        ca.isAutoSubmit = true
        var trig = ca.triggers[0]
        trig.isAutoSubmitOverride = false
        XCTAssertFalse(ca.autoSubmit(for: trig))
    }

    func testSessionModeAndIncludeSourceOverridesAreIndependent() {
        var ca = CustomAction.makeNew(name: "n", prompt: "p", kind: .text)
        ca.sessionMode = "new"; ca.includeSource = true
        var trig = ca.triggers[0]
        trig.sessionModeOverride = "add"
        XCTAssertEqual(ca.effectiveSessionMode(for: trig), "add")
        XCTAssertTrue(ca.shouldIncludeSource(for: trig))  // untouched — still inherits
    }

    // ---- CommandAction catalog lookups ---------------------------------------

    func testActionNameFallsBackToIDWhenUnknown() {
        XCTAssertEqual(actionName("not-a-real-action"), "not-a-real-action")
    }

    func testActionNameKnownID() {
        XCTAssertEqual(actionName("cliphistory"), "Clipboard History")
    }

    func testFixedCatalogHasNoHandoffActionsLeft() {
        // Skill/Screenshot Handoff, and now Text Handoff too, were folded into
        // user-configurable Custom Actions (kind: .popup for the old Text
        // Handoff) — none of the fixed catalog entries should be handoffs.
        XCTAssertFalse(COMMAND_ACTIONS.contains { $0.id.lowercased().contains("handoff") })
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
