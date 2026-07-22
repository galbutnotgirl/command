import XCTest
import AppKit
@testable import ClaudeCommandCore

final class KeyCodesTests: XCTestCase {
    func testUnboundKeycodeIsQuestionMark() {
        // keycode 0 is 'A' in the map (not "unbound" — that's HotkeyBinding's
        // job to represent as "—"), so humanShortcut itself always resolves
        // known keycodes, falling back to "?" only for truly unknown ones.
        XCTAssertEqual(humanShortcut(keycode: 999, mods: 0), "?")
    }

    func testPlainKeyNoModifiers() {
        XCTAssertEqual(humanShortcut(keycode: 100, mods: 0), "F8")
    }

    func testModifierOrderIsControlOptionShiftCommand() {
        // CARBON_MODS is ordered ⌃⌥⇧⌘ regardless of which bits are set — the
        // display should always read in that fixed order.
        let allMods: UInt32 = 4096 | 2048 | 512 | 256
        XCTAssertEqual(humanShortcut(keycode: 100, mods: allMods), "⌃⌥⇧⌘F8")
    }

    func testSingleModifier() {
        XCTAssertEqual(humanShortcut(keycode: 98, mods: 2048), "⌥F7")
    }

    func testModifierOnlyKeysDisplayByName() {
        XCTAssertEqual(humanShortcut(keycode: 55, mods: 0), "Command")
        XCTAssertEqual(humanShortcut(keycode: 58, mods: 0), "Option")
        XCTAssertEqual(humanShortcut(keycode: 63, mods: 0), "Fn")
        XCTAssertTrue(MODIFIER_ONLY_KEYCODES.contains(55))
        XCTAssertTrue(MODIFIER_ONLY_KEYCODES.contains(58))
        XCTAssertTrue(MODIFIER_ONLY_KEYCODES.contains(63))
    }

    func testCarbonModsFromCocoaFlagsRoundTrips() {
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertEqual(carbonMods(from: flags), 256 | 512)
    }

    func testCarbonModsEmpty() {
        XCTAssertEqual(carbonMods(from: []), 0)
    }

    func testFnArrowNavigationMapsToDistinctNavigationKeys() {
        XCTAssertEqual(fnNavigationKeycode(sourceKeycode: 123, functionPressed: true), 115)
        XCTAssertEqual(fnNavigationKeycode(sourceKeycode: 124, functionPressed: true), 119)
        XCTAssertEqual(fnNavigationKeycode(sourceKeycode: 126, functionPressed: true), 116)
        XCTAssertEqual(fnNavigationKeycode(sourceKeycode: 125, functionPressed: true), 121)
    }

    func testPlainLeftArrowNeverBecomesHome() {
        XCTAssertNil(fnNavigationKeycode(sourceKeycode: 123, functionPressed: false))
        XCTAssertNotEqual(UInt32(123), fnNavigationKeycode(sourceKeycode: 123, functionPressed: true))
    }

    func testEventTapOwnsOnlyModifierAndMediaVoiceKeys() {
        XCTAssertTrue(eventTapOwnsVoiceHotkey(keycode: 63))
        XCTAssertTrue(eventTapOwnsVoiceHotkey(keycode: 100))
        XCTAssertFalse(eventTapOwnsVoiceHotkey(keycode: 115))
        XCTAssertFalse(eventTapOwnsVoiceHotkey(keycode: 123))
    }
}
