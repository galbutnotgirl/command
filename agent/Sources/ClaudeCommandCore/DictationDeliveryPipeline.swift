import Foundation

public enum DictationTranscriptDecision: Equatable, Sendable {
    case deliver(String)
    case suppress(String)

    public var selectedText: String {
        switch self {
        case .deliver(let text), .suppress(let text): return text
        }
    }

    public var shouldDeliver: Bool {
        if case .deliver = self { return true }
        return false
    }
}

public func dictationTranscriptDecision(
    final: String,
    lastPartial: String,
    recordedSeconds: Double,
    minimumDuration: Double
) -> DictationTranscriptDecision {
    let selected = preferredDictationTranscript(final: final, lastPartial: lastPartial)
    let gate = DictationActivityGate(minimumDuration: minimumDuration)
    return gate.shouldDispatch(text: selected, recordedSeconds: recordedSeconds)
        ? .deliver(selected)
        : .suppress(selected)
}

public enum DictationDeliveryStatus: String, Equatable, Sendable {
    case delivered
    case deliveredRawFallback
    case suppressedEmptyRaw
}

public struct DictationDeliveryResult: Equatable, Sendable {
    public let status: DictationDeliveryStatus
    public let rawText: String
    public let processedText: String

    public init(status: DictationDeliveryStatus, rawText: String, processedText: String) {
        self.status = status
        self.rawText = rawText
        self.processedText = processedText
    }

    public var delivered: Bool {
        status == .delivered || status == .deliveredRawFallback
    }
}

@MainActor
public func runDictationDeliveryPipeline(
    rawText: String,
    process: (String) async -> String,
    deliver: (String, String) -> Void
) async -> DictationDeliveryResult {
    guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return DictationDeliveryResult(
            status: .suppressedEmptyRaw,
            rawText: rawText,
            processedText: ""
        )
    }

    let processed = await process(rawText)
    let processedIsEmpty = processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let deliveryText = processedIsEmpty ? rawText : processed

    deliver(rawText, deliveryText)
    return DictationDeliveryResult(
        status: processedIsEmpty ? .deliveredRawFallback : .delivered,
        rawText: rawText,
        processedText: deliveryText
    )
}
