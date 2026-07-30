import Foundation

public enum HotkeyHealthProbeStatus: String, Codable, Equatable, Sendable {
    case passed
    case accessibilityUnavailable
    case eventTapMissing
    case eventTapDisabled
    case registrationMismatch
    case probeBusy
    case eventCreationFailed
    case eventDeliveryTimedOut
}

public struct HotkeyHealthProbeResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let status: HotkeyHealthProbeStatus
    public let accessibilityTrusted: Bool
    public let eventTapInstalled: Bool
    public let eventTapEnabled: Bool
    public let expectedCarbonRegistrations: Int
    public let actualCarbonRegistrations: Int
    public let registrationFailures: Int
    public let expectedEventTapAliases: Int
    public let configuredVoiceAliases: Int
    public let requestedEvents: Int
    public let deliveredEvents: Int
    public let durationMilliseconds: Int
    public let failure: String?

    public init(
        status: HotkeyHealthProbeStatus,
        accessibilityTrusted: Bool = false,
        eventTapInstalled: Bool = false,
        eventTapEnabled: Bool = false,
        expectedCarbonRegistrations: Int = 0,
        actualCarbonRegistrations: Int = 0,
        registrationFailures: Int = 0,
        expectedEventTapAliases: Int = 0,
        configuredVoiceAliases: Int = 0,
        requestedEvents: Int = 0,
        deliveredEvents: Int = 0,
        durationMilliseconds: Int = 0,
        failure: String? = nil
    ) {
        self.ok = status == .passed
        self.status = status
        self.accessibilityTrusted = accessibilityTrusted
        self.eventTapInstalled = eventTapInstalled
        self.eventTapEnabled = eventTapEnabled
        self.expectedCarbonRegistrations = max(0, expectedCarbonRegistrations)
        self.actualCarbonRegistrations = max(0, actualCarbonRegistrations)
        self.registrationFailures = max(0, registrationFailures)
        self.expectedEventTapAliases = max(0, expectedEventTapAliases)
        self.configuredVoiceAliases = max(0, configuredVoiceAliases)
        self.requestedEvents = max(0, requestedEvents)
        self.deliveredEvents = max(0, deliveredEvents)
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.failure = failure
    }
}

public enum HotkeyHealthProbeCoding {
    public static func encode(_ result: HotkeyHealthProbeResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    public static func decode(_ data: Data) throws -> HotkeyHealthProbeResult {
        try JSONDecoder().decode(HotkeyHealthProbeResult.self, from: data)
    }
}
