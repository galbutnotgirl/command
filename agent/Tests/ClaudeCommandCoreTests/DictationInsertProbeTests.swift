import XCTest
@testable import ClaudeCommandCore

final class DictationInsertProbeTests: XCTestCase {
    func testPassedProbeCarriesPipelinePasteAndRestoreEvidence() throws {
        let original = DictationInsertProbeResult(
            status: .passed,
            pipelineStatus: "delivered",
            rawCharacters: 58,
            processedCharacters: 59,
            clipboardWritten: true,
            targetActive: true,
            pasteEventPosted: true,
            receiverMatched: true,
            clipboardRestored: true,
            previousAppRestored: true,
            durationMilliseconds: 37
        )

        let decoded = try DictationInsertProbeCoding.decode(
            DictationInsertProbeCoding.encode(original)
        )

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.ok)
    }

    func testFailureStatusCannotReportSuccessAndClampsMetrics() {
        let result = DictationInsertProbeResult(
            status: .pasteTimedOut,
            rawCharacters: -1,
            processedCharacters: -2,
            durationMilliseconds: -3,
            failure: "Focused receiver never received paste."
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.rawCharacters, 0)
        XCTAssertEqual(result.processedCharacters, 0)
        XCTAssertEqual(result.durationMilliseconds, 0)
    }
}
