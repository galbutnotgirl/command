import AVFoundation
import ClaudeCommandCore

/// Engine, input node, and tap are touched only on the native-audio executor.
/// Cancellation is immediate even while a native open is still blocked.
final class DictationAudioCapture: @unchecked Sendable {
    private static let executor = DictationAudioExecutor()
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private let lock = NSLock()
    private var cancelled = false
    private let startupDelayMilliseconds: Int

    init(startupDelayMilliseconds: Int = 0) {
        self.startupDelayMilliseconds = max(0, startupDelayMilliseconds)
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func prepare() async throws -> AVAudioFormat {
        try await Self.executor.perform {
            guard !self.isCancelled else { throw CancellationError() }
            if self.startupDelayMilliseconds > 0 {
                Thread.sleep(forTimeInterval: Double(self.startupDelayMilliseconds) / 1_000)
                guard !self.isCancelled else { throw CancellationError() }
            }
            let engine = AVAudioEngine()
            self.engine = engine
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard !self.isCancelled else {
                self.close()
                throw CancellationError()
            }
            guard format.sampleRate > 0, format.channelCount > 0 else {
                self.close()
                throw NSError(domain: "CommandCapture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Microphone has no usable input format."])
            }
            return format
        }
    }

    func start(format: AVAudioFormat, handler: @escaping AVAudioNodeTapBlock) async throws {
        try await Self.executor.perform {
            guard !self.isCancelled, let engine = self.engine else { throw CancellationError() }
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format, block: handler)
            self.tapInstalled = true
            do { try engine.start() }
            catch { self.close(); throw error }
            guard !self.isCancelled else {
                self.close()
                throw CancellationError()
            }
        }
    }

    func removeTap() {
        Self.executor.enqueue {
            if self.tapInstalled {
                self.engine?.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
        }
    }

    func shutdown() async {
        cancel()
        _ = try? await Self.executor.perform { self.close() }
    }

    private func close() {
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
    }
}
