import Foundation

/// Native audio APIs can block during Bluetooth profile negotiation. Keep
/// their serial ownership independent from UI and shortcut delivery.
public final class DictationAudioExecutor: @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String = "command.dictation.audio") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    public func enqueue(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }

    public func perform<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
