import AVFoundation
import ClaudeCommandCore

private final class DictationSampleReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let handler: AVAudioNodeTapBlock
    let acceptsAudio: () -> Bool

    init(handler: @escaping AVAudioNodeTapBlock, acceptsAudio: @escaping () -> Bool) {
        self.handler = handler
        self.acceptsAudio = acceptsAudio
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard acceptsAudio(), let buffer = copyDictationPCMBuffer(sampleBuffer) else { return }
        handler(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate))
    }
}

/// Open the selected microphone directly, avoiding AVAudioEngine's default
/// input-node Bluetooth format negotiation. Native lifecycle stays off-main.
final class DictationAudioCapture: @unchecked Sendable {
    private static let executor = DictationAudioExecutor()
    private let sampleQueue = DispatchQueue(label: "command.dictation.samples", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var receiver: DictationSampleReceiver?
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

    func prepare() async throws -> (format: AVAudioFormat, deviceName: String) {
        try await Self.executor.perform {
            guard !self.isCancelled else { throw CancellationError() }
            if self.startupDelayMilliseconds > 0 {
                Thread.sleep(forTimeInterval: Double(self.startupDelayMilliseconds) / 1_000)
                guard !self.isCancelled else { throw CancellationError() }
            }
            guard let device = AVCaptureDevice.default(for: .audio) else {
                throw NSError(domain: "CommandCapture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
            }
            let input = try AVCaptureDeviceInput(device: device)
            let session = AVCaptureSession()
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true
            ]
            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw NSError(domain: "CommandCapture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Microphone capture could not be configured."])
            }
            session.beginConfiguration()
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            self.session = session
            self.output = output
            guard !self.isCancelled else { self.close(); throw CancellationError() }
            return (AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                  channels: 1, interleaved: false)!, device.localizedName)
        }
    }

    func start(format: AVAudioFormat, handler: @escaping AVAudioNodeTapBlock) async throws {
        try await Self.executor.perform {
            guard !self.isCancelled, let session = self.session, let output = self.output else {
                throw CancellationError()
            }
            let receiver = DictationSampleReceiver(handler: handler, acceptsAudio: { [weak self] in
                self.map { !$0.isCancelled } ?? false
            })
            self.receiver = receiver
            output.setSampleBufferDelegate(receiver, queue: self.sampleQueue)
            session.startRunning()
            guard !self.isCancelled else { self.close(); throw CancellationError() }
            guard session.isRunning else {
                self.close()
                throw NSError(domain: "CommandCapture", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Microphone capture did not start."])
            }
        }
    }

    func removeTap() {
        Self.executor.enqueue {
            self.output?.setSampleBufferDelegate(nil, queue: nil)
            self.sampleQueue.sync { }
            self.receiver = nil
        }
    }

    func shutdown() async {
        cancel()
        _ = try? await Self.executor.perform { self.close() }
    }

    private func close() {
        output?.setSampleBufferDelegate(nil, queue: nil)
        sampleQueue.sync { }
        receiver = nil
        session?.stopRunning()
        session = nil
        output = nil
    }
}
