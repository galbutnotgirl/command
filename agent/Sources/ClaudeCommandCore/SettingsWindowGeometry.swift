import Foundation

public struct SettingsWindowDimensions: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum SettingsWindowGeometry {
    public static let minimum = SettingsWindowDimensions(width: 960, height: 600)
    public static let preferred = SettingsWindowDimensions(width: 1040, height: 860)
    public static let screenMargin: Double = 40

    public static func initialContentSize(
        visibleWidth: Double,
        visibleHeight: Double
    ) -> SettingsWindowDimensions {
        let availableWidth = max(0, visibleWidth - screenMargin)
        let availableHeight = max(0, visibleHeight - screenMargin)
        return SettingsWindowDimensions(
            width: max(minimum.width, min(preferred.width, availableWidth)),
            height: max(minimum.height, min(preferred.height, availableHeight))
        )
    }
}
