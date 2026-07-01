import Cocoa
import SwiftUI

// MARK: - View model

private final class OverlayModel: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = true
    @Published var errorText: String? = nil
}

// MARK: - SwiftUI pill view

private struct PillView: View {
    @ObservedObject var model: OverlayModel

    private var displayText: String {
        if let err = model.errorText { return err }
        if model.transcript.isEmpty { return "Listening…" }
        // Tail-truncate to last 60 chars so the pill doesn't overflow.
        let t = model.transcript
        if t.count > 60 { return "…" + t.suffix(60) }
        return t
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isRecording ? Color.red : Color(white: 0.55))
                .frame(width: 10, height: 10)
                .opacity(model.isRecording ? 1.0 : 0.6)
                .animation(
                    model.isRecording
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default,
                    value: model.isRecording
                )

            Text(displayText)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(nil, value: displayText)

            Text("F9 stop · esc cancel")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 0)
        .frame(width: 480, height: 56)
    }
}

// MARK: - NSPanel subclass (must be key to receive esc)

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay controller

final class DictationOverlay: NSObject {
    static let shared = DictationOverlay()

    private var panel: DictationPanel?
    private var model = OverlayModel()
    private var keyMonitor: Any?
    private var errorHideTimer: Timer?
    private(set) var isVisible: Bool = false
    private var currentMode: DictationMode = .insert
    private var prevBundle: String = ""

    private override init() { super.init() }

    // MARK: - Public API

    func show(mode: DictationMode) {
        prevBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        currentMode = mode

        model.transcript = ""
        model.isRecording = true
        model.errorText = nil

        if panel == nil { buildPanel() }
        positionPanel()
        panel?.orderFront(nil)
        isVisible = true

        let _gu = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        if let s = NSSound(contentsOf: _gu, byReference: true) { s.volume = 0.35; s.play() }

        installKeyMonitor()
        wireEngine()
        SpeechEngine.shared.start(mode: mode)
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        isVisible = false
    }

    func cancel() {
        SpeechEngine.shared.cancel()
        hide()
    }

    // MARK: - Build once

    private func buildPanel() {
        let p = DictationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 56),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.isMovableByWindowBackground = true

        // Visual effect container — HUD pill
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 480, height: 56))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 28
        fx.layer?.masksToBounds = true

        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = fx.bounds
        host.autoresizingMask = [.width, .height]
        fx.addSubview(host)

        p.contentView = fx
        panel = p
    }

    private func positionPanel() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let sw = screen.frame.width
        let ox = screen.frame.minX + (sw - 480) / 2
        let oy = screen.frame.maxY - 40 - 56
        p.setFrameOrigin(NSPoint(x: ox, y: oy))
    }

    // MARK: - SpeechEngine wiring

    private func wireEngine() {
        let engine = SpeechEngine.shared

        engine.onPartialResult = { [weak self] text in
            self?.model.transcript = text
        }

        engine.onFinalResult = { [weak self] text, mode in
            guard let self = self else { return }
            let audioURL = SpeechEngine.shared.lastAudioFile
            SpeechEngine.shared.lastAudioFile = nil
            if whisperPostProcessEnabled() {
                self.dispatchWithWhisper(rawText: text, audioURL: audioURL, mode: mode)
            } else {
                self.hide()
                self.dispatch(text: text, mode: mode)
            }
        }

        engine.onError = { [weak self] message in
            guard let self = self else { return }
            NSSound.beep()
            self.model.isRecording = false
            self.model.errorText = message
            self.errorHideTimer?.invalidate()
            self.errorHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.hide()
            }
        }
    }

    // MARK: - Whisper post-processing

    private func dispatchWithWhisper(rawText: String, audioURL: URL?, mode: DictationMode) {
        guard let audio = audioURL, whisperAvailable() else {
            dispatch(text: rawText, mode: mode)
            return
        }
        model.transcript = "Refining…"
        model.isRecording = false
        panel?.orderFront(nil); isVisible = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let refined = runWhisper(audioURL: audio)
            DispatchQueue.main.async {
                self?.hide()
                self?.dispatch(text: refined ?? rawText, mode: mode)
                try? FileManager.default.removeItem(at: audio)
            }
        }
    }

    // MARK: - Dispatch final text

    private func dispatch(text: String, mode: DictationMode) {
        let _pu = URL(fileURLWithPath: "/System/Library/Sounds/Pop.aiff")
        if let s = NSSound(contentsOf: _pu, byReference: true) { s.volume = 0.3; s.play() }
        switch mode {
        case .insert:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            // Restore the source app first, then paste into it.
            if !prevBundle.isEmpty {
                activate(prevBundle)
                usleep(200_000)
            }
            postKey(kV, cmd: true)

        case .addToClaudeChat:
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            if let url = URL(string: "claude://code/new?q=\(encoded)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Esc key monitor

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Global monitor — needed because panel is .nonactivatingPanel and never becomes key window
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { DispatchQueue.main.async { self?.cancel() } }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}
