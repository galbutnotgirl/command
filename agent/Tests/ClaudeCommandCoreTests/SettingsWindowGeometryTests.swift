import XCTest
@testable import ClaudeCommandCore

final class SettingsWindowGeometryTests: XCTestCase {
    func testLargeScreenUsesPreferredContentSize() {
        XCTAssertEqual(
            SettingsWindowGeometry.initialContentSize(visibleWidth: 1728, visibleHeight: 1080),
            SettingsWindowGeometry.preferred
        )
    }

    func testShortScreenLeavesVisibleMargin() {
        XCTAssertEqual(
            SettingsWindowGeometry.initialContentSize(visibleWidth: 1440, visibleHeight: 760),
            SettingsWindowDimensions(width: 1040, height: 720)
        )
    }

    func testNarrowScreenConstrainsWidth() {
        XCTAssertEqual(
            SettingsWindowGeometry.initialContentSize(visibleWidth: 1024, visibleHeight: 900),
            SettingsWindowDimensions(width: 984, height: 860)
        )
    }

    func testTinyVisibleFrameNeverDropsBelowUsableMinimum() {
        XCTAssertEqual(
            SettingsWindowGeometry.initialContentSize(visibleWidth: 800, visibleHeight: 500),
            SettingsWindowGeometry.minimum
        )
    }

    func testGeometryConstantsKeepScrollableComposeSheetUsable() {
        XCTAssertGreaterThanOrEqual(SettingsWindowGeometry.minimum.height, 600)
        XCTAssertGreaterThanOrEqual(SettingsWindowGeometry.preferred.height, 680)
        XCTAssertGreaterThanOrEqual(SettingsWindowGeometry.minimum.width, 820)
    }
}
