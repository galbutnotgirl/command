// DictationOverlay.swift — recording session controller.

import Cocoa

// MARK: - Overlay controller

@MainActor
final class DictationOverlay: NSObject {
    static let shared = DictationOverlay()

    private(set) var isVisible: Bool = false  // true = recording in progress
    var prevBundle: String = ""
    private var levelTask: Task<Void, Never>?

    private override init() {
        super.init()
        wireRecorder()
    }

    // MARK: - Public API

    func show(mode: DictMode) {
        prevBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        isVisible = true
        menuBar.setRecording(true)
        recorder.start(mode: mode)
        startLevelUpdates()
    }

    func hide() {
        levelTask?.cancel(); levelTask = nil
        menuBar.setRecording(false)
        isVisible = false
        resetDictTrigMode()
    }

    func stopRecording() {
        hide()
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
                let processed = await TranscriptProcessor.process(
                    rawText,
                    vocab: .shared,
                    settings: .shared,
                    log: { DebugLog.shared.append($0) }
                )
                HistoryStore.shared.add(raw: rawText, processed: processed, mode: mode)
                self.playStopSound()
                self.hide()
                self.dispatch(text: processed, mode: mode)
            }
        }
    }

    private func playStopSound() {
        playUISound(settingsModel.stopSound)
    }

    // MARK: - Dispatch final text

    private func dispatch(text: String, mode: DictMode) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        stampDictationSource(cc: pb.changeCount)   // after the write — exact cc, no race

        switch mode {
        case .insert:
            if !prevBundle.isEmpty { activate(prevBundle); usleep(200_000) }
            postKey(kV, cmd: true)

        case .claude:
            activate(CLAUDE_BUNDLE)
            usleep(300_000)
            postKey(kV, cmd: true)

        case .customAction(let id):
            dispatchCustomAction(id: id, text: text)
        }
    }

    // Voice-kind Custom Action: feed the transcript in as this action's
    // captured content instead of pasting it — background handoff, or the
    // same paste-into-Claude path a text/screenshot custom action uses.
    private func dispatchCustomAction(id: String, text: String) {
        guard let ca = loadCustomActions().first(where: { $0.id == id }), ca.enabled else {
            notify("Dictation failed", "That custom action no longer exists.")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if ca.isHandoff {
            DispatchQueue.global().async { runCustomHandoff(ca, capturedText: text) }
        } else {
            DispatchQueue.global().async {
                runWorker("custom", source: front, captured: text,
                          customPrompt: ca.prompt, customSubmit: ca.isAutoSubmit,
                          customSession: ca.sessionMode, customIncludeSource: ca.includeSource)
            }
        }
    }

    // Tags this write "com.claudecommand.dictation" — NOT in clipwatch's BLOCK_BUNDLES,
    // so it's recorded (unlike the internal-only "com.claudecommand" sentinel) and
    // shows up under the picker's "Dictated" filter. The exact changeCount (not just a
    // timestamp) is what lets clipwatch match this deterministically to its own write.
    private func stampDictationSource(cc: Int) {
        let entry: [String: Any] = ["bundle": "com.claudecommand.dictation",
                                     "ts": Date().timeIntervalSince1970, "cc": cc]
        if let d = try? JSONSerialization.data(withJSONObject: entry) {
            try? d.write(to: URL(fileURLWithPath: COPY_SOURCE_PATH))
        }
    }
}
