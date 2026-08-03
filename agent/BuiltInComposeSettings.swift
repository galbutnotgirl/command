import Foundation

struct BuiltInComposeSettings: Codable {
    var autoSubmitDefault: Bool
    var autoSubmitOverrides: [String: Bool]

    func effectiveAutoSubmit(for action: String) -> Bool {
        autoSubmitOverrides[action] ?? autoSubmitDefault
    }
}

let BUILTIN_COMPOSE_SETTINGS_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent(".claude/state/built-in-compose.json")

let DEFAULT_BUILTIN_COMPOSE_SETTINGS = BuiltInComposeSettings(
    autoSubmitDefault: false,
    autoSubmitOverrides: ["go": true, "shotgo": true]
)

struct BuiltInComposeRowDefinition: Identifiable {
    let action: String
    let inputLabel: String
    let behaviorLabel: String
    let icon: String
    var id: String { action }
}

let BUILTIN_COMPOSE_ROWS: [BuiltInComposeRowDefinition] = [
    BuiltInComposeRowDefinition(action: "add", inputLabel: "Selected text", behaviorLabel: "Existing conversation", icon: "text.cursor"),
    BuiltInComposeRowDefinition(action: "comment", inputLabel: "Selected text", behaviorLabel: "New conversation", icon: "text.cursor"),
    BuiltInComposeRowDefinition(action: "go", inputLabel: "Selected text", behaviorLabel: "Go", icon: "text.cursor"),
    BuiltInComposeRowDefinition(action: "shotadd", inputLabel: "Screenshot", behaviorLabel: "Existing conversation", icon: "camera.viewfinder"),
    BuiltInComposeRowDefinition(action: "shotcomment", inputLabel: "Screenshot", behaviorLabel: "New conversation", icon: "camera.viewfinder"),
    BuiltInComposeRowDefinition(action: "shotgo", inputLabel: "Screenshot", behaviorLabel: "Go", icon: "camera.viewfinder"),
]

func loadBuiltInComposeSettings() -> BuiltInComposeSettings {
    guard let data = FileManager.default.contents(atPath: BUILTIN_COMPOSE_SETTINGS_PATH),
          let settings = try? JSONDecoder().decode(BuiltInComposeSettings.self, from: data) else {
        return DEFAULT_BUILTIN_COMPOSE_SETTINGS
    }
    return settings
}

func encodedBuiltInComposeSettings(_ settings: BuiltInComposeSettings) throws -> Data {
    try JSONEncoder().encode(settings)
}

@discardableResult
func saveBuiltInComposeSettings(_ settings: BuiltInComposeSettings) -> Bool {
    do {
        return persistStateData(
            try encodedBuiltInComposeSettings(settings),
            to: URL(fileURLWithPath: BUILTIN_COMPOSE_SETTINGS_PATH),
            label: "Compose behavior"
        )
    } catch {
        reportStateSaveFailure(label: "Compose behavior", error: error)
        return false
    }
}

func builtInComposeAutoSubmit(_ action: String) -> Bool? {
    guard BUILTIN_COMPOSE_ROWS.contains(where: { $0.action == action }) else { return nil }
    return loadBuiltInComposeSettings().effectiveAutoSubmit(for: action)
}
