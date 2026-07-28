// DictationOverlay.swift — recording session controller.

import Cocoa

// MARK: - Overlay controller

@MainActor
final class DictationOverlay: NSObject {
    static let shared = DictationOverlay()

    private(set) var isVisible: Bool = false  // true = recording in progress
    var prevBundle: String = ""
    private var levelTask: Task<Void, Never>?
    private var isFinishing: Bool = false

    private override init() {
        super.init()
        wireRecorder()
    }

    // MARK: - Public API

    func show(mode: DictMode) {
        prevBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        isVisible = true
        isFinishing = false
        menuBar.setRecording(true)
        recorder.start(mode: mode)
        if case .error = recorder.state {
            hide()
            return
        }
        playUISound(settingsModel.startSound, role: .start)
        startLevelUpdates()
    }

    func hide() {
        levelTask?.cancel(); levelTask = nil
        menuBar.setRecording(false)
        isVisible = false
        isFinishing = false
        resetDictTrigMode()
    }

    func stopRecording() {
        guard isVisible, !isFinishing else { return }
        isFinishing = true
        resetDictTrigMode()
        playStopSound()
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

    // MARK: - Recorder wiring

    private func wireRecorder() {
        recorder.onPartial = { _ in }

        recorder.onFinal = { [weak self] rawText, mode in
            guard let self = self else { return }
            Task { @MainActor in
                appendLog("[dictation] final received mode=\(String(describing: mode)) rawChars=\(rawText.count)")
                let processed = await TranscriptProcessor.process(
                    rawText,
                    vocab: .shared,
                    settings: .shared,
                    log: { DebugLog.shared.append($0) }
                )
                appendLog("[dictation] processing complete rawChars=\(rawText.count) processedChars=\(processed.count)")
                HistoryStore.shared.add(raw: rawText, processed: processed, mode: mode)
                self.hide()
                self.dispatch(text: processed, mode: mode)
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
