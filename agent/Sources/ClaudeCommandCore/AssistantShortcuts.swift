// Native shortcuts exposed by the unified ChatGPT app. Keep this mapping in
// pure core logic so app updates cannot silently change routing behavior.

import Foundation

public struct AssistantAppShortcut: Equatable, Sendable {
    public let keycode: UInt32
    public let command: Bool
    public let option: Bool
    public let shift: Bool

    public init(keycode: UInt32, command: Bool, option: Bool = false, shift: Bool = false) {
        self.keycode = keycode
        self.command = command
        self.option = option
        self.shift = shift
    }
}

public func assistantShortcut(forSocketCommand command: String) -> AssistantAppShortcut? {
    switch command {
    case "newtask":
        return AssistantAppShortcut(keycode: 45, command: true) // Command-N
    case "newchat":
        return AssistantAppShortcut(keycode: 45, command: true, option: true) // Command-Option-N
    case "newprojectless":
        return AssistantAppShortcut(keycode: 31, command: true, option: true) // Command-Option-O
    default:
        return nil
    }
}
