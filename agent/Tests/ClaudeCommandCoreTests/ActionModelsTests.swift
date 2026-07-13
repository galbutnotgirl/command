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

    func testDeliveryAndDestinationInheritFromAction() {
        var ca = CustomAction.makeNew(name: "n", prompt: "p", kind: .text)
        ca.delivery = .existingChat
        ca.destination = .cowork
        let trig = ca.triggers[0]
        XCTAssertEqual(ca.effectiveDelivery(for: trig), .existingChat)
        XCTAssertEqual(ca.effectiveDestination(for: trig), .cowork)
    }

    func testTriggerDeliveryAndDestinationOverridesWin() {
        var ca = CustomAction.makeNew(name: "n", prompt: "p", kind: .text)
        ca.delivery = .newChat
        ca.destination = .chat
        var trig = ca.triggers[0]
        trig.deliveryOverride = .background
        trig.destinationOverride = .code
        XCTAssertEqual(ca.effectiveDelivery(for: trig), .background)
        XCTAssertEqual(ca.effectiveDestination(for: trig), .code)
    }

    func testLegacyDeliveryMapping() {
        XCTAssertEqual(ActionDelivery.fromLegacy(isHandoff: true, sessionMode: "new"), .background)
        XCTAssertEqual(ActionDelivery.fromLegacy(isHandoff: false, sessionMode: "add"), .existingChat)
        XCTAssertEqual(ActionDelivery.fromLegacy(isHandoff: false, sessionMode: "new"), .newChat)
    }

    // ---- CommandAction catalog lookups ---------------------------------------

    func testActionNameFallsBackToIDWhenUnknown() {
        XCTAssertEqual(actionName("not-a-real-action"), "not-a-real-action")
    }

    func testActionNameKnownID() {
        XCTAssertEqual(actionName("cliphistory"), "Clipboard History")
    }

    func testFixedCatalogHasNoHandoffActionsLeft() {
        // Old fixed background actions were folded into user-configurable Custom
        // Actions (kind: .popup for the old text-entry path) — none of the fixed
        // catalog entries should be handoffs.
        XCTAssertFalse(COMMAND_ACTIONS.contains { $0.id.lowercased().contains("handoff") })
    }

    func testEveryDefaultBindingReferencesARealCatalogAction() {
        let ids = Set(COMMAND_ACTIONS.map(\.id))
        for def in DEFAULT_BINDINGS {
            XCTAssertTrue(ids.contains(def.action), "DEFAULT_BINDINGS has an action not in COMMAND_ACTIONS: \(def.action)")
        }
    }

    func testNewUserDefaultsUseMacFunctionRowKeys() {
        let byAction = Dictionary(uniqueKeysWithValues: DEFAULT_BINDINGS.map { ($0.action, (keycode: $0.keycode, mods: $0.mods)) })
        XCTAssertEqual(byAction["add"]?.keycode, 100)
        XCTAssertEqual(byAction["add"]?.mods, 2048)
        XCTAssertEqual(byAction["comment"]?.keycode, 100)
        XCTAssertEqual(byAction["comment"]?.mods, 0)
        XCTAssertEqual(byAction["shotadd"]?.keycode, 98)
        XCTAssertEqual(byAction["shotadd"]?.mods, 2048)
        XCTAssertEqual(byAction["shotcomment"]?.keycode, 98)
        XCTAssertEqual(byAction["shotcomment"]?.mods, 0)
        XCTAssertEqual(byAction["cliphistory"]?.keycode, 97)
        XCTAssertEqual(byAction["cliphistory"]?.mods, 0)
        XCTAssertEqual(byAction["dictate"]?.keycode, 115)
        XCTAssertEqual(byAction["dictate"]?.mods, 0)
        XCTAssertEqual(byAction["dictateadd"]?.keycode, 115)
        XCTAssertEqual(byAction["dictateadd"]?.mods, 2048)
    }

    func testNewUserDefaultsDoNotCollideWhenBound() {
        var seen = Set<String>()
        for binding in DEFAULT_BINDINGS where binding.keycode != 0 {
            let key = "\(binding.keycode):\(binding.mods)"
            XCTAssertFalse(seen.contains(key), "Duplicate default shortcut \(key)")
            seen.insert(key)
        }
    }

    func testAutoSubmitDefaultsStayUnboundForNewUsers() {
        let byAction = Dictionary(uniqueKeysWithValues: DEFAULT_BINDINGS.map { ($0.action, (keycode: $0.keycode, mods: $0.mods)) })
        XCTAssertEqual(byAction["go"]?.keycode, 0)
        XCTAssertEqual(byAction["shotgo"]?.keycode, 0)
    }

    // ---- HotkeyBinding.human -------------------------------------------------

    func testUnboundHotkeyDisplaysAsDash() {
        let b = HotkeyBinding(action: "go", keycode: 0, mods: 0, enabled: true)
        XCTAssertEqual(b.human, "—")
    }

    func testBoundHotkeyDisplaysShortcut() {
        let b = HotkeyBinding(action: "add", keycode: 100, mods: 2048, enabled: true)
        XCTAssertEqual(b.human, "⌥F8")
    }
}
