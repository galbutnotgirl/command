import XCTest
@testable import ClaudeCommandCore

final class HandoffModelsTests: XCTestCase {
    // ---- staleness / age (now injected, not wall-clock) ----------------------

    func testRunningUnder30MinutesIsNotStalled() {
        let now = Date(timeIntervalSince1970: 10_000)
        let createdAt = now.addingTimeInterval(-1000)   // ~16.7 min ago
        XCTAssertFalse(isHandoffStalled(status: "running", createdAt: createdAt, now: now))
    }

    func testRunningOver30MinutesIsStalled() {
        let now = Date(timeIntervalSince1970: 10_000)
        let createdAt = now.addingTimeInterval(-1801)   // just over 30 min
        XCTAssertTrue(isHandoffStalled(status: "running", createdAt: createdAt, now: now))
    }

    func testSucceededNeverStalledRegardlessOfAge() {
        let now = Date(timeIntervalSince1970: 10_000)
        let createdAt = now.addingTimeInterval(-1_000_000)
        XCTAssertFalse(isHandoffStalled(status: "succeeded", createdAt: createdAt, now: now))
    }

    func testStatusGlyphs() {
        XCTAssertEqual(handoffStatusGlyph(status: "succeeded", isStalled: false), "✓")
        XCTAssertEqual(handoffStatusGlyph(status: "failed", isStalled: false), "✗")
        XCTAssertEqual(handoffStatusGlyph(status: "running", isStalled: false), "…")
        XCTAssertEqual(handoffStatusGlyph(status: "running", isStalled: true), "⚠")
    }

    func testAgeStringBuckets() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(handoffAgeString(createdAt: now.addingTimeInterval(-30), now: now), "30s ago")
        XCTAssertEqual(handoffAgeString(createdAt: now.addingTimeInterval(-120), now: now), "2m ago")
        XCTAssertEqual(handoffAgeString(createdAt: now.addingTimeInterval(-7200), now: now), "2h ago")
        XCTAssertEqual(handoffAgeString(createdAt: now.addingTimeInterval(-172_800), now: now), "2d ago")
    }

    func testMenuTitleWithSkill() {
        let title = handoffMenuTitle(statusGlyph: "✓", source: "selection", skill: "triage-capture", age: "2m ago", isStalled: false)
        XCTAssertEqual(title, "✓ selection → /triage-capture — 2m ago")
    }

    func testMenuTitleWithoutSkillFallsBackToClaudeP() {
        let title = handoffMenuTitle(statusGlyph: "…", source: "screenshot", skill: nil, age: "5s ago", isStalled: false)
        XCTAssertEqual(title, "… screenshot → claude -p — 5s ago")
    }

    func testMenuTitleFlagsStalled() {
        let title = handoffMenuTitle(statusGlyph: "⚠", source: "selection", skill: nil, age: "40m ago", isStalled: true)
        XCTAssertTrue(title.hasSuffix("(stalled?)"))
    }

    // ---- retention pruning eligibility ----------------------------------------

    func testRunningNeverPruneEligibleEvenIfOld() {
        let cutoff = Date(timeIntervalSince1970: 10_000)
        let ancient = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(isHandoffPruneEligible(status: "running", createdAt: ancient, cutoff: cutoff))
    }

    func testFinishedOlderThanCutoffIsPruneEligible() {
        let cutoff = Date(timeIntervalSince1970: 10_000)
        let old = Date(timeIntervalSince1970: 5_000)
        XCTAssertTrue(isHandoffPruneEligible(status: "succeeded", createdAt: old, cutoff: cutoff))
        XCTAssertTrue(isHandoffPruneEligible(status: "failed", createdAt: old, cutoff: cutoff))
    }

    func testFinishedNewerThanCutoffIsNotPruneEligible() {
        let cutoff = Date(timeIntervalSince1970: 10_000)
        let recent = Date(timeIntervalSince1970: 15_000)
        XCTAssertFalse(isHandoffPruneEligible(status: "succeeded", createdAt: recent, cutoff: cutoff))
    }

    // ---- renderCustomActionHandoffPrompt ---------------------------------------

    private func makeAction(prompt: String, skill: String = "", isShot: Bool = false) -> CustomAction {
        CustomAction.makeNew(name: "t", prompt: prompt, isShot: isShot, isHandoff: true, skill: skill)
    }

    func testTextContentInlineViaSelectionToken() {
        let ca = makeAction(prompt: "Summarize: {selection}")
        XCTAssertEqual(renderCustomActionHandoffPrompt(ca, content: "hello", file: nil), "Summarize: hello")
    }

    func testTextContentAppendedWhenNoToken() {
        let ca = makeAction(prompt: "Summarize this")
        XCTAssertEqual(renderCustomActionHandoffPrompt(ca, content: "hello", file: nil), "Summarize this\n\nhello")
    }

    func testEmptyPromptWithContentIsJustContent() {
        let ca = makeAction(prompt: "")
        XCTAssertEqual(renderCustomActionHandoffPrompt(ca, content: "hello", file: nil), "hello")
    }

    func testFileInlineViaFileToken() {
        let ca = makeAction(prompt: "Read {file} and summarize", isShot: true)
        XCTAssertEqual(renderCustomActionHandoffPrompt(ca, content: nil, file: "/tmp/x.png"),
                        "Read /tmp/x.png and summarize")
    }

    func testFileAppendedWhenNoToken() {
        let ca = makeAction(prompt: "Look at this screenshot", isShot: true)
        let out = renderCustomActionHandoffPrompt(ca, content: nil, file: "/tmp/x.png")
        XCTAssertTrue(out.hasPrefix("Look at this screenshot"))
        XCTAssertTrue(out.contains("/tmp/x.png"))
    }

    func testSkillPrependedWhenSet() {
        let ca = makeAction(prompt: "{selection}", skill: "triage-capture")
        let out = renderCustomActionHandoffPrompt(ca, content: "hi", file: nil)
        XCTAssertEqual(out, "/triage-capture\n\nhi")
    }

    func testNoSkillLineWhenSkillEmpty() {
        let ca = makeAction(prompt: "{selection}")
        let out = renderCustomActionHandoffPrompt(ca, content: "hi", file: nil)
        XCTAssertEqual(out, "hi")
        XCTAssertFalse(out.hasPrefix("/"))
    }
}
