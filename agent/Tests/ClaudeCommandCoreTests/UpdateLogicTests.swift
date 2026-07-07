import XCTest
@testable import ClaudeCommandCore

final class UpdateLogicTests: XCTestCase {
    // ---- versionGreater -------------------------------------------------------

    func testStrictlyNewerPatch() {
        XCTAssertTrue(versionGreater("1.2.1", "1.2.0"))
        XCTAssertFalse(versionGreater("1.2.0", "1.2.1"))
    }

    func testEqualVersionsNotGreater() {
        XCTAssertFalse(versionGreater("1.2.0", "1.2.0"))
    }

    func testLeadingVIsIgnored() {
        XCTAssertFalse(versionGreater("v1.2.0", "1.2.0"))
        XCTAssertTrue(versionGreater("v1.2.1", "1.2.0"))
    }

    func testMissingComponentsTreatedAsZero() {
        // Doc comment: "1.2 vs 1.2.0 → equal".
        XCTAssertFalse(versionGreater("1.2", "1.2.0"))
        XCTAssertFalse(versionGreater("1.2.0", "1.2"))
    }

    func testAlphaSuffixNumberStillComparesWithinSameBase() {
        XCTAssertTrue(versionGreater("1.2.0-alpha.2", "1.2.0-alpha.1"))
        XCTAssertFalse(versionGreater("1.2.0-alpha.1", "1.2.0-alpha.2"))
    }

    // Regression guard for the isNewer fix in Updater.swift's check(): a
    // locally-built version ahead of the latest tag must never look "newer"
    // in the wrong direction just because the strings differ.
    func testNotNewerWhenCurrentIsAheadOfLatestTag() {
        XCTAssertFalse(versionGreater("1.2.0-alpha.1", "1.3.0-dev"))
    }

    // ---- UpdateChannel ----------------------------------------------------------

    func testChannelOfTagDetection() {
        XCTAssertEqual(UpdateChannel.of(tag: "v1.2.0-alpha.2"), .alpha)
        XCTAssertEqual(UpdateChannel.of(tag: "v1.2.0-beta.1"), .beta)
        XCTAssertEqual(UpdateChannel.of(tag: "v1.2.0"), .prod)
        XCTAssertEqual(UpdateChannel.of(tag: "V1.2.0-ALPHA.2"), .alpha) // case-insensitive
    }

    func testAlphaChannelAcceptsEverything() {
        XCTAssertEqual(UpdateChannel.alpha.accepts, Set([.alpha, .beta, .prod]))
    }

    func testProdChannelAcceptsOnlyProd() {
        XCTAssertEqual(UpdateChannel.prod.accepts, Set([.prod]))
    }

    func testBetaChannelDoesNotAcceptAlpha() {
        XCTAssertFalse(UpdateChannel.beta.accepts.contains(.alpha))
        XCTAssertTrue(UpdateChannel.beta.accepts.contains(.beta))
        XCTAssertTrue(UpdateChannel.beta.accepts.contains(.prod))
    }
}
