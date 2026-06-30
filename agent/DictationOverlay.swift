// DictationOverlay.swift — invisible recording session controller.
// No UI panel; menu bar icon changes during capture (see MenuBar.setRecording/updateAudioLevel).

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
        recorder.onPartial = { _ in }   // no UI to update

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
                self.hide()         // idempotent; also covers 10-min timeout path
                self.dispatch(text: processed, mode: mode)
            }
        }
    }

    private func playStopSound() {
        if let s = NSSound(named: NSSound.Name("Pop")) { s.volume = 0.3; s.play() }
    }

    // MARK: - Dispatch final text

    private func dispatch(text: String, mode: DictMode) {
        switch mode {
        case .insert:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if !prevBundle.isEmpty { activate(prevBundle); usleep(200_000) }
            postKey(kV, cmd: true)

        case .claude:
            // Paste into the existing open Claude window (same as the "add" action),
            // not a new prompt. Activate Claude, then ⌘V.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            activate(CLAUDE_BUNDLE)
            usleep(300_000)
            postKey(kV, cmd: true)
        }
    }

}
