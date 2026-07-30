import XCTest
@testable import ClaudeCommandCore

final class DictationDeliveryPipelineTests: XCTestCase {
    func testDecisionKeepsLongerPartialWhenFinalDropsTail() {
        let decision = dictationTranscriptDecision(
            final: "Please keep this ending",
            lastPartial: "Please keep this ending cobalt compass",
            recordedSeconds: 2,
            minimumDuration: 0.2
        )

        XCTAssertEqual(decision, .deliver("Please keep this ending cobalt compass"))
    }

    func testDecisionUsesCompleteFinalWhenItExtendsPartial() {
        let decision = dictationTranscriptDecision(
            final: "Please keep this ending cobalt compass",
            lastPartial: "Please keep this ending",
            recordedSeconds: 2,
            minimumDuration: 0.2
        )

        XCTAssertEqual(decision, .deliver("Please keep this ending cobalt compass"))
    }

    func testDecisionSuppressesEmptyOrTooShortCapture() {
        XCTAssertEqual(
            dictationTranscriptDecision(
                final: "",
                lastPartial: "",
                recordedSeconds: 2,
                minimumDuration: 0.2
            ),
            .suppress("")
        )
        XCTAssertEqual(
            dictationTranscriptDecision(
                final: "keep this",
                lastPartial: "",
                recordedSeconds: 0.1,
                minimumDuration: 0.2
            ),
            .suppress("keep this")
        )
    }

    @MainActor
    func testPipelineCarriesFinalWordsThroughProcessingAndDelivery() async {
        let raw = "Retain every word through the final silver shoreline"
        var processorInput = ""
        var deliveredRaw = ""
        var deliveredProcessed = ""

        let result = await runDictationDeliveryPipeline(
            rawText: raw,
            process: { text in
                processorInput = text
                return text + "."
            },
            deliver: { deliveredRaw = $0; deliveredProcessed = $1 }
        )

        XCTAssertEqual(result.status, .delivered)
        XCTAssertEqual(processorInput, raw)
        XCTAssertEqual(deliveredRaw, raw)
        XCTAssertEqual(deliveredProcessed, raw + ".")
        XCTAssertTrue(result.processedText.hasSuffix("silver shoreline."))
    }

    @MainActor
    func testPipelineNeverDeliversEmptyRawTranscript() async {
        var processCalls = 0
        var deliveryCalls = 0

        let result = await runDictationDeliveryPipeline(
            rawText: "  \n",
            process: { text in processCalls += 1; return text },
            deliver: { _, _ in deliveryCalls += 1 }
        )

        XCTAssertEqual(result.status, .suppressedEmptyRaw)
        XCTAssertEqual(processCalls, 0)
        XCTAssertEqual(deliveryCalls, 0)
    }

    @MainActor
    func testPipelineFallsBackToRawWhenProcessingReturnsEmpty() async {
        var deliveryCalls = 0
        var deliveredRaw = ""
        var deliveredText = ""

        let result = await runDictationDeliveryPipeline(
            rawText: "um",
            process: { _ in "   " },
            deliver: {
                deliveryCalls += 1
                deliveredRaw = $0
                deliveredText = $1
            }
        )

        XCTAssertEqual(result.status, .deliveredRawFallback)
        XCTAssertEqual(deliveryCalls, 1)
        XCTAssertEqual(deliveredRaw, "um")
        XCTAssertEqual(deliveredText, "um")
        XCTAssertEqual(result.processedText, "um")
        XCTAssertTrue(result.delivered)
    }
}
