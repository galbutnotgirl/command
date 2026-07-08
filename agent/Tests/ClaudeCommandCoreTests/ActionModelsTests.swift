import XCTest
@testable import ClaudeCommandCore

final class ActionModelsTests: XCTestCase {
    // ---- CustomAction.actionID ----------------------------------------------
    // The hotkey dispatcher (main.swift) branches purely on this string prefix,
    // so a wrong prefix here silently routes a custom action to the wrong path.

    func testPlainCustomActionID() {
        let ca = CustomAction.makeNew(name: "Summarize", prompt: "p", kind: .text)
        XCTAssertEqual(ca.actionID, "custom:\(ca.id)")
    }

    func testScreenshotCustomActionIDSharesPlainPrefix() {
        // Screenshot vs text is read from .kind at dispatch time, not encoded
        // in the actionID — only voice (press/hold semantics) and handoff
        // (delivery) change the prefix.
        let ca = CustomAction.makeNew(name: "Screenshot it", prompt: "p", kind: .screenshot)
        XCTAssertEqual(ca.actionID, "custom:\(ca.id)")
    }

    func testPopupCustomActionIDSharesPlainPrefix() {
        let ca = CustomAction.makeNew(name: "Popup it", prompt: "p", kind: .popup)
        XCTAssertEqual(ca.actionID, "custom:\(ca.id)")
    }

    func testTextHandoffActionID() {
        let ca = CustomAction.makeNew(name: "Triage", prompt: "p", kind: .text, isHandoff: true, skill: "triage")
        XCTAssertEqual(ca.actionID, "customhandoff:\(ca.id)")
    }

    func testScreenshotHandoffActionIDSharesHandoffPrefix() {
        let ca = CustomAction.makeNew(name: "Triage shot", prompt: "p", kind: .screenshot, isHandoff: true, skill: "triage")
        XCTAssertEqual(ca.actionID, "customhandoff:\(ca.id)")
    }

    func testVoiceCustomActionIDGetsItsOwnPrefix() {
        // Voice needs the press/hold/double-tap trigger machinery, not a
        // fire-on-press dispatch — hence a distinct prefix so main.swift's
        // hotKeyHandler can route it to triggerDictation() instead.
        let ca = CustomAction.makeNew(name: "Dictate task", prompt: "p", kind: .voice)
        XCTAssertEqual(ca.actionID, "customvoice:\(ca.id)")
    }

    func testVoiceHandoffCustomActionIDCombinesBothPrefixes() {
        let ca = CustomAction.makeNew(name: "Dictate task", prompt: "p", kind: .voice, isHandoff: true)
        XCTAssertEqual(ca.actionID, "customvoicehandoff:\(ca.id)")
    }

    func testDefaultsAreNonHandoffText() {
        let ca = CustomAction.makeNew(name: "n", prompt: "p", kind: .text)
        XCTAssertFalse(ca.isHandoff)
        XCTAssertEqual(ca.kind, .text)
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
