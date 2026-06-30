import Speech
import AVFoundation
import CoreAudio

enum DictationMode { case insert, addToClaudeChat }

private func dlog(_ s: String) { FileHandle.standardError.write(("[dictation] " + s + "\n").data(using: .utf8)!) }

// Convert a CMSampleBuffer (from AVCaptureAudioDataOutput) into an AVAudioPCMBuffer
// for SFSpeechAudioBufferRecognitionRequest.
private func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let desc = CMSampleBufferGetFormatDescription(sb) else { return nil }
    let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
    let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
    guard n > 0 else { return nil }
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
    buf.frameLength = n
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList) == noErr else { return nil }
    return buf
}

// MARK: - Capture delegate (AVCaptureSession → SFSpeechRecognitionRequest bridge)

private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onDebug: ((String) -> Void)?
    private var bufCount = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = pcmBuffer(from: sb) else {
            onDebug?("pcmBuffer conversion failed")
            return
        }
        bufCount += 1
        if bufCount % 20 == 0 {
            var rms: Float = 0
            if let ch = buf.floatChannelData {
                let n = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n { let v = ch[0][i]; sum += v * v }
                rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            }
            onDebug?("buf #\(bufCount) rms=\(String(format: "%.4f", rms)) ch=\(buf.format.channelCount) fmt=\(buf.format.sampleRate)Hz")
        }
        onBuffer?(buf)
    }
}

// MARK: - SpeechEngine

final class SpeechEngine: NSObject, SFSpeechRecognizerDelegate {
    static let shared = SpeechEngine()

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String, DictationMode) -> Void)?
    var onError: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: DispatchSourceTimer?
    private var currentMode: DictationMode = .insert
    private var lastTranscript: String = ""
    private var _isRecording = false
    private var audioFile: AVAudioFile?
    var lastAudioFile: URL?

    var isRecording: Bool { _isRecording }

    private override init() {
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer?.delegate = self
    }

    func start(mode: DictationMode) {
        guard !_isRecording else { return }
        currentMode = mode
        lastTranscript = ""

        dlog("start() mode=\(mode) micAuth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speechAuth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            dlog("speech requestAuthorization → \(authStatus.rawValue)")
            guard authStatus == .authorized else {
                DispatchQueue.main.async { self?.onError?("Speech recognition not authorized.") }
                return
            }
            if #available(macOS 14.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    dlog("mic requestRecordPermission → \(granted)")
                    if granted {
                        DispatchQueue.main.async { self?.startCapture() }
                    } else {
                        DispatchQueue.main.async { self?.onError?("Microphone access denied.") }
                    }
                }
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if granted {
                        DispatchQueue.main.async { self?.startCapture() }
                    } else {
                        DispatchQueue.main.async { self?.onError?("Microphone access denied.") }
                    }
                }
            }
        }
    }

    private func startCapture() {
        guard let recognizer = recognizer else {
            dlog("recognizer is nil")
            onError?("Speech recognizer unavailable.")
            return
        }
        dlog("recognizer.isAvailable=\(recognizer.isAvailable) supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)")
        guard recognizer.isAvailable else {
            onError?("Speech recognizer unavailable.")
            return
        }

        // Pick the default audio capture device (microphone).
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            dlog("no AVCaptureDevice for audio")
            onError?("No microphone found.")
            return
        }
        dlog("capture device: \(mic.localizedName)")

        guard let micInput = try? AVCaptureDeviceInput(device: mic) else {
            dlog("AVCaptureDeviceInput init failed")
            onError?("Could not open microphone.")
            return
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()

        guard session.canAddInput(micInput), session.canAddOutput(output) else {
            dlog("session cannot add input or output")
            onError?("Audio capture session setup failed.")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        let vocab = loadVocab()
        if !vocab.isEmpty { req.contextualStrings = Array(vocab.prefix(100)) }

        let wavPath = NSTemporaryDirectory() + "dictation_\(Date().timeIntervalSince1970).wav"
        let wavURL = URL(fileURLWithPath: wavPath)
        lastAudioFile = wavURL

        let del = AudioCaptureDelegate()
        del.onDebug = { s in dlog(s) }
        del.onBuffer = { [weak self] buf in
            guard let self = self else { return }
            self.request?.append(buf)
            if self.audioFile == nil {
                self.audioFile = try? AVAudioFile(forWriting: wavURL, settings: buf.format.settings)
            }
            try? self.audioFile?.write(from: buf)
        }

        output.setSampleBufferDelegate(del, queue: DispatchQueue.global(qos: .userInteractive))
        session.addInput(micInput)
        session.addOutput(output)
        session.startRunning()

        dlog("AVCaptureSession running=\(session.isRunning) connections=\(output.connections.count)")

        captureSession = session
        captureDelegate = del
        request = req
        _isRecording = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                dlog("partial: \"\(text)\" isFinal=\(result.isFinal)")
                self.lastTranscript = text
                DispatchQueue.main.async { self.onPartialResult?(text) }
                self.resetSilenceTimer()
                if result.isFinal { self.finalize(text: text) }
            }

            if let error = error {
                let ns = error as NSError
                dlog("recognitionTask error: domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
                // 216 = session ended normally; 203 = no speech detected — both are non-fatal.
                if ns.code == 216 || ns.code == 203 { return }
                DispatchQueue.main.async { self.onError?(error.localizedDescription) }
                self.tearDown()
            }
        }

        resetSilenceTimer()
    }

    func stop() {
        guard _isRecording else { return }
        cancelSilenceTimer()
        request?.endAudio()
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        _isRecording = false

        let captured = lastTranscript
        let mode = currentMode
        DispatchQueue.main.asyncAfter(deadline: .now() + readDictationSilenceTimeout()) { [weak self] in
            guard let self = self, self.task != nil else { return }
            self.task?.cancel()
            self.task = nil
            if !captured.isEmpty { self.onFinalResult?(captured, mode) }
        }
    }

    func cancel() {
        cancelSilenceTimer()
        task?.cancel()
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        request = nil
        task = nil
        audioFile = nil
        _isRecording = false
        lastTranscript = ""
        if let url = lastAudioFile { try? FileManager.default.removeItem(at: url) }
        lastAudioFile = nil
    }

    // MARK: - Silence detection

    private func resetSilenceTimer() {
        cancelSilenceTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + readDictationSilenceTimeout())
        t.setEventHandler { [weak self] in
            guard let self = self, self._isRecording else { return }
            let text = self.lastTranscript
            let mode = self.currentMode
            self.tearDown()
            if !text.isEmpty { self.onFinalResult?(text, mode) }
        }
        t.resume()
        silenceTimer = t
    }

    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    // MARK: - Internal

    private func finalize(text: String) {
        let mode = currentMode
        tearDown()
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onFinalResult?(text, mode) }
    }

    private func tearDown() {
        cancelSilenceTimer()
        captureSession?.stopRunning()
        task?.cancel()
        captureSession = nil
        captureDelegate = nil
        request = nil
        task = nil
        _isRecording = false
        audioFile = nil  // flushes WAV header on dealloc
    }

    private func loadVocab() -> [String] {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/state/dictation-vocab.json")
        guard let data = FileManager.default.contents(atPath: path),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }

    // MARK: - SFSpeechRecognizerDelegate

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer,
                          availabilityDidChange available: Bool) {
        if !available && _isRecording {
            DispatchQueue.main.async { [weak self] in
                self?.onError?("Speech recognizer became unavailable.")
            }
            tearDown()
        }
    }
}
