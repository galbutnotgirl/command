// DictationLab — standalone test harness for the dictation pipeline.
//
// Purpose: iterate on mic capture + SFSpeechRecognizer in ISOLATION from the
// ClaudeCommand agent. This is a normal foreground app (shows in Dock, runs in
// the user's GUI/audio session) — NOT a launchd LSUIElement agent. If capture
// works here but not in the agent, the agent's launchd launch context is the
// culprit and capture must move to a foreground helper.
//
// UI: Start/Stop, live RMS meter (proves audio buffers are flowing), live
// partial transcript, final transcript, and a scrolling log. No hotkeys.
//
// Build: ./dictation-lab/build.sh  →  dictation-lab/DictationLab.app

import SwiftUI
import Speech
import AVFoundation
import CoreAudio
import AudioToolbox

// MARK: - HAL helpers

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

private func deviceName(_ dev: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cf: CFString = "" as CFString
    var sz = UInt32(MemoryLayout<CFString>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &cf)
    return cf as String
}

// MARK: - Recorder

@MainActor
final class Recorder: ObservableObject {
    enum State: String { case idle, starting, listening, error }

    @Published var state: State = .idle
    @Published var liveTranscript = ""
    @Published var finalTranscript = ""
    @Published var rms: Float = 0          // 0…~0.3 typical speech
    @Published var bufferCount = 0
    @Published var deviceLabel = ""
    @Published var log: [String] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private func L(_ s: String) {
        log.append(s)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        FileHandle.standardError.write(("[lab] " + s + "\n").data(using: .utf8)!)
    }

    func toggle() { state == .listening || state == .starting ? stop() : start() }

    func start() {
        guard state == .idle || state == .error else { return }
        state = .starting
        liveTranscript = ""; finalTranscript = ""; rms = 0; bufferCount = 0
        L("start — micAuth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speechAuth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")

        SFSpeechRecognizer.requestAuthorization { [weak self] sAuth in
            Task { @MainActor in
                guard let self = self else { return }
                self.L("speech auth → \(sAuth.rawValue)")
                guard sAuth == .authorized else { self.fail("Speech not authorized"); return }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        self.L("mic access → \(granted)")
                        guard granted else { self.fail("Mic denied"); return }
                        self.startEngine()
                    }
                }
            }
        }
    }

    private func startEngine() {
        guard let recognizer = recognizer, recognizer.isAvailable else { fail("Recognizer unavailable"); return }
        L("recognizer available, onDevice=\(recognizer.supportsOnDeviceRecognition)")

        let engine = AVAudioEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        let input = engine.inputNode

        // Bind explicit HAL default input device (launchd-context guard).
        var dev = defaultInputDeviceID()
        deviceLabel = "\(deviceName(dev)) (id \(dev))"
        if dev != 0, let au = input.audioUnit {
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            L("set input device id=\(dev) status=\(st)")
        }

        let inFmt = input.inputFormat(forBus: 0)
        let outFmt = input.outputFormat(forBus: 0)
        L("format in: \(inFmt.sampleRate)Hz \(inFmt.channelCount)ch | out: \(outFmt.channelCount)ch")

        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self = self else { return }
            self.request?.append(buf)
            // Compute RMS for the meter.
            var r: Float = 0
            if let ch = buf.floatChannelData {
                let n = Int(buf.frameLength)
                var s: Float = 0
                for i in 0..<n { let v = ch[0][i]; s += v * v }
                r = n > 0 ? (s / Float(n)).squareRoot() : 0
            }
            Task { @MainActor in
                self.bufferCount += 1
                self.rms = r
                if self.bufferCount % 20 == 0 { self.L("buf #\(self.bufferCount) rms=\(String(format: "%.4f", r)) ch=\(buf.format.channelCount)") }
            }
        }

        do {
            try engine.start()
            L("engine started")
        } catch {
            fail("engine.start: \(error.localizedDescription)"); return
        }

        self.engine = engine
        self.request = req
        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let result = result {
                    let t = result.bestTranscription.formattedString
                    self.liveTranscript = t
                    if result.isFinal { self.finalTranscript = t; self.L("FINAL: \"\(t)\"") }
                }
                if let error = error {
                    let ns = error as NSError
                    self.L("task error: \(ns.domain) \(ns.code) — \(ns.localizedDescription)")
                }
            }
        }

        state = .listening
        L("listening…")
    }

    func stop() {
        L("stop")
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Give the recognizer a moment to flush a final result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.task?.cancel(); self?.task = nil
        }
        engine = nil; request = nil
        rms = 0
        state = .idle
    }

    private func fail(_ msg: String) {
        L("ERROR: \(msg)")
        state = .error
        engine?.stop(); engine = nil; request = nil; task = nil
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var rec = Recorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Dictation Lab").font(.title2).bold()
                Spacer()
                Text(rec.state.rawValue.uppercased())
                    .font(.caption).bold()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(statusColor.opacity(0.2), in: Capsule())
                    .foregroundColor(statusColor)
            }

            HStack(spacing: 12) {
                Button(rec.state == .listening ? "Stop" : "Start") { rec.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                Text(rec.deviceLabel).font(.caption).foregroundColor(.secondary)
            }

            // RMS meter — the key signal: does real audio flow?
            VStack(alignment: .leading, spacing: 4) {
                Text("Mic level (RMS)  ·  buffers: \(rec.bufferCount)").font(.caption).foregroundColor(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.2))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(rec.rms > 0.001 ? Color.green : Color.red.opacity(0.5))
                            .frame(width: min(geo.size.width, geo.size.width * CGFloat(min(rec.rms * 6, 1))))
                    }
                }.frame(height: 16)
                Text(rec.rms > 0.001 ? "✓ audio flowing" : "no audio (flat = silent buffers)")
                    .font(.caption2).foregroundColor(rec.rms > 0.001 ? .green : .red)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Live transcript").font(.caption).foregroundColor(.secondary)
                Text(rec.liveTranscript.isEmpty ? "—" : rec.liveTranscript)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .padding(8).background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if !rec.finalTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Final").font(.caption).foregroundColor(.secondary)
                    Text(rec.finalTranscript).bold()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8).background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Text("Log").font(.caption).foregroundColor(.secondary)
            ScrollView {
                Text(rec.log.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            .frame(height: 160)
            .padding(8).background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(width: 480, height: 640)
    }

    private var statusColor: Color {
        switch rec.state {
        case .listening: return .green
        case .error: return .red
        case .starting: return .orange
        case .idle: return .secondary
        }
    }
}

struct DictationLabApp: App {
    var body: some Scene {
        WindowGroup("Dictation Lab") { ContentView() }
            .windowResizability(.contentSize)
    }
}

// Single-file build: explicit entry point (avoids @main + top-level-code clash).
DictationLabApp.main()
