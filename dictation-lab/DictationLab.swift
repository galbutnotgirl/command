// DictationLab — standalone dictation menu-bar app.
//
// Menu-bar icon (rounded square) turns purple while recording. Dock icon is orange.
// Global hotkeys: F10 = insert at cursor, ⌥F10 = send to Claude.
// Settings pane lets you rebind both actions and shows permission state.
// No dependency on the ClaudeCommand agent.
//
// Build: ./dictation-lab/build.sh → dictation-lab/DictationLab.app
// Launch via `open` (not launchd) to get a proper GUI audio session.

import Cocoa
import SwiftUI
import Speech
import AVFoundation
import CoreAudio
import AudioToolbox
import Carbon.HIToolbox
import ApplicationServices

// ─── HAL helpers ──────────────────────────────────────────────────────────────

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

private func deviceNameFor(_ dev: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &cf)
    return (cf?.takeRetainedValue() as String?) ?? "Unknown"
}

// ─── Mode ──────────────────────────────────────────────────────────────────────

enum DictMode { case insert, claude }

// ─── Keycode / modifier helpers ────────────────────────────────────────────────

private let FKEY_NAMES: [UInt32: String] = [
    122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",
    101:"F9",109:"F10",103:"F11",111:"F12"
]
private let LETTER_NAMES: [UInt32: String] = [
    0:"A",11:"B",8:"C",2:"D",14:"E",3:"F",5:"G",4:"H",34:"I",38:"J",
    40:"K",37:"L",46:"M",45:"N",31:"O",35:"P",12:"Q",15:"R",1:"S",17:"T",
    32:"U",9:"V",13:"W",7:"X",16:"Y",6:"Z",18:"1",19:"2",20:"3",21:"4",
    23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",49:"Space"
]

func keycodeLabel(_ kc: UInt32) -> String {
    FKEY_NAMES[kc] ?? LETTER_NAMES[kc] ?? "?"
}

func humanShortcut(keycode: UInt32, mods: UInt32) -> String {
    if keycode == 0 { return "—" }
    var s = ""
    if mods & 4096 != 0 { s += "⌃" }
    if mods & 2048 != 0 { s += "⌥" }
    if mods & 512  != 0 { s += "⇧" }
    if mods & 256  != 0 { s += "⌘" }
    return s + keycodeLabel(keycode)
}

// ─── Binding storage ───────────────────────────────────────────────────────────

final class HotkeyState: ObservableObject {
    @Published var insertKeycode: UInt32
    @Published var insertMods: UInt32
    @Published var claudeKeycode: UInt32
    @Published var claudeMods: UInt32

    // Shared instance — settings view + app controller both use this.
    static let shared = HotkeyState()

    private init() {
        let ud = UserDefaults.standard
        if !ud.bool(forKey: "hk_init") {
            ud.set(109,  forKey: "hk_insert_kc");  ud.set(0,    forKey: "hk_insert_mods")
            ud.set(109,  forKey: "hk_claude_kc");  ud.set(2048, forKey: "hk_claude_mods")
            ud.set(true, forKey: "hk_init")
        }
        insertKeycode = UInt32(ud.integer(forKey: "hk_insert_kc"))
        insertMods    = UInt32(ud.integer(forKey: "hk_insert_mods"))
        claudeKeycode = UInt32(ud.integer(forKey: "hk_claude_kc"))
        claudeMods    = UInt32(ud.integer(forKey: "hk_claude_mods"))
    }

    func save() {
        let ud = UserDefaults.standard
        ud.set(Int(insertKeycode), forKey: "hk_insert_kc")
        ud.set(Int(insertMods),   forKey: "hk_insert_mods")
        ud.set(Int(claudeKeycode), forKey: "hk_claude_kc")
        ud.set(Int(claudeMods),   forKey: "hk_claude_mods")
    }

    var insertHuman: String { humanShortcut(keycode: insertKeycode, mods: insertMods) }
    var claudeHuman: String { humanShortcut(keycode: claudeKeycode, mods: claudeMods) }
}

// ─── Recorder (the working dictation engine) ───────────────────────────────────

final class Recorder: ObservableObject {
    enum State: String { case idle, starting, listening, error }

    @Published var state: State = .idle
    @Published var liveTranscript = ""

    var onFinal: ((String, DictMode) -> Void)?
    private(set) var currentMode: DictMode = .insert
    var prevBundle = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: DispatchSourceTimer?
    private var lastTranscript = ""
    private var tapBufCount = 0
    private var engineConfigObserver: NSObjectProtocol?
    private var sessionID = 0
    private var pendingDispatch: DispatchWorkItem?

    private func log(_ s: String) {
        NSLog("[dictlab] %@", s)
    }

    func toggle(mode: DictMode) {
        if state == .listening || state == .starting { stop() }
        else { start(mode: mode) }
    }

    func start(mode: DictMode) {
        guard state == .idle || state == .error else { return }
        task?.cancel(); task = nil   // discard stale task from previous stop()
        sessionID += 1
        currentMode = mode
        lastTranscript = ""; liveTranscript = ""
        state = .starting
        log("start mode=\(mode)")

        // Fast path: grants already cached — skip async permission chain entirely.
        if SFSpeechRecognizer.authorizationStatus() == .authorized &&
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            startEngine()
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] sAuth in
            Task { @MainActor in
                guard let self = self else { return }
                self.log("speechAuth → \(sAuth.rawValue)")
                guard sAuth == .authorized else { self.fail("Speech recognition not authorized."); return }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        self.log("micAccess → \(granted)")
                        guard granted else { self.fail("Microphone access denied."); return }
                        self.startEngine()
                    }
                }
            }
        }
    }

    private func startEngine() {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            fail("Speech recognizer unavailable."); return
        }
        log("recognizer available, onDevice=\(recognizer.supportsOnDeviceRecognition)")

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // On-device recognition: no server round-trip, faster results.
        // Falls back to server if on-device model unavailable (Dictation not enabled).
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        let engine = AVAudioEngine()
        tapBufCount = 0
        installTapOnEngine(engine)
        self.request = req

        do {
            try engine.start()
            log("engine started")
        } catch {
            fail("engine.start: \(error.localizedDescription)"); return
        }

        self.engine = engine
        state = .listening
        log("listening…")

        // Re-install tap and restart engine whenever HAL device assignment changes.
        // Without this the tap goes dead after the initial 51→161→78 device churn.
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.state == .listening, let eng = self.engine else { return }
            self.log("engine config changed — reinstalling tap")
            self.installTapOnEngine(eng)
            do { try eng.start(); self.log("engine restarted OK") }
            catch { self.fail("engine restart: \(error.localizedDescription)") }
        }

        let mySession = sessionID
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self, self.sessionID == mySession else { return }
                if let result = result {
                    let t = result.bestTranscription.formattedString
                    self.liveTranscript = t
                    self.lastTranscript = t
                    if result.isFinal { self.finalize(t) }
                }
                if let error = error {
                    let ns = error as NSError
                    self.log("task error: \(ns.domain) \(ns.code) — \(ns.localizedDescription)")
                    if ns.code == 216 || ns.code == 203 { return } // normal end / no speech
                    self.fail(error.localizedDescription)
                }
            }
        }

        resetSilenceTimer()
    }

    private func installTapOnEngine(_ engine: AVAudioEngine) {
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        var dev = defaultInputDeviceID()
        let devLabel = "\(deviceNameFor(dev)) (id \(dev))"
        if dev != 0, let au = input.audioUnit {
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            log("device: \(devLabel) bindStatus=\(st)")
        }

        let inFmt = input.inputFormat(forBus: 0)
        log("tap fmt: \(inFmt.sampleRate)Hz \(inFmt.channelCount)ch")

        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
            guard let self = self else { return }
            self.request?.append(buf)
            self.tapBufCount += 1
            if self.tapBufCount % 20 == 0 {
                var r: Float = 0
                if let ch = buf.floatChannelData {
                    let n = Int(buf.frameLength)
                    var s: Float = 0
                    for i in 0..<n { let v = ch[0][i]; s += v * v }
                    r = n > 0 ? (s / Float(n)).squareRoot() : 0
                }
                Task { @MainActor in
                    self.log("buf #\(self.tapBufCount) rms=\(String(format: "%.4f", r))")
                }
            }
        }
    }

    func stop() {
        guard state == .listening || state == .starting else { return }
        let mode = currentMode
        log("stop — endAudio, 250ms window for final partial")
        cancelSilenceTimer()
        if let obs = engineConfigObserver { NotificationCenter.default.removeObserver(obs); engineConfigObserver = nil }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        engine = nil; request = nil
        state = .idle
        // Keep task alive briefly so the recognizer can deliver last-word partial.
        // finalize() cancels this and wins if isFinal arrives first (more complete text).
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.task?.cancel(); self.task = nil
            let text = self.lastTranscript   // read latest, not snapshot from stop() time
            if !text.isEmpty { self.onFinal?(text, mode) }
        }
        pendingDispatch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func cancel() {
        log("cancel")
        pendingDispatch?.cancel(); pendingDispatch = nil
        cancelSilenceTimer()
        if let obs = engineConfigObserver { NotificationCenter.default.removeObserver(obs); engineConfigObserver = nil }
        task?.cancel(); task = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil; request = nil
        lastTranscript = ""; liveTranscript = ""
        state = .idle
    }

    private func finalize(_ text: String) {
        guard !text.isEmpty else { return }
        // Cancel stop()'s 250ms fallback — isFinal result is more complete.
        pendingDispatch?.cancel(); pendingDispatch = nil
        let mode = currentMode
        cancelSilenceTimer()
        if let obs = engineConfigObserver { NotificationCenter.default.removeObserver(obs); engineConfigObserver = nil }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil
        engine = nil; request = nil
        liveTranscript = text
        state = .idle
        onFinal?(text, mode)
    }

    private func resetSilenceTimer() {
        cancelSilenceTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 120)
        t.setEventHandler { [weak self] in
            guard let self = self, self.state == .listening else { return }
            let text = self.lastTranscript
            let mode = self.currentMode
            self.cancelSilenceTimer()
            if let obs = self.engineConfigObserver { NotificationCenter.default.removeObserver(obs); self.engineConfigObserver = nil }
            self.engine?.stop()
            self.engine?.inputNode.removeTap(onBus: 0)
            self.task?.cancel(); self.task = nil
            self.engine = nil; self.request = nil
            self.state = .idle
            if !text.isEmpty { self.onFinal?(text, mode) }
        }
        t.resume()
        silenceTimer = t
    }

    private func cancelSilenceTimer() { silenceTimer?.cancel(); silenceTimer = nil }

    private func fail(_ msg: String) {
        log("ERROR: \(msg)")
        if let obs = engineConfigObserver { NotificationCenter.default.removeObserver(obs); engineConfigObserver = nil }
        engine?.stop(); engine = nil; request = nil; task = nil
        state = .error
    }
}

// ─── Purple dot overlay ────────────────────────────────────────────────────────

private final class DotState: ObservableObject {
    @Published var shown = false
}

private struct DotView: View {
    @ObservedObject var s: DotState

    var body: some View {
        Capsule()
            .fill(LinearGradient(
                colors: [Color(red: 0.74, green: 0.26, blue: 1.0),
                         Color(red: 0.50, green: 0.16, blue: 0.90)],
                startPoint: .leading, endPoint: .trailing))
            .frame(width: 44, height: 5)
            .shadow(color: Color.purple.opacity(0.9), radius: 7, x: 0, y: 1)
            .scaleEffect(x: s.shown ? 1.0 : 0.05, y: s.shown ? 1.0 : 0.15)
            .opacity(s.shown ? 1.0 : 0)
            .animation(.spring(response: 0.27, dampingFraction: 0.55), value: s.shown)
            .frame(width: 76, height: 20)
    }
}

final class OverlayController {
    private var panel: NSPanel?
    private var escMonitor: Any?
    private let dot = DotState()
    private var hideToken = 0

    func show(rec: Recorder) {
        hideToken += 1               // cancel any pending orderOut from previous hide()
        if panel == nil { build() }
        position()
        panel?.orderFront(nil)
        installEscMonitor(rec: rec)
        dot.shown = true
    }

    func hide() {
        removeEscMonitor()
        dot.shown = false
        let tok = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.hideToken == tok else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func build() {
        let w: CGFloat = 76, h: CGFloat = 20
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = false; p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.ignoresMouseEvents = true

        let host = NSHostingView(rootView: DotView(s: dot))
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        p.contentView = host
        panel = p
    }

    private func position() {
        guard let p = panel, let screen = NSScreen.main else { return }
        // Just below camera: top center of screen, inside menu-bar zone
        p.setFrameOrigin(NSPoint(x: screen.frame.midX - 38,
                                 y: screen.frame.maxY - 40))
    }

    private func installEscMonitor(rec: Recorder) {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { DispatchQueue.main.async { rec.cancel(); self?.hide() } }
        }
    }

    private func removeEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }
}

// ─── Settings window ───────────────────────────────────────────────────────────

private struct SettingsContent: View {
    @ObservedObject var hk: HotkeyState
    @State var recording: String? = nil     // "insert" | "claude" | nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dictation Lab").font(.title2).bold()

            // Hotkeys
            GroupBox(label: Text("Hotkeys").bold()) {
                VStack(spacing: 0) {
                    hotkeyRow(label: "Dictate (insert at cursor)",
                              detail: "Transcribes speech and types it at your cursor.",
                              human: hk.insertHuman, key: "insert")
                    Divider()
                    hotkeyRow(label: "Dictate → Claude",
                              detail: "Opens a new Claude session with your words.",
                              human: hk.claudeHuman, key: "claude")
                }
                .padding(.vertical, 4)
            }

            // Permissions
            GroupBox(label: Text("Permissions").bold()) {
                VStack(spacing: 8) {
                    permRow("Microphone",
                            ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                            action: { AVCaptureDevice.requestAccess(for: .audio) { _ in } })
                    permRow("Speech Recognition",
                            ok: SFSpeechRecognizer.authorizationStatus() == .authorized,
                            action: { SFSpeechRecognizer.requestAuthorization { _ in } })
                    permRow("Accessibility (needed for paste-at-cursor)",
                            ok: AXIsProcessTrusted(),
                            action: {
                                let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                                _ = AXIsProcessTrustedWithOptions(o)
                            })
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 540, height: 420)
        .onAppear { recording = nil }
        .background(KeyCaptureView(recording: $recording, hk: hk))
    }

    @ViewBuilder
    private func hotkeyRow(label: String, detail: String, human: String, key: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Group {
                if recording == key {
                    Text("Press keys…").foregroundColor(.accentColor).italic()
                } else {
                    Text(human).font(.system(.body, design: .rounded)).bold()
                }
            }.frame(width: 100, alignment: .trailing)
            Button(recording == key ? "…" : "Set") {
                if recording == key { recording = nil; reregisterHotkeys() }
                else { unregisterHotkeys(); recording = key }
            }.frame(width: 48)
            Button("Clear") {
                if key == "insert" { hk.insertKeycode = 0; hk.insertMods = 0 }
                else               { hk.claudeKeycode = 0; hk.claudeMods = 0 }
                hk.save(); reregisterHotkeys()
            }
            .disabled(key == "insert" ? hk.insertKeycode == 0 : hk.claudeKeycode == 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func permRow(_ title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red).frame(width: 18)
            Text(title)
            Spacer()
            if !ok { Button("Enable") { action() }.controlSize(.small) }
        }
    }
}

// NSViewRepresentable shim: captures raw key events for hotkey recording.
private struct KeyCaptureView: NSViewRepresentable {
    @Binding var recording: String?
    var hk: HotkeyState

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onKey = { keycode, mods in
            guard let action = recording else { return }
            if action == "insert" { hk.insertKeycode = keycode; hk.insertMods = mods }
            else                  { hk.claudeKeycode = keycode; hk.claudeMods = mods }
            hk.save()
            recording = nil
            reregisterHotkeys()
        }
        return v
    }

    func updateNSView(_ v: KeyView, context: Context) { v.isActive = recording != nil }

    class KeyView: NSView {
        var onKey: ((UInt32, UInt32) -> Void)?
        var isActive = false

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard isActive, event.keyCode != 53 else { // 53 = esc
                if event.keyCode == 53 { onKey = nil /* cancel handled by parent */ }
                super.keyDown(with: event)
                return
            }
            let kc = UInt32(event.keyCode)
            let mods: UInt32 = {
                var m: UInt32 = 0
                let f = event.modifierFlags
                if f.contains(.command) { m |= 256 }
                if f.contains(.shift)   { m |= 512 }
                if f.contains(.option)  { m |= 2048 }
                if f.contains(.control) { m |= 4096 }
                return m
            }()
            onKey?(kc, mods)
        }
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var keyMonitor: Any?

    func show() {
        if window == nil { build() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let host = NSHostingController(rootView: SettingsContent(hk: HotkeyState.shared))
        let w = NSWindow(contentViewController: host)
        w.title = "Dictation Lab"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 540, height: 420))
        w.center()
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

let settingsController = SettingsWindowController()

// ─── Icons ─────────────────────────────────────────────────────────────────────

// Menu-bar icon: small rounded square. isTemplate=true so contentTintColor turns it purple when recording.
private func brandIcon() -> NSImage {
    let h = NSStatusBar.system.thickness
    let img = NSImage(size: NSSize(width: h, height: h), flipped: false) { full in
        let inset = full.width * 0.18
        let rect = full.insetBy(dx: inset, dy: inset)
        let radius = rect.width * 0.22
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.isTemplate = true
    return img
}

// Dock/Finder icon: orange square so the lab is visually distinct from ClaudeCommand.
private func dockIcon() -> NSImage {
    let size: CGFloat = 256
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { full in
        let inset = size * 0.08
        let rect = full.insetBy(dx: inset, dy: inset)
        let radius = rect.width * 0.22
        NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    return img
}

// ─── Carbon global hotkeys ─────────────────────────────────────────────────────

private var hkActions: [UInt32: DictMode] = [:]
private var hkRefs: [EventHotKeyRef?] = []

private let hkHandler: EventHandlerUPP = { _, event, _ -> OSStatus in
    var hkID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    if let mode = hkActions[hkID.id] {
        DispatchQueue.main.async { appController.triggerDictation(mode: mode) }
    }
    return noErr
}

func registerHotkeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), hkHandler, 1, &spec, nil, nil)
    reregisterHotkeys()
}

func reregisterHotkeys() {
    unregisterHotkeys()
    let hk = HotkeyState.shared
    let sig = OSType(0x44494354) // 'DICT'
    let pairs: [(UInt32, UInt32, DictMode)] = [
        (hk.insertKeycode, hk.insertMods, .insert),
        (hk.claudeKeycode, hk.claudeMods, .claude)
    ]
    for (i, (kc, mods, mode)) in pairs.enumerated() {
        guard kc != 0 else { continue }
        let id = EventHotKeyID(signature: sig, id: UInt32(i + 1))
        hkActions[UInt32(i + 1)] = mode
        var ref: EventHotKeyRef?
        RegisterEventHotKey(kc, mods, id, GetApplicationEventTarget(), 0, &ref)
        hkRefs.append(ref)
    }
}

func unregisterHotkeys() {
    for ref in hkRefs { if let r = ref { UnregisterEventHotKey(r) } }
    hkRefs.removeAll(); hkActions.removeAll()
}

// ─── App controller ────────────────────────────────────────────────────────────

final class AppController: NSObject {
    private let rec = Recorder()
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem!

    // Push-to-talk / double-tap-lock state machine
    private enum TrigMode { case idle, pushToTalk, lock }
    private var trigMode: TrigMode = .idle
    private var ptTimer: Timer?
    private var lastPressTime: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.35

    override init() {
        super.init()
        setupStatusItem()
        setupRecorder()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        NSApp.applicationIconImage = dockIcon()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let btn = statusItem.button else { return }
        btn.image = brandIcon()
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        let hk = HotkeyState.shared
        addItem(m, "Dictate (insert)", action: #selector(triggerInsert),
                key: hk.insertKeycode, mods: hk.insertMods)
        addItem(m, "Dictate → Claude", action: #selector(triggerClaude),
                key: hk.claudeKeycode, mods: hk.claudeMods)
        m.addItem(.separator())
        addItem(m, "Settings…", action: #selector(openSettings))
        addItem(m, "Quit", action: #selector(quit), shortcutKey: "q")
        return m
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, action: Selector,
                         key: UInt32 = 0, mods: UInt32 = 0, shortcutKey: String = "") -> NSMenuItem {
        let it = menu.addItem(withTitle: title, action: action, keyEquivalent: shortcutKey)
        it.target = self
        if key != 0 {
            let fkeys: [UInt32: UInt32] = [
                101: 0xF70C, 100: 0xF70B, 98: 0xF70A, 97: 0xF709, 96: 0xF708,
                109: 0xF70D, 103: 0xF70E, 111: 0xF70F, 122: 0xF704, 120: 0xF705
            ]
            if let scalar = fkeys[key], let u = Unicode.Scalar(scalar) {
                it.keyEquivalent = String(u)
                var f: NSEvent.ModifierFlags = []
                if mods & 256 != 0  { f.insert(.command) }
                if mods & 512 != 0  { f.insert(.shift) }
                if mods & 2048 != 0 { f.insert(.option) }
                if mods & 4096 != 0 { f.insert(.control) }
                it.keyEquivalentModifierMask = f
            }
        }
        return it
    }

    private func setRecording(_ on: Bool) {
        statusItem.button?.contentTintColor = on ? .systemPurple : nil
        // Rebuild menu so shortcut display stays current.
        if !on { statusItem.menu = buildMenu() }
    }

    // MARK: - Recorder wiring

    private func setupRecorder() {
        rec.onFinal = { [weak self] text, mode in
            guard let self = self else { return }
            // A stale onFinal from a previous recording fires while a new one is active —
            // dispatch the text but don't touch overlay/trigMode.
            if self.rec.state == .idle || self.rec.state == .error {
                self.overlay.hide()
                self.setRecording(false)
                self.trigMode = .idle
            }
            self.dispatch(text: text, mode: mode)
        }
    }

    // MARK: - Trigger

    func triggerDictation(mode: DictMode) {
        switch trigMode {
        case .lock:
            // F10 in lock mode → stop and paste
            rec.stop()
            overlay.hide()
            setRecording(false)
            trigMode = .idle

        case .pushToTalk:
            // Second press while holding → upgrade to lock (no auto-stop on release)
            ptTimer?.invalidate(); ptTimer = nil
            trigMode = .lock

        case .idle:
            let now = Date().timeIntervalSinceReferenceDate
            let isDouble = (now - lastPressTime) < doubleTapWindow
            lastPressTime = now

            if isDouble {
                // Double-tap → lock mode; restart if first tap already stopped
                if rec.state == .idle || rec.state == .error { beginRecording(mode: mode) }
                trigMode = .lock
            } else {
                // Single press → push-to-talk (hold key, release stops)
                beginRecording(mode: mode)
                trigMode = .pushToTalk
                startPushToTalkPolling()
            }
        }
    }

    private func beginRecording(mode: DictMode) {
        rec.prevBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        rec.start(mode: mode)
        overlay.show(rec: rec)
        setRecording(true)
        Task { @MainActor in
            while self.rec.state == .starting { try? await Task.sleep(nanoseconds: 50_000_000) }
            if self.rec.state != .listening {
                self.ptTimer?.invalidate(); self.ptTimer = nil
                self.overlay.hide()
                self.setRecording(false)
                self.trigMode = .idle
            }
        }
    }

    private func startPushToTalkPolling() {
        let kc = CGKeyCode(HotkeyState.shared.insertKeycode)
        ptTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] t in
            guard let self = self, self.trigMode == .pushToTalk else { t.invalidate(); return }
            if !CGEventSource.keyState(.combinedSessionState, key: kc) {
                t.invalidate()
                self.ptTimer = nil
                self.trigMode = .idle
                self.rec.stop()
                self.overlay.hide()
                self.setRecording(false)
            }
        }
    }

    @objc func triggerInsert() { triggerDictation(mode: .insert) }
    @objc func triggerClaude() { triggerDictation(mode: .claude) }
    @objc func openSettings()  { settingsController.show() }
    @objc func quit()          { NSApp.terminate(nil) }

    // MARK: - Dispatch

    private func dispatch(text: String, mode: DictMode) {
        switch mode {
        case .insert:
            let pb = NSPasteboard.general
            // Save existing clipboard so we can restore it after paste.
            let savedClipboard = pb.string(forType: .string)
            pb.clearContents(); pb.setString(text, forType: .string)

            let ax = AXIsProcessTrusted()
            let bundle = rec.prevBundle
            let targetApp = bundle.isEmpty ? nil :
                NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            let pid = targetApp?.processIdentifier ?? -1
            NSLog("[dispatch] ax=%@ bundle=%@ pid=%d textLen=%d", "\(ax)", bundle, pid, text.count)

            guard ax else {
                let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(o)
                NSLog("[dispatch] AX not trusted — text in clipboard, prompted for AX")
                return
            }
            if pid > 0 {
                postCmdV(toPid: pid_t(pid))
                NSLog("[dispatch] postToPid %d done", pid)
            } else {
                postCmdV(toPid: nil)
                NSLog("[dispatch] fallback HID post done")
            }
            // Restore previous clipboard after paste has had time to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pb.clearContents()
                if let saved = savedClipboard { pb.setString(saved, forType: .string) }
            }

        case .claude:
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            if let url = URL(string: "claude://code/new?q=\(encoded)") { NSWorkspace.shared.open(url) }
        }
    }

    private func postCmdV(toPid: pid_t?) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let d = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let u = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else { return }
        d.flags = .maskCommand; u.flags = .maskCommand
        if let pid = toPid {
            d.postToPid(pid); u.postToPid(pid)
        } else {
            d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
        }
    }
}

// ─── Entry ─────────────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appController = AppController()
registerHotkeys()
app.run()
