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
        ca.destination = .chat
        let trig = ca.triggers[0]
        XCTAssertEqual(ca.effectiveDelivery(for: trig), .existingChat)
        XCTAssertEqual(ca.effectiveDestination(for: trig), .chat)
    }

    func testLegacyCoworkDestinationsCanonicalizeToCombinedChatSurface() {
        var trigger = ActionTrigger(kind: .text, destinationOverride: .cowork)
        XCTAssertEqual(trigger.destinationOverride, .chat)
        trigger.destinationOverride = .cowork

        let action = CustomAction(
            id: "legacy", name: "Legacy", prompt: "p", isAutoSubmit: false,
            sessionMode: "new", includeSource: true, enabled: true,
            destination: .cowork, triggers: [trigger]
        )
        XCTAssertEqual(action.destination, .chat)
        XCTAssertEqual(action.effectiveDestination(for: trigger), .chat)
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
        XCTAssertEqual(byAction["add"]?.mods, 0)
        XCTAssertEqual(byAction["comment"]?.keycode, 100)
        XCTAssertEqual(byAction["comment"]?.mods, 256)
        XCTAssertEqual(byAction["shotadd"]?.keycode, 98)
        XCTAssertEqual(byAction["shotadd"]?.mods, 0)
        XCTAssertEqual(byAction["shotcomment"]?.keycode, 98)
        XCTAssertEqual(byAction["shotcomment"]?.mods, 256)
        XCTAssertEqual(byAction["cliphistory"]?.keycode, 97)
        XCTAssertEqual(byAction["cliphistory"]?.mods, 0)
        XCTAssertEqual(byAction["dictate"]?.keycode, 63)
        XCTAssertEqual(byAction["dictate"]?.mods, 0)
        XCTAssertEqual(byAction["dictateadd"]?.keycode, 0)
        XCTAssertEqual(byAction["dictateadd"]?.mods, 0)
        XCTAssertEqual(byAction["dictateadd2"]?.keycode, 0)
        XCTAssertEqual(byAction["dictateadd2"]?.mods, 0)
    }

    func testNewUserDefaultsDoNotCollideWhenBound() {
        var seen = Set<String>()
        for binding in DEFAULT_BINDINGS where binding.keycode != 0 {
            let key = "\(binding.keycode):\(binding.mods)"
            XCTAssertFalse(seen.contains(key), "Duplicate default shortcut \(key)")
            seen.insert(key)
        }
    }

    func testExperimentalDefaultsAreEligibleForOneTimeMigration() {
        let bindings = Dictionary(uniqueKeysWithValues: COMMAND_ACTIONS.map { action in
            let value = EXPERIMENTAL_DEFAULT_BINDINGS[action.id] ?? (0, 0)
            return (action.id, HotkeyBinding(action: action.id, keycode: value.keycode, mods: value.mods, enabled: true))
        })
        XCTAssertTrue(bindingsMatchExperimentalDefaults(bindings))
    }

    func testCustomizedExperimentalBindingIsNeverMigrated() {
        var bindings = Dictionary(uniqueKeysWithValues: COMMAND_ACTIONS.map { action in
            let value = EXPERIMENTAL_DEFAULT_BINDINGS[action.id] ?? (0, 0)
            return (action.id, HotkeyBinding(action: action.id, keycode: value.keycode, mods: value.mods, enabled: true))
        })
        bindings["dictate"] = HotkeyBinding(action: "dictate", keycode: 63, mods: 0, enabled: true)
        XCTAssertFalse(bindingsMatchExperimentalDefaults(bindings))
    }

    func testExperimentalPrimaryWithAlternateBindingIsNeverMigrated() {
        var bindings = Dictionary(uniqueKeysWithValues: COMMAND_ACTIONS.map { action in
            let value = EXPERIMENTAL_DEFAULT_BINDINGS[action.id] ?? (0, 0)
            return (action.id, HotkeyBinding(action: action.id, keycode: value.keycode, mods: value.mods, enabled: true))
        })
        bindings["add"] = HotkeyBinding(action: "add", shortcuts: [
            HotkeyShortcut(keycode: 109, mods: 0),
            HotkeyShortcut(keycode: 115, mods: 0),
        ], enabled: true)
        XCTAssertFalse(bindingsMatchExperimentalDefaults(bindings))
    }

    func testUnknownActionPreventsExperimentalMigration() {
        let unknown = HotkeyBinding(action: "future-action", keycode: 1, mods: 0, enabled: true)
        XCTAssertFalse(bindingsMatchExperimentalDefaults([unknown.action: unknown]))
    }

    func testAutoSubmitDefaultsStayUnboundForNewUsers() {
        let byAction = Dictionary(uniqueKeysWithValues: DEFAULT_BINDINGS.map { ($0.action, (keycode: $0.keycode, mods: $0.mods)) })
        XCTAssertEqual(byAction["go"]?.keycode, 0)
        XCTAssertEqual(byAction["shotgo"]?.keycode, 0)
        XCTAssertEqual(byAction["dictateadd2"]?.keycode, 0)
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

    func testTwoHotkeysDisplayInStableOrder() {
        let b = HotkeyBinding(action: "add", shortcuts: [
            HotkeyShortcut(keycode: 100, mods: 0),
            HotkeyShortcut(keycode: 115, mods: 0),
        ], enabled: true)
        XCTAssertEqual(b.human, "F8 / Home")
        XCTAssertEqual(b.keycode, 100)
        XCTAssertEqual(b.mods, 0)
    }

    func testShortcutNormalizationDropsUnboundDuplicatesAndThirdAlias() {
        XCTAssertEqual(normalizedShortcuts([
            HotkeyShortcut(keycode: 0, mods: 0),
            HotkeyShortcut(keycode: 115, mods: 0),
            HotkeyShortcut(keycode: 115, mods: 0),
            HotkeyShortcut(keycode: 119, mods: 0),
            HotkeyShortcut(keycode: 100, mods: 0),
        ]), [
            HotkeyShortcut(keycode: 115, mods: 0),
            HotkeyShortcut(keycode: 119, mods: 0),
        ])
    }

    func testLegacyShortcutDecodeAndDualWriteEncoding() {
        XCTAssertEqual(decodeShortcutFields(["keycode": 115, "mods": 0]), [
            HotkeyShortcut(keycode: 115, mods: 0),
        ])
        let encoded = encodeShortcutFields([
            HotkeyShortcut(keycode: 100, mods: 0),
            HotkeyShortcut(keycode: 115, mods: 256),
        ])
        XCTAssertEqual(encoded["keycode"] as? Int, 100)
        XCTAssertEqual(encoded["mods"] as? Int, 0)
        let aliases = encoded["shortcuts"] as? [[String: Int]]
        XCTAssertEqual(aliases?[1]["keycode"], 115)
        XCTAssertEqual(aliases?[1]["mods"], 256)
    }

    func testShortcutArrayDecodeTakesPriorityOverLegacyFields() {
        let decoded = decodeShortcutFields([
            "keycode": 100,
            "mods": 0,
            "shortcuts": [
                ["keycode": 115, "mods": 0],
                ["keycode": 119, "mods": 2048],
                ["keycode": 98, "mods": 0],
            ],
        ])
        XCTAssertEqual(decoded, [
            HotkeyShortcut(keycode: 115, mods: 0),
            HotkeyShortcut(keycode: 119, mods: 2048),
        ])
    }

    func testConflictDetectionRejectsOtherOwnerAndDuplicateAlias() {
        let home = HotkeyShortcut(keycode: 115, mods: 0)
        let assignments = [
            ShortcutAssignment(ownerID: "add", slot: 0, shortcut: HotkeyShortcut(keycode: 100, mods: 0)),
            ShortcutAssignment(ownerID: "add", slot: 1, shortcut: home),
        ]
        XCTAssertEqual(
            conflictingShortcutAssignment(ownerID: "comment", slot: 0, candidate: home,
                                          assignments: assignments)?.ownerID,
            "add"
        )
        XCTAssertEqual(
            conflictingShortcutAssignment(ownerID: "add", slot: 0, candidate: home,
                                          assignments: assignments)?.slot,
            1
        )
        XCTAssertNil(conflictingShortcutAssignment(ownerID: "add", slot: 1, candidate: home,
                                                    assignments: assignments))
    }

    func testResetRestoresPrimaryDefaultAndRemovesAlternate() {
        let changed = HotkeyBinding(action: "add", shortcuts: [
            HotkeyShortcut(keycode: 115, mods: 0),
            HotkeyShortcut(keycode: 119, mods: 0),
        ], enabled: true)
        let reset = resettingShortcutBindings([changed], actions: ["add"])
        XCTAssertEqual(reset[0].shortcuts, [HotkeyShortcut(keycode: 100, mods: 0)])
        XCTAssertTrue(reset[0].enabled)
    }

    func testOnlyEnabledBoundHotkeysAreVisibleInMenu() {
        XCTAssertTrue(HotkeyBinding(action: "add", keycode: 100, mods: 0, enabled: true).isVisibleInMenu)
        XCTAssertFalse(HotkeyBinding(action: "go", keycode: 0, mods: 0, enabled: true).isVisibleInMenu)
        XCTAssertFalse(HotkeyBinding(action: "add", keycode: 100, mods: 0, enabled: false).isVisibleInMenu)
    }
}
