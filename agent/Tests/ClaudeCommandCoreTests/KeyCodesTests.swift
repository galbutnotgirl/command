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
        XCTAssertTrue(MODIFIER_ONLY_KEYCODES.contains(55))
        XCTAssertTrue(MODIFIER_ONLY_KEYCODES.contains(58))
    }

    func testCarbonModsFromCocoaFlagsRoundTrips() {
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertEqual(carbonMods(from: flags), 256 | 512)
    }

    func testCarbonModsEmpty() {
        XCTAssertEqual(carbonMods(from: []), 0)
    }
}
