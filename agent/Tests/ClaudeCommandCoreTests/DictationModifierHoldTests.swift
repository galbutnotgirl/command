import XCTest
@testable import ClaudeCommandCore

final class DictationModifierHoldTests: XCTestCase {
    func testControlFnStopsWhenControlReleasesFirst() {
        let hold = DictationModifierHold(keycode: 63, requiredModifiers: 4096)
        XCTAssertTrue(hold.isHeld(primaryIsDown: true, activeModifiers: 4096))
        XCTAssertFalse(hold.isHeld(primaryIsDown: true, activeModifiers: 0))
    }
    func testControlFnStopsWhenFnReleasesFirst() {
        let hold = DictationModifierHold(keycode: 63, requiredModifiers: 4096)
        XCTAssertFalse(hold.isHeld(primaryIsDown: false, activeModifiers: 4096))
    }
    func testExtraModifiersDoNotReleaseOrChangeOriginalChord() {
        let hold = DictationModifierHold(keycode: 63, requiredModifiers: 4096)
        XCTAssertTrue(hold.isHeld(primaryIsDown: true, activeModifiers: 4096 | 512))
        XCTAssertTrue(hold.isHeld(primaryIsDown: true, activeModifiers: 4096))
        XCTAssertFalse(hold.isHeld(primaryIsDown: true, activeModifiers: 512))
    }
    func testPlainFnAndCommandFnKeepTheirOwnReleaseRules() {
        XCTAssertTrue(DictationModifierHold(keycode: 63, requiredModifiers: 0).isHeld(primaryIsDown: true, activeModifiers: 4096))
        XCTAssertFalse(DictationModifierHold(keycode: 63, requiredModifiers: 0).isHeld(primaryIsDown: false, activeModifiers: 0))
        XCTAssertFalse(DictationModifierHold(keycode: 63, requiredModifiers: 256).isHeld(primaryIsDown: true, activeModifiers: 4096))
    }
}
