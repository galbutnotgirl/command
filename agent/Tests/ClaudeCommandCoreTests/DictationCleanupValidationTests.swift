import XCTest
@testable import ClaudeCommandCore

final class DictationCleanupValidationTests: XCTestCase {
    func testAllowsPunctuationCaseAndSpacing() {
        XCTAssertTrue(DictationCleanupValidation.preservesWords(
            original: "i don’t want this changed new teams", candidate: "I don't want this changed. New teams!"))
    }

    func testRejectsScreenshotRewrite() {
        XCTAssertFalse(DictationCleanupValidation.preservesWords(
            original: "Can you make a document to keep track of this um or a markdown file that I can just keep my pending to when I have other ideas of things I would like to be logged by other teams?",
            candidate: "Create a document or a markdown file to track your pending ideas. Include sections for items you want logged by other teams when you have additional concepts."))
    }

    func testRejectsAddedWordsAndChangedIntent() {
        for candidate in ["Ask other teams for updates", "Tell other teams", "Ask teams", "Teams other ask", ""] {
            XCTAssertFalse(DictationCleanupValidation.preservesWords(original: "Ask other teams", candidate: candidate))
        }
    }

    func testKeepsNamesNumbersAndUnfinishedPhrasing() {
        XCTAssertTrue(DictationCleanupValidation.preservesWords(original: "GitHub IDs for 4 teams and", candidate: "GitHub IDs for 4 teams and…"))
        XCTAssertFalse(DictationCleanupValidation.preservesWords(original: "GitHub IDs for 4 teams", candidate: "GitHub IDs for 5 teams"))
        XCTAssertFalse(DictationCleanupValidation.preservesWords(original: "I think that would be very useful", candidate: "That would be very useful."))
    }
}
