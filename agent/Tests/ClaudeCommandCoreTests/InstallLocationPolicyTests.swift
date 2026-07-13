import XCTest
@testable import ClaudeCommandCore

final class InstallLocationPolicyTests: XCTestCase {
    func testOffersMoveFromDownloads() {
        XCTAssertTrue(InstallLocationPolicy.shouldOfferMove(
            bundlePath: "/Users/gal/Downloads/Command.app",
            homeDirectory: "/Users/gal",
            sourceRootHasBuildScript: false
        ))
    }

    func testOffersMoveFromAppTranslocation() {
        XCTAssertTrue(InstallLocationPolicy.shouldOfferMove(
            bundlePath: "/private/var/folders/x/AppTranslocation/Command.app",
            homeDirectory: "/Users/gal",
            sourceRootHasBuildScript: false
        ))
    }

    func testAcceptsUserApplications() {
        XCTAssertFalse(InstallLocationPolicy.shouldOfferMove(
            bundlePath: "/Users/gal/Applications/Command.app",
            homeDirectory: "/Users/gal",
            sourceRootHasBuildScript: false
        ))
    }

    func testAcceptsSystemApplications() {
        XCTAssertFalse(InstallLocationPolicy.shouldOfferMove(
            bundlePath: "/Applications/Command.app",
            homeDirectory: "/Users/gal",
            sourceRootHasBuildScript: false
        ))
    }

    func testSkipsSourceBuild() {
        XCTAssertFalse(InstallLocationPolicy.shouldOfferMove(
            bundlePath: "/Users/gal/Projects/command/Command.app",
            homeDirectory: "/Users/gal",
            sourceRootHasBuildScript: true
        ))
    }
}
