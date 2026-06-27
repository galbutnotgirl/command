import Speech
import AVFoundation
import CoreAudio
import AudioToolbox

enum DictationMode { case insert, addToClaudeChat }

// Lightweight stderr logger for dictation diagnostics.
private func dlog(_ s: String) { FileHandle.standardError.write(("[dictation] " + s + "\n").data(using: .utf8)!) }

// HAL default input device id. Needed because a launchd-spawned LSUIElement agent
// often gets an unbound AVAudioEngine inputNode (bogus multi-channel format, no
// buffers). Setting this device explicitly on the input audio unit binds it.
private func defaultInputDeviceID() -> AudioDeviceID {
    var id = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id)
    return id
}

final class SpeechEngine: NSObject, SFSpeechRecognizerDelegate {
    static let shared = SpeechEngine()

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String, DictationMode) -> Void)?
    var onError: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
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
                DispatchQueue.main.async {
                    self?.onError?("Speech recognition not authorized.")
                }
                return
            }
            if #available(macOS 14.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    dlog("mic requestRecordPermission → \(granted)")
                    if granted {
                        DispatchQueue.main.async { self?.startEngine() }
                    } else {
                        DispatchQueue.main.async {
                            self?.onError?("Microphone access denied.")
                        }
                    }
                }
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if granted {
                        DispatchQueue.main.async { self?.startEngine() }
                    } else {
                        DispatchQueue.main.async {
                            self?.onError?("Microphone access denied.")
                        }
                    }
                }
            }
        }
    }

    private func startEngine() {
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

        let engine = AVAudioEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true

        let vocab = loadVocab()
        if !vocab.isEmpty {
            req.contextualStrings = Array(vocab.prefix(100))
        }

        let inputNode = engine.inputNode

        // Bind the input audio unit to the real HAL default input device. Without
        // this, a launchd-spawned agent's inputNode can report a bogus format
        // (e.g. 3ch from a 1ch mic) and deliver zero buffers → "No speech detected".
        var devID = defaultInputDeviceID()
        if devID != 0, let au = inputNode.audioUnit {
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            dlog("set input device id=\(devID) status=\(st)")
        } else {
            dlog("could not set input device (devID=\(devID), audioUnit=\(inputNode.audioUnit != nil))")
        }

        // Use the node's INPUT format (the actual hardware stream) for the tap.
        let fmt = inputNode.inputFormat(forBus: 0)
        let outFmt = inputNode.outputFormat(forBus: 0)
        dlog("input format: sampleRate=\(fmt.sampleRate) ch=\(fmt.channelCount) | output ch=\(outFmt.channelCount)")

        // WAV created lazily from the first buffer's real format (whisper post-process).
        let wavPath = NSTemporaryDirectory() + "dictation_\(Date().timeIntervalSince1970).wav"
        let wavURL = URL(fileURLWithPath: wavPath)
        lastAudioFile = wavURL

        // Tap with nil format → the node supplies its own (avoids format-mismatch
        // crashes and the bogus pre-start format).
        var bufCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self = self else { return }
            self.request?.append(buf)
            if self.audioFile == nil {
                self.audioFile = try? AVAudioFile(forWriting: wavURL, settings: buf.format.settings)
            }
            try? self.audioFile?.write(from: buf)
            // Log RMS level every ~20 buffers so we can see if real audio arrives.
            bufCount += 1
            if bufCount % 20 == 0, let ch = buf.floatChannelData {
                let n = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n { let v = ch[0][i]; sum += v * v }
                let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
                dlog("buf #\(bufCount) frames=\(n) rms=\(rms) bufCh=\(buf.format.channelCount)")
            }
        }

        do {
            try engine.start()
            dlog("engine started")
        } catch {
            dlog("engine.start threw: \(error.localizedDescription)")
            onError?("Mic tap failed: \(error.localizedDescription)")
            return
        }

        audioEngine = engine
        request = req
        _isRecording = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                dlog("partial: \"\(text)\" isFinal=\(result.isFinal)")
                self.lastTranscript = text
                DispatchQueue.main.async {
                    self.onPartialResult?(text)
                }
                self.resetSilenceTimer()

                if result.isFinal {
                    self.finalize(text: text)
                }
            }

            if let error = error {
                // Code 216: recognition session ended normally (stop was called). Code 203: no speech detected.
                let nsErr = error as NSError
                dlog("recognitionTask error: domain=\(nsErr.domain) code=\(nsErr.code) \(nsErr.localizedDescription)")
                if nsErr.code == 216 || nsErr.code == 203 { return }
                DispatchQueue.main.async {
                    self.onError?(error.localizedDescription)
                }
                self.tearDown()
            }
        }

        resetSilenceTimer()
    }

    func stop() {
        guard _isRecording else { return }
        cancelSilenceTimer()
        // Signal end of audio — recognizer will deliver a final result asynchronously.
        request?.endAudio()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        _isRecording = false

        // Flush whatever we have if the recognizer doesn't deliver isFinal in time.
        let captured = lastTranscript
        let mode = currentMode
        DispatchQueue.main.asyncAfter(deadline: .now() + readDictationSilenceTimeout()) { [weak self] in
            guard let self = self, self.task != nil else { return }
            self.task?.cancel()
            self.task = nil
            if !captured.isEmpty {
                self.onFinalResult?(captured, mode)
            }
        }
    }

    func cancel() {
        cancelSilenceTimer()
        task?.cancel()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        request = nil
        task = nil
        audioEngine = nil
        audioFile = nil
        _isRecording = false
        lastTranscript = ""
        // Don't leave a partial recording for whisper to pick up.
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
            if !text.isEmpty {
                self.onFinalResult?(text, mode)
            }
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
        DispatchQueue.main.async { [weak self] in
            self?.onFinalResult?(text, mode)
        }
    }

    private func tearDown() {
        cancelSilenceTimer()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        task?.cancel()
        audioEngine = nil
        request = nil
        task = nil
        _isRecording = false
        // AVAudioFile closes and finalizes on dealloc — nil-ing flushes the WAV header.
        audioFile = nil
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
