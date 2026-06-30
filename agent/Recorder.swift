// Recorder.swift — Parakeet TDT on-device ASR via FluidAudio.
// Drop-in replacement for the old SFSpeechRecognizer-based SpeechEngine.

import Cocoa
import AVFoundation
import FluidAudio

// ─── Mode ──────────────────────────────────────────────────────────────────────

enum DictMode { case insert, claude }

// ─── Global recorder singleton ─────────────────────────────────────────────────
// @MainActor: Recorder is @MainActor-isolated; annotation ensures init runs on main actor.

@MainActor
let recorder = Recorder()

// ─── Recorder ──────────────────────────────────────────────────────────────────

@MainActor
final class Recorder: ObservableObject {
    enum State: String { case idle, loading, starting, listening, error }
    enum ModelStatus { case notDownloaded, downloading(Double), ready, error(String) }

    @Published var state: State = .idle
    @Published var liveTranscript = ""
    @Published var modelStatus: ModelStatus = .notDownloaded
    @Published var audioLevel: Float = 0

    var onFinal:   ((String, DictMode) -> Void)?
    var onPartial: ((String) -> Void)?

    private(set) var currentMode: DictMode = .insert
    var prevBundle = ""

    private var loadedModels: AsrModels?
    private var currentMgr: SlidingWindowAsrManager?
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: DispatchSourceTimer?
    private var lastTranscript = ""
    private var sessionID = 0
    private var streamTask: Task<Void, Never>?

    private func log(_ s: String) { DebugLog.shared.append(s) }

    // MARK: - Model management

    func initModels() async {
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
        if AsrModels.modelsExist(at: cacheDir) {
            log("models cached — loading")
            await loadFromCache(cacheDir: cacheDir)
        } else {
            log("models not cached — open Dictation settings to download")
            modelStatus = .notDownloaded
        }
    }

    func downloadModels() async {
        guard case .notDownloaded = modelStatus else { return }
        log("downloading models…")
        modelStatus = .downloading(0)
        do {
            let models = try await AsrModels.downloadAndLoad(progressHandler: { [weak self] progress in
                Task { @MainActor in
                    self?.modelStatus = .downloading(progress.fractionCompleted)
                    if Int(progress.fractionCompleted * 100) % 10 == 0 {
                        DebugLog.shared.append("download \(Int(progress.fractionCompleted * 100))%")
                    }
                }
            })
            loadedModels = models
            modelStatus = .ready
            log("models downloaded and ready")
        } catch {
            log("download failed: \(error)")
            modelStatus = .error(error.localizedDescription)
        }
    }

    func removeModels() {
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
        do {
            try FileManager.default.removeItem(at: cacheDir)
            log("model cache removed")
        } catch {
            log("remove failed: \(error.localizedDescription)")
        }
        loadedModels = nil; currentMgr = nil; modelStatus = .notDownloaded
    }

    private func loadFromCache(cacheDir: URL) async {
        state = .loading
        do {
            let models = try await AsrModels.downloadAndLoad(to: cacheDir)
            loadedModels = models; modelStatus = .ready; state = .idle
            log("models loaded from cache — ready")
        } catch {
            log("cache load failed: \(error)")
            modelStatus = .error(error.localizedDescription); state = .idle
        }
    }

    // MARK: - Recording lifecycle

    func toggle(mode: DictMode) {
        if state == .listening || state == .starting { stop() }
        else if state == .idle { start(mode: mode) }
    }

    func start(mode: DictMode) {
        guard state == .idle || state == .error else { return }
        guard loadedModels != nil else {
            fail("models not loaded")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Model not downloaded"
                alert.informativeText = "Open Claude Command > Settings > Dictation and click Download to get the Parakeet model (~650 MB), then try again."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    settingsWindow.show(tab: .dictSettings)
                }
            }
            return
        }
        sessionID += 1
        let mySession = sessionID
        currentMode = mode
        lastTranscript = ""; liveTranscript = ""
        state = .starting
        log("▶ session \(mySession) start mode=\(mode)")

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            beginStreaming(session: mySession)
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self = self else { return }
                    if granted { self.beginStreaming(session: mySession) }
                    else { self.fail("microphone access denied") }
                }
            }
        }
    }

    private func beginStreaming(session: Int) {
        guard let models = loadedModels else { fail("loadedModels nil"); return }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        log("audio format: \(hwFormat.sampleRate)Hz ch=\(hwFormat.channelCount)")

        streamTask = Task {
            let mgr = SlidingWindowAsrManager(config: .default)
            do { try await mgr.loadModels(models) }
            catch { self.fail("mgr.loadModels: \(error)"); return }
            self.currentMgr = mgr

            var bufCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buf, _ in
                bufCount += 1
                if let channelData = buf.floatChannelData?[0] {
                    let n = Int(buf.frameLength); var sum: Float = 0
                    for i in 0..<n { let s = channelData[i]; sum += s * s }
                    let rms = n > 0 ? sqrt(sum / Float(n)) : 0
                    Task { @MainActor in self?.audioLevel = min(rms * 20, 1.0) }
                }
                Task { await mgr.streamAudio(buf) }
            }

            do {
                try await mgr.startStreaming(source: .microphone)
                self.log("startStreaming ok")
                do { try engine.start(); self.log("engine started") }
                catch {
                    self.fail("engine.start: \(error.localizedDescription)")
                    inputNode.removeTap(onBus: 0); return
                }
                self.audioEngine = engine
                guard self.sessionID == session, !Task.isCancelled else {
                    engine.stop(); inputNode.removeTap(onBus: 0); self.audioEngine = nil; return
                }
                self.state = .listening
                self.log("🎙 listening")
                self.resetSilenceTimer()

                for await update in await mgr.transcriptionUpdates {
                    guard self.sessionID == session, !Task.isCancelled else { break }
                    self.liveTranscript = update.text
                    self.lastTranscript = update.text
                    self.onPartial?(update.text)
                    self.log("partial: \"\(update.text)\"")
                }
                self.log("transcriptionUpdates stream ended")
            } catch {
                guard self.sessionID == session else { return }
                self.fail("streaming error: \(error.localizedDescription)")
            }
            engine.stop(); inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
            self.log("engine stopped, buf total=\(bufCount)")
        }
    }

    func stop() {
        guard state == .listening || state == .starting else { return }
        let mode = currentMode
        let wasListening = state == .listening
        let mgr = currentMgr; currentMgr = nil
        log("■ stop wasListening=\(wasListening)")
        cancelSilenceTimer()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop(); audioEngine = nil
        streamTask?.cancel(); streamTask = nil
        state = .idle
        guard wasListening else { return }

        Task {
            do {
                self.log("calling finish()…")
                let text = try await mgr?.finish() ?? ""
                self.log("finish() → \"\(text)\" (\(text.count) chars)")
                if !text.isEmpty {
                    self.onFinal?(text, mode)
                } else if !self.lastTranscript.isEmpty {
                    self.log("using lastTranscript fallback")
                    self.onFinal?(self.lastTranscript, mode)
                } else {
                    self.log("⚠ finish empty — nothing to dispatch")
                    DispatchQueue.main.async { NSSound.beep() }
                }
            } catch {
                self.log("finish() threw: \(error)")
                if !self.lastTranscript.isEmpty { self.onFinal?(self.lastTranscript, mode) }
            }
        }
    }

    func cancel() {
        log("cancel")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop(); audioEngine = nil
        streamTask?.cancel(); streamTask = nil
        cancelSilenceTimer()
        lastTranscript = ""; liveTranscript = ""
        audioLevel = 0
        state = .idle
        let mgr = currentMgr; currentMgr = nil
        Task { try? await mgr?.finish() }
    }

    private func resetSilenceTimer() {
        cancelSilenceTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 600)   // 10-minute auto-stop
        t.setEventHandler { [weak self] in
            guard let self = self, self.state == .listening else { return }
            self.log("10m timeout — stopping")
            self.stop()
        }
        t.resume(); silenceTimer = t
    }

    private func cancelSilenceTimer() { silenceTimer?.cancel(); silenceTimer = nil }

    private func fail(_ msg: String) {
        log("ERROR: \(msg)")
        streamTask?.cancel(); streamTask = nil
        audioLevel = 0; state = .error
    }
}
