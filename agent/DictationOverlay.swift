// DictationOverlay.swift — recording session controller.

import Cocoa
import ClaudeCommandCore

@MainActor
private final class DictationCaptureWarningPanel {
    static let shared = DictationCaptureWarningPanel()

    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var dismissTask: Task<Void, Never>?

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.cornerCurve = .continuous
        panel.contentView = background

        let icon = NSImageView(image: NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone warning") ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 46, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 16, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(icon)
        background.addSubview(titleLabel)
        background.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 30),
            icon.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -30),
            titleLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 40),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -30),
        ])
    }

    func show(title: String, detail: String, autoDismissAfter: TimeInterval? = nil) {
        dismissTask?.cancel()
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        guard let delay = autoDismissAfter else { return }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel.orderOut(nil)
    }
}

// MARK: - Overlay controller

@MainActor
final class DictationOverlay: NSObject {
    static let shared = DictationOverlay()

    private(set) var isVisible: Bool = false  // true = recording in progress
    var prevBundle: String = ""
    private var levelTask: Task<Void, Never>?
    private var captureWatchdogTask: Task<Void, Never>?
    private var captureWarningVisible = false
    private var isFinishing: Bool = false
    private let watchdogPolicy = DEFAULT_DICTATION_CAPTURE_WATCHDOG_POLICY
    private(set) var captureWatchdogWarningCount = 0
    private(set) var captureWatchdogRecoveryCount = 0

    private override init() {
        super.init()
        wireRecorder()
    }

    // MARK: - Public API

    @discardableResult
    func show(mode: DictMode) -> Bool {
        prevBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let attemptedPhase = recorder.state
        guard recorder.start(mode: mode) else {
            appendLog("[dictation] overlay start rejected mode=\(mode) phase=\(recorder.state.rawValue)")
            if attemptedPhase == .loading {
                showUnavailable(
                    title: "Dictation is loading",
                    detail: "Command is preparing on-device transcription. Release your shortcut and try again in a moment."
                )
            } else {
                showUnavailable(
                    title: "Dictation didn't start",
                    detail: "Release your shortcut and try again. Command reset any stale recording state."
                )
            }
            return false
        }
        isVisible = true
        isFinishing = false
        menuBar.setRecording(true)
        if mode != .diagnostic {
            playUISound(settingsModel.startSound, role: .start)
        }
        startLevelUpdates()
        startCaptureWatchdog()
        return true
    }

    func hide() {
        levelTask?.cancel(); levelTask = nil
        captureWatchdogTask?.cancel(); captureWatchdogTask = nil
        captureWarningVisible = false
        DictationCaptureWarningPanel.shared.hide()
        menuBar.setRecording(false)
        isVisible = false
        isFinishing = false
        resetDictTrigMode()
    }

    func stopRecording() {
        guard isVisible, !isFinishing else { return }
        isFinishing = true
        resetDictTrigMode()
        if recorder.currentMode != .diagnostic {
            playStopSound()
        }
        recorder.stop()
    }

    // MARK: - Live audio level → menu bar icon

    private func startLevelUpdates() {
        levelTask?.cancel()
        levelTask = Task { @MainActor [weak self] in
            while let s = self, s.isVisible, !Task.isCancelled {
                menuBar.updateAudioLevel(recorder.audioLevel)
                try? await Task.sleep(nanoseconds: 66_000_000)   // ~15 fps
            }
        }
    }

    private func startCaptureWatchdog() {
        captureWatchdogTask?.cancel()
        captureWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var watchdog = DictationCaptureWatchdog(policy: watchdogPolicy)
            while self.isVisible, !Task.isCancelled {
                let buffers = recorder.capturedBufferCount
                switch watchdog.observe(
                    nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    phase: recorder.state,
                    capturedBufferCount: buffers
                ) {
                case .none:
                    break
                case .warn:
                    self.captureWatchdogWarningCount += 1
                    self.captureWarningVisible = true
                    appendLog("[dictation] capture warning phase=\(recorder.state.rawValue) buffers=\(buffers) startup=\(recorder.captureStartupBegan)")
                    if recorder.currentMode != .diagnostic {
                        let detail = buffers == 0
                            ? "Stop speaking. Command has not received audio yet and is trying to recover."
                            : "Stop speaking. Command stopped receiving audio and is trying to recover."
                        DictationCaptureWarningPanel.shared.show(
                            title: "Microphone isn't recording",
                            detail: detail
                        )
                    }
                case .recovered:
                    self.captureWarningVisible = false
                    DictationCaptureWarningPanel.shared.hide()
                    appendLog("[dictation] capture recovered after warning buffers=\(buffers)")
                case .resetCapture:
                    self.captureWatchdogRecoveryCount += 1
                    appendLog("[dictation] capture watchdog recovering phase=\(recorder.state.rawValue) buffers=\(buffers) startup=\(recorder.captureStartupBegan) finishing=\(self.isFinishing)")
                    let diagnostic = recorder.currentMode == .diagnostic
                    recorder.cancel()
                    self.hide()
                    if !diagnostic {
                        DictationCaptureWarningPanel.shared.show(
                            title: "Dictation stopped",
                            detail: "Audio capture stalled. Release your shortcut and try again; Command reset the microphone.",
                            autoDismissAfter: 8
                        )
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func showUnavailable(title: String, detail: String) {
        DictationCaptureWarningPanel.shared.show(title: title, detail: detail, autoDismissAfter: 6)
    }

    // MARK: - Recorder wiring

    private func wireRecorder() {
        recorder.onPartial = { _ in }

        recorder.onFinal = { [weak self] rawText, mode in
            guard let self = self else { return }
            Task { @MainActor in
                appendLog("[dictation] final received mode=\(String(describing: mode)) rawChars=\(rawText.count)")
                if mode == .diagnostic {
                    appendLog("[dictation-probe] diagnostic final suppressed chars=\(rawText.count)")
                    self.hide()
                    return
                }
                let result = await runDictationDeliveryPipeline(
                    rawText: rawText,
                    process: { text in
                        await TranscriptProcessor.process(
                            text,
                            vocab: .shared,
                            settings: .shared,
                            log: { DebugLog.shared.append($0) }
                        )
                    },
                    deliver: { raw, processed in
                        HistoryStore.shared.add(raw: raw, processed: processed, mode: mode)
                        self.hide()
                        self.dispatch(text: processed, mode: mode)
                    }
                )
                appendLog("[dictation] delivery status=\(result.status.rawValue) rawChars=\(result.rawText.count) processedChars=\(result.processedText.count)")
                if !result.delivered {
                    self.hide()
                    appendLog("[dictation] processed transcript suppressed before history and dispatch")
                }
            }
        }

        recorder.onFinishedWithoutText = { [weak self] mode in
            Task { @MainActor in
                appendLog("[dictation] finished without dispatchable text mode=\(String(describing: mode))")
                self?.hide()
            }
        }

        recorder.onFailure = { [weak self] message, mode in
            Task { @MainActor in
                appendLog("[dictation] failed mode=\(String(describing: mode)) error=\(message)")
                self?.hide()
                if mode == .diagnostic {
                    appendLog("[dictation-probe] diagnostic failure warning suppressed")
                    return
                }
                DictationCaptureWarningPanel.shared.show(
                    title: "Dictation failed",
                    detail: "No audio is being captured. Command reset dictation; release your shortcut and try again.",
                    autoDismissAfter: 8
                )
            }
        }
    }

    private func playStopSound() {
        playUISound(settingsModel.stopSound, role: .stop)
    }

    // MARK: - Dispatch final text

    private func dispatch(text: String, mode: DictMode) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let clipboardWritten = pb.setString(text, forType: .string)
        appendLog("[dictation] dispatch mode=\(String(describing: mode)) chars=\(text.count) previousBundle=\(prevBundle.isEmpty ? "(empty)" : prevBundle) clipboard=\(clipboardWritten)")
        guard clipboardWritten else {
            notify("Dictation failed", "Command could not place transcript on clipboard.")
            return
        }
        stampDictationSource(cc: pb.changeCount)   // after the write — exact cc, no race

        switch mode {
        case .diagnostic:
            appendLog("[dictation-probe] diagnostic dispatch suppressed chars=\(text.count)")

        case .insert:
            guard !prevBundle.isEmpty else {
                appendLog("[dictation] insert failed: previous app bundle missing")
                notify("Dictation copied", "Transcript is on clipboard, but Command could not identify where to paste it.")
                return
            }
            activate(prevBundle)
            waitForActive(prevBundle)
            let pasted = postKey(kV, cmd: true, to: prevBundle)
            appendLog("[dictation] insert target=\(prevBundle) active=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == prevBundle) pastePosted=\(pasted)")
            if !pasted {
                notify("Dictation copied", "Transcript is on clipboard, but Command could not paste into previous app.")
            }

        case .claude, .claude2:
            let front = prevBundle
            let provider = mode == .claude2 ? dictationAssistant2Provider() : dictationAssistantProvider()
            DispatchQueue.global().async {
                runWorker("custom", source: front, captured: text, customPrompt: "{selection}",
                          customSession: "add", customIncludeSource: false,
                          provider: provider)
            }

        case .customAction(let actionID, let triggerID):
            dispatchCustomAction(actionID: actionID, triggerID: triggerID, text: text)
        }
    }

    // Voice-kind Custom Action trigger: feed the transcript in as this
    // action's captured content instead of pasting it — background handoff,
    // or the same paste-into-Claude path a text/screenshot trigger uses.
    private func dispatchCustomAction(actionID: String, triggerID: String, text: String) {
        guard let ca = loadCustomActions().first(where: { $0.id == actionID }), ca.enabled,
              let trig = ca.triggers.first(where: { $0.id == triggerID }) else {
            notify("Dictation failed", "That custom action no longer exists.")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let delivery = ca.effectiveDelivery(for: trig)
        if delivery == .background {
            DispatchQueue.global().async { runCustomHandoff(ca, trigger: trig, capturedText: text) }
        } else {
            let dest = ca.effectiveDestination(for: trig).envValue
            let provider = ca.effectiveProvider(for: trig, default: selectedProvider())
            DispatchQueue.global().async {
                runWorker("custom", source: front, captured: text,
                          customPrompt: ca.prompt, customSubmit: ca.autoSubmit(for: trig),
                          customSession: delivery.sessionMode, customIncludeSource: ca.shouldIncludeSource(for: trig),
                          destination: dest, provider: provider)
            }
        }
    }

    // Tags this write "com.claudecommand.dictation" for Clipboard History attribution,
    // so it's recorded (unlike the internal-only "com.claudecommand" sentinel) and
    // shows up under the picker's "Dictated" filter. The exact changeCount (not just a
    // timestamp) is what lets the watcher match this deterministically to its own write.
    private func stampDictationSource(cc: Int) {
        let entry: [String: Any] = ["bundle": "com.claudecommand.dictation",
                                     "ts": Date().timeIntervalSince1970, "cc": cc]
        if let d = try? JSONSerialization.data(withJSONObject: entry) {
            try? d.write(to: URL(fileURLWithPath: COPY_SOURCE_PATH))
        }
    }
}
