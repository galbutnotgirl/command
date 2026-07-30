// Recorder.swift — Parakeet TDT on-device ASR via FluidAudio.
// Drop-in replacement for the old SFSpeechRecognizer-based SpeechEngine.

import Cocoa
import AVFoundation
import FluidAudio
import ClaudeCommandCore

// ─── Mode ──────────────────────────────────────────────────────────────────────

enum DictMode: Equatable { case insert, claude, claude2, customAction(actionID: String, triggerID: String) }

// AVAudioEngine owns tap buffers and may reuse them as soon as its callback
// returns. Deep-copy before crossing the AsyncStream boundary so transcription
// always reads stable bytes owned by this session.
private struct OwnedAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}

private final class DictationCaptureProbeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferCount = 0

    func recordBuffer() {
        lock.lock()
        bufferCount += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferCount
    }
}

let dictationSessionHealthURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/state/dictation-health.json")

func latestDictationSessionHealth() -> DictationSessionHealth? {
    guard let data = try? Data(contentsOf: dictationSessionHealthURL) else { return nil }
    return try? DictationSessionHealthCoding.decode(data)
}

private func copyAudioBuffer(_ source: AVAudioPCMBuffer) -> OwnedAudioBuffer? {
    guard let copy = AVAudioPCMBuffer(
        pcmFormat: source.format,
        frameCapacity: source.frameLength
    ) else { return nil }
    copy.frameLength = source.frameLength

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: source.audioBufferList)
    )
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard sourceBuffers.count == destinationBuffers.count else { return nil }

    for index in 0..<sourceBuffers.count {
        let byteCount = min(
            Int(sourceBuffers[index].mDataByteSize),
            Int(destinationBuffers[index].mDataByteSize)
        )
        guard byteCount == 0 || (
            sourceBuffers[index].mData != nil && destinationBuffers[index].mData != nil
        ) else { return nil }
        if byteCount > 0 {
            memcpy(destinationBuffers[index].mData, sourceBuffers[index].mData, byteCount)
        }
        destinationBuffers[index].mDataByteSize = UInt32(byteCount)
    }
    return OwnedAudioBuffer(value: copy)
}

// ─── Global recorder singleton ─────────────────────────────────────────────────
// @MainActor: Recorder is @MainActor-isolated; annotation ensures init runs on main actor.

@MainActor
let recorder = Recorder()

// ─── Recorder ──────────────────────────────────────────────────────────────────

@MainActor
final class Recorder: ObservableObject {
    typealias State = DictationCapturePhase
    enum ModelStatus { case notDownloaded, downloading(Double), ready, error(String) }

    @Published var state: State = .idle
    @Published var liveTranscript = ""
    @Published var modelStatus: ModelStatus = .notDownloaded
    @Published var audioLevel: Float = 0

    var onFinal:   ((String, DictMode) -> Void)?
    var onPartial: ((String) -> Void)?
    var onFinishedWithoutText: ((DictMode) -> Void)?
    var onFailure: ((String, DictMode) -> Void)?

    private(set) var currentMode: DictMode = .insert
    var prevBundle = ""

    private var loadedModels: AsrModels?
    private var currentMgr: SlidingWindowAsrManager?
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: DispatchSourceTimer?
    private var lastTranscript = ""
    private var sessionID = 0
    private var stopRequestedDuringStart = false
    private var streamTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<OwnedAudioBuffer>.Continuation?
    private var bufferFeederTask: Task<Void, Never>?
    private let stopTailPolicy = DEFAULT_DICTATION_STOP_TAIL_POLICY
    private var totalAudioSeconds: Double = 0
    private var activeSpeechSeconds: Double = 0
    private var secondsSinceStopTailActivity: Double = .infinity
    private var noiseFloorRMS: Float = 0.003
    private(set) var capturedBufferCount = 0
    private(set) var captureStartupBegan = false
    private var bufferCopyFailureCount = 0
    private var transcriptionUpdateCount = 0
    private var peakRMS: Float = 0
    private var inputDeviceName = "unknown"
    private var sessionHealth: DictationSessionHealth?
    private var captureProbeInProgress = false

    private func log(_ s: String) { DebugLog.shared.append(s) }

    private func persistSessionHealth() {
        guard let sessionHealth else { return }
        do {
            let directory = dictationSessionHealthURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try DictationSessionHealthCoding.encode(sessionHealth).write(
                to: dictationSessionHealthURL,
                options: .atomic
            )
        } catch {
            appendLog("[dictation] health snapshot write failed error=\(error.localizedDescription)")
        }
    }

    private func transitionSessionHealth(
        to stage: DictationSessionStage,
        finalCharacters: Int? = nil,
        failure: String? = nil,
        persist: Bool = true
    ) {
        sessionHealth?.transition(
            to: stage,
            inputDevice: inputDeviceName,
            capturedBuffers: capturedBufferCount,
            transcriptionUpdates: transcriptionUpdateCount,
            finalCharacters: finalCharacters,
            failure: failure
        )
        if persist { persistSessionHealth() }
    }

    private func updateSessionHealthMetrics(persist: Bool) {
        sessionHealth?.updateMetrics(
            inputDevice: inputDeviceName,
            capturedBuffers: capturedBufferCount,
            transcriptionUpdates: transcriptionUpdateCount
        )
        if persist { persistSessionHealth() }
    }

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
        if state.canStop { stop() }
        else if state.canStart { start(mode: mode) }
    }

    @discardableResult
    func start(mode: DictMode) -> Bool {
        guard !captureProbeInProgress else {
            appendLog("[dictation] start rejected because installed microphone probe is running")
            return false
        }
        guard state.canStart else {
            appendLog("[dictation] start rejected mode=\(mode) phase=\(state.rawValue)")
            return false
        }
        guard loadedModels != nil else {
            fail("models not loaded")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Model not downloaded"
                alert.informativeText = "Open Settings -> Dictation Settings and click Download to get the Parakeet model (~650 MB), then try again."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    settingsWindow.show(tab: .dictSettings)
                }
            }
            return false
        }
        sessionID += 1
        let mySession = sessionID
        if let previous = latestDictationSessionHealth(), previous.indicatesInterruptedCapture {
            appendLog("[dictation] previous session interrupted \(previous.diagnosticSummary)")
        }
        currentMode = mode
        stopRequestedDuringStart = false
        lastTranscript = ""; liveTranscript = ""
        totalAudioSeconds = 0; activeSpeechSeconds = 0
        secondsSinceStopTailActivity = .infinity; noiseFloorRMS = 0.003
        capturedBufferCount = 0; bufferCopyFailureCount = 0; transcriptionUpdateCount = 0
        captureStartupBegan = false
        peakRMS = 0; inputDeviceName = "unknown"
        sessionHealth = DictationSessionHealth(sessionID: mySession, mode: String(describing: mode))
        persistSessionHealth()
        state = .starting
        log("▶ session \(mySession) start mode=\(mode)")
        appendLog("[dictation] start session=\(mySession) mode=\(mode) deviceAuthorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")

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
        return true
    }

    func runCaptureProbe(
        duration: TimeInterval = 0.8,
        completion: @escaping (DictationCaptureProbeResult) -> Void
    ) {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let authorization = String(describing: authorizationStatus)
        guard authorizationStatus == .authorized else {
            completion(DictationCaptureProbeResult(
                status: .microphoneDenied,
                authorization: authorization,
                failure: "Command does not have microphone access."
            ))
            return
        }
        guard state.canStart, audioEngine == nil, !captureProbeInProgress else {
            completion(DictationCaptureProbeResult(
                status: .recorderBusy,
                authorization: authorization,
                failure: "Dictation recorder is busy."
            ))
            return
        }

        captureProbeInProgress = true
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let inputDevice = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        let duration = min(max(duration, 0.25), 2.0)
        let durationMilliseconds = Int((duration * 1_000).rounded())
        guard format.sampleRate > 0, format.channelCount > 0 else {
            captureProbeInProgress = false
            completion(DictationCaptureProbeResult(
                status: .inputUnavailable,
                authorization: authorization,
                inputDevice: inputDevice,
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                durationMilliseconds: durationMilliseconds,
                failure: "Default microphone has no usable input format."
            ))
            return
        }

        let accumulator = DictationCaptureProbeAccumulator()
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in
            accumulator.recordBuffer()
        }
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            captureProbeInProgress = false
            completion(DictationCaptureProbeResult(
                status: .engineStartFailed,
                authorization: authorization,
                inputDevice: inputDevice,
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                durationMilliseconds: durationMilliseconds,
                failure: error.localizedDescription
            ))
            return
        }

        appendLog("[dictation-probe] started device=\(inputDevice.debugDescription) durationMs=\(durationMilliseconds)")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self?.captureProbeInProgress = false
            let result = DictationCaptureProbeResult.completed(
                authorization: authorization,
                capturedBuffers: accumulator.snapshot(),
                inputDevice: inputDevice,
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                durationMilliseconds: durationMilliseconds
            )
            appendLog("[dictation-probe] completed status=\(result.status.rawValue) buffers=\(result.capturedBuffers) device=\(inputDevice.debugDescription)")
            completion(result)
        }
    }

    private func beginStreaming(session: Int) {
        guard let models = loadedModels else { fail("loadedModels nil"); return }
        transitionSessionHealth(to: .loadingModel)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        inputDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        log("audio device: \(inputDeviceName); format: \(hwFormat.sampleRate)Hz ch=\(hwFormat.channelCount)")

        streamTask = Task {
            let mgr = SlidingWindowAsrManager(config: .default)
            do { try await mgr.loadModels(models) }
            catch { self.fail("mgr.loadModels: \(error)"); return }
            guard self.sessionID == session, !Task.isCancelled else {
                self.log("startup abandoned before audio tap session=\(session)")
                return
            }
            self.captureStartupBegan = true
            self.currentMgr = mgr

            var bufCount = 0
            // Buffers are fed through an AsyncStream (not one detached Task per buffer)
            // so stop() can deterministically drain every enqueued buffer — including
            // the last 1-2 captured during the post-stop grace window below — instead
            // of guessing how long in-flight Tasks need to land.
            let (bufStream, bufContinuation) = AsyncStream<OwnedAudioBuffer>.makeStream()
            self.audioContinuation = bufContinuation
            self.bufferFeederTask = Task {
                for await buf in bufStream { await mgr.streamAudio(buf.value) }
                self.log("buffer feeder drained")
            }
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buf, _ in
                bufCount += 1
                if let channelData = buf.floatChannelData?[0] {
                    let n = Int(buf.frameLength); var sum: Float = 0
                    for i in 0..<n { let s = channelData[i]; sum += s * s }
                    let rms = n > 0 ? sqrt(sum / Float(n)) : 0
                    let seconds = hwFormat.sampleRate > 0 ? Double(buf.frameLength) / hwFormat.sampleRate : 0
                    Task { @MainActor in self?.observeAudioFrame(rms: rms, seconds: seconds) }
                }
                if let ownedBuffer = copyAudioBuffer(buf) {
                    bufContinuation.yield(ownedBuffer)
                } else {
                    Task { @MainActor in
                        self?.bufferCopyFailureCount += 1
                        self?.log("audio buffer copy failed")
                    }
                }
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
                self.transitionSessionHealth(to: .listening)
                self.log("🎙 listening")
                appendLog("[dictation] listening session=\(session) device=\(self.inputDeviceName.debugDescription)")
                if self.stopRequestedDuringStart {
                    self.stopRequestedDuringStart = false
                    self.log("stop was requested during startup — stopping now that audio is live")
                    self.stop()
                    return
                }
                self.resetSilenceTimer()

                for await update in await mgr.transcriptionUpdates {
                    guard self.sessionID == session, !Task.isCancelled else { break }
                    self.transcriptionUpdateCount += 1
                    self.updateSessionHealthMetrics(
                        persist: self.transcriptionUpdateCount == 1 || self.transcriptionUpdateCount % 10 == 0
                    )
                    self.liveTranscript = update.text
                    self.lastTranscript = update.text
                    self.onPartial?(update.text)
                    self.log("partial: \"\(update.text)\"")
                }
                self.log("transcriptionUpdates stream ended")
            } catch is CancellationError {
                self.log("stream task cancelled")
            } catch {
                guard self.sessionID == session else { return }
                self.fail("streaming error: \(error.localizedDescription)")
            }
            engine.stop(); inputNode.removeTap(onBus: 0)
            if self.audioEngine === engine { self.audioEngine = nil }
            self.log("engine stopped, buf total=\(bufCount)")
        }
    }

    func stop() {
        guard state.canStop else { return }
        let finishingSession = sessionID
        let mode = currentMode
        let wasListening = state == .listening
        log("■ stop wasListening=\(wasListening)")
        cancelSilenceTimer()
        if !wasListening {
            stopRequestedDuringStart = true
            log("stop requested while startup still in flight")
            return
        }
        let mgr = currentMgr; currentMgr = nil
        state = .finishing
        transitionSessionHealth(to: .finishing)

        let capturedStreamTask = streamTask
        streamTask = nil
        let stopTailNanoseconds = stopTailPolicy.tailNanoseconds(
            for: audioLevel,
            secondsSinceActiveSpeech: secondsSinceStopTailActivity,
            capturedSpeechSeconds: activeSpeechSeconds
        )
        let stopLevel = String(format: "%.3f", audioLevel)
        let recentSpeech = String(format: "%.3f", secondsSinceStopTailActivity)
        let activeDuration = String(format: "%.3f", activeSpeechSeconds)
        let totalDuration = String(format: "%.3f", totalAudioSeconds)
        appendLog("[dictation] stop session=\(finishingSession) tailMs=\(stopTailNanoseconds / 1_000_000) level=\(stopLevel) recentSpeech=\(recentSpeech)s active=\(activeDuration)s total=\(totalDuration)s")
        // Don't tear the tap/engine down synchronously here — that was the actual
        // source of dropped tail words, not the flush step below. People keep
        // talking through the last syllable as they release the key/hotkey;
        // removeTap() discards whatever's in the CURRENTLY-FILLING buffer (up to
        // ~85ms of audio at 4096 frames/48kHz) that hasn't hit a full callback yet.
        // No amount of waiting for finish() can recover audio that was never
        // captured. Keep the mic open a little longer than the stop signal instead.
        let engineToStop = audioEngine
        audioEngine = nil
        let capturedFeederTask = bufferFeederTask
        bufferFeederTask = nil
        let capturedContinuation = audioContinuation
        audioContinuation = nil

        Task {
            try? await Task.sleep(nanoseconds: stopTailNanoseconds)
            engineToStop?.inputNode.removeTap(onBus: 0)
            engineToStop?.stop()

            // The buffers captured during the grace window above are still sitting in
            // the feeder's queue. Finishing the continuation and awaiting the feeder
            // drains every one of them deterministically — no sleep, no guessing how
            // long delivery to the ASR manager takes under system load.
            capturedContinuation?.finish()
            await capturedFeederTask?.value
            capturedStreamTask?.cancel()   // now safe to end the update loop
            do {
                self.log("calling finish()…")
                let text = try await mgr?.finish() ?? ""
                self.log("finish() → \"\(text)\" (\(text.count) chars), lastTranscript=\(self.lastTranscript.count) chars")
                // Use whichever is longer: finish() should be complete, but if it
                // returns less than the last partial (e.g. model flush gap), keep the
                // partial — it's less likely to have dropped tail words than finish().
                let best = preferredDictationTranscript(final: text, lastPartial: self.lastTranscript)
                appendLog("[dictation] finish session=\(finishingSession) finalChars=\(text.count) partialChars=\(self.lastTranscript.count) selectedChars=\(best.count)")
                await capturedStreamTask?.value
                guard self.sessionID == finishingSession else { return }
                self.state = .idle
                self.audioLevel = 0
                if self.shouldDispatchDictation(best) {
                    self.transitionSessionHealth(to: .completed, finalCharacters: best.count)
                    self.onFinal?(best, mode)
                } else {
                    self.transitionSessionHealth(to: .empty, finalCharacters: best.count)
                    self.appendEmptyDiagnostics(session: finishingSession, mode: mode)
                    self.log("⚠ dictation suppressed — textChars=\(best.count) activeSpeech=\(String(format: "%.3f", self.activeSpeechSeconds))s totalAudio=\(String(format: "%.3f", self.totalAudioSeconds))s min=\(String(format: "%.1f", self.minimumDictationDuration()))s")
                    self.onFinishedWithoutText?(mode)
                }
            } catch {
                self.log("finish() threw: \(error)")
                await capturedStreamTask?.value
                guard self.sessionID == finishingSession else { return }
                self.state = .idle
                self.audioLevel = 0
                if self.shouldDispatchDictation(self.lastTranscript) {
                    self.transitionSessionHealth(to: .completed, finalCharacters: self.lastTranscript.count)
                    self.onFinal?(self.lastTranscript, mode)
                } else {
                    self.transitionSessionHealth(to: .empty, finalCharacters: self.lastTranscript.count)
                    self.appendEmptyDiagnostics(session: finishingSession, mode: mode)
                    self.onFinishedWithoutText?(mode)
                }
            }
        }
    }

    func cancel() {
        log("cancel")
        appendLog("[dictation] cancel session=\(sessionID) phase=\(state.rawValue) buffers=\(capturedBufferCount)")
        transitionSessionHealth(to: .cancelled)
        sessionID += 1
        stopRequestedDuringStart = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop(); audioEngine = nil
        streamTask?.cancel(); streamTask = nil
        audioContinuation?.finish(); audioContinuation = nil
        bufferFeederTask?.cancel(); bufferFeederTask = nil
        cancelSilenceTimer()
        lastTranscript = ""; liveTranscript = ""
        totalAudioSeconds = 0; activeSpeechSeconds = 0
        captureStartupBegan = false
        secondsSinceStopTailActivity = .infinity; noiseFloorRMS = 0.003
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

    private func observeAudioFrame(rms: Float, seconds: Double) {
        capturedBufferCount += 1
        if capturedBufferCount == 1,
           let stage = sessionHealth?.stage,
           stage == .loadingModel || stage == .listening {
            transitionSessionHealth(to: .capturing)
        }
        peakRMS = max(peakRMS, rms)
        totalAudioSeconds += seconds
        let gate = DictationActivityGate(minimumDuration: minimumDictationDuration())
        let threshold = gate.threshold(noiseFloor: noiseFloorRMS)
        let active = rms >= threshold
        if active {
            activeSpeechSeconds += seconds
        } else {
            // Slow adaptive floor: learn quiet room tone, ignore louder bursts.
            noiseFloorRMS = max(0.0005, min(0.03, (noiseFloorRMS * 0.96) + (rms * 0.04)))
        }
        audioLevel = min(rms * 20, 1.0)
        if audioLevel > stopTailPolicy.activeAudioLevelThreshold {
            secondsSinceStopTailActivity = 0
        } else if secondsSinceStopTailActivity.isFinite {
            secondsSinceStopTailActivity += seconds
        }
    }

    private func minimumDictationDuration() -> Double {
        let value = UserDefaults.standard.object(forKey: VoiceSettingsKeys.minDictationDuration) as? Double
        return min(max(value ?? VoiceSettingsDefaults.minDictationDuration, 0), 1.5)
    }

    private func shouldDispatchDictation(_ text: String) -> Bool {
        let gate = DictationActivityGate(minimumDuration: minimumDictationDuration())
        return gate.shouldDispatch(text: text, recordedSeconds: totalAudioSeconds)
    }

    private func appendEmptyDiagnostics(session: Int, mode: DictMode) {
        appendLog("[dictation] empty session=\(session) mode=\(mode) buffers=\(capturedBufferCount) copyFailures=\(bufferCopyFailureCount) updates=\(transcriptionUpdateCount) peakRMS=\(String(format: "%.5f", peakRMS)) device=\(inputDeviceName.debugDescription)")
    }

    private func fail(_ msg: String) {
        log("ERROR: \(msg)")
        if state == .loading || state == .starting || state == .listening || state == .finishing {
            transitionSessionHealth(to: .failed, failure: msg)
        }
        stopRequestedDuringStart = false
        streamTask?.cancel(); streamTask = nil
        audioLevel = 0; state = .error
        onFailure?(msg, currentMode)
    }
}
