import Foundation

/// A modifier voice shortcut stays held only while its primary key and all
/// required chord modifiers remain down. Extra modifiers do not change ownership.
public struct DictationModifierHold: Equatable, Sendable {
    public let keycode: UInt32
    public let requiredModifiers: UInt32

    public init(keycode: UInt32, requiredModifiers: UInt32) {
        self.keycode = keycode
        self.requiredModifiers = requiredModifiers
    }

    public func isHeld(primaryIsDown: Bool, activeModifiers: UInt32) -> Bool {
        primaryIsDown && activeModifiers & requiredModifiers == requiredModifiers
    }
}
