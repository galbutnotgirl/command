// SettingsWindow.swift — the menu-bar window: Set Up (live permission checks +
// a step graphic), Shortcuts (central hotkey editor), Troubleshooting, About.
// Hosted via NSHostingController so the rest of the agent stays AppKit.

import Cocoa
import SwiftUI
import Combine

// Repo URL lives in Updater.swift (GITHUB_REPO_URL) as the single source of truth.

enum SettingsTab: Equatable { case setup, shortcuts, history, dictation, troubleshooting, about }

// Single shared model (the local key monitor in main.swift also talks to it
// while recording a rebind).
let settingsModel = SettingsModel()
let settingsWindow = SettingsWindowController()

// ---- model ------------------------------------------------------------------
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .setup
    @Published var perms: [StatusCheck] = []
    @Published var comps: [StatusCheck] = []
    @Published var bindings: [HotkeyBinding] = []
    @Published var recordingAction: String? = nil

    func refresh() {
        perms = permissionChecks()
        comps = componentChecks()
        bindings = loadBindings()
    }

    func setBinding(action: String, keycode: UInt32, mods: UInt32) {
        if let i = bindings.firstIndex(where: { $0.action == action }) {
            bindings[i].keycode = keycode; bindings[i].mods = mods
        }
        saveBindings(bindings); refresh()
    }
    func setEnabled(action: String, enabled: Bool) {
        if let i = bindings.firstIndex(where: { $0.action == action }) {
            bindings[i].enabled = enabled
        }
        saveBindings(bindings); refresh()
    }
    func clearBinding(_ action: String) {
        if let i = bindings.firstIndex(where: { $0.action == action }) {
            bindings[i].keycode = 0; bindings[i].mods = 0
        }
        saveBindings(bindings); refresh()
    }

    // Begin capturing the next combo for `action`. Hotkeys are paused so the
    // combo being pressed doesn't also fire whatever it's currently bound to.
    func startRecording(_ action: String) {
        recordingAction = action
        unregisterAllHotkeys()
    }
    func cancelRecording() {
        recordingAction = nil
        reregisterHotkeys()
    }

    // Called from the global key monitor. Returns true if it consumed the event.
    func handleRecording(_ ev: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }
        if ev.keyCode == 53 { cancelRecording(); return true }              // esc cancels
        let key = UInt32(ev.keyCode)
        guard KEYCODE_NAMES[key] != nil else { return true }                // ignore keys we can't name
        recordingAction = nil
        setBinding(action: action, keycode: key, mods: carbonMods(from: ev.modifierFlags))  // saves + re-registers
        return true
    }
}

// ---- window controller ------------------------------------------------------
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var tabObserver: AnyCancellable?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(tab: SettingsTab) {
        settingsModel.tab = tab
        settingsModel.refresh()
        if window == nil { build() }
        NSApp.setActivationPolicy(.regular)            // so the window can take focus
        NSApp.activate(ignoringOtherApps: true)
        sizeWindow(for: tab)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let host = NSHostingController(rootView: SettingsRootView(model: settingsModel))
        let w = NSWindow(contentViewController: host)
        w.title = "Claude Command"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        // Resize to fit each tab (up to the screen) whenever the tab changes.
        tabObserver = settingsModel.$tab
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.sizeWindow(for: t) }
    }

    // Grow the window to fit the tab's content, capped to the visible screen — so a
    // big display shows everything without inner scrolling; a small one scrolls.
    private func sizeWindow(for tab: SettingsTab) {
        guard let w = window else { return }
        let ideal: CGFloat
        switch tab {
        case .setup:           ideal = 840
        case .shortcuts:       ideal = 150 + CGFloat(max(1, settingsModel.bindings.count)) * 62
        case .history:         ideal = 560
        case .dictation:       ideal = 680
        case .troubleshooting: ideal = 600
        case .about:           ideal = 620
        }
        let cap = ((w.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 40
        let wasVisible = w.isVisible
        w.setContentSize(NSSize(width: 720, height: max(540, min(ideal, cap))))
        if !wasVisible { w.center() }
    }

    func windowWillClose(_ notification: Notification) {
        if settingsModel.recordingAction != nil { settingsModel.cancelRecording() }
        applyDockPolicy()                              // menu-bar-only again unless "Show in Dock" is on
    }
}

// ---- root view --------------------------------------------------------------
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 196)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            tabButton(.setup, "Set Up", "checklist")
            tabButton(.shortcuts, "Shortcuts", "keyboard")
            tabButton(.history, "History", "clock.arrow.circlepath")
            tabButton(.dictation, "Dictation", "mic")
            tabButton(.troubleshooting, "Troubleshooting", "wrench.and.screwdriver")
            tabButton(.about, "About", "info.circle")
            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tabButton(_ t: SettingsTab, _ label: String, _ icon: String) -> some View {
        Button(action: { model.tab = t }) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18)
                Text(label); Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(model.tab == t ? Color.accentColor.opacity(0.18) : Color.clear)
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .setup:            SetupView(model: model)
        case .shortcuts:        ShortcutsView(model: model)
        case .history:          HistoryView()
        case .dictation:        DictationView()
        case .troubleshooting:  TroubleshootingView()
        case .about:            AboutView(model: model)
        }
    }
}

// ---- Set Up -----------------------------------------------------------------
struct CheckAction { let label: String; let run: () -> Void }

struct SetupView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Set Up").font(.title2).bold()
                Text("Two quick grants and you're done. Click a row's button, flip the switch in System Settings, then Re-check.")
                    .foregroundColor(.secondary)

                StepDiagram()

                GroupBox(label: Text("Permissions").bold()) {
                    VStack(spacing: 0) {
                        ForEach(model.perms, id: \.title) { c in
                            CheckRow(check: c, action: action(for: c.title)); Divider()
                        }
                    }.padding(.vertical, 2)
                }

                GroupBox(label: Text("Components").bold()) {
                    VStack(spacing: 0) {
                        ForEach(model.comps, id: \.title) { c in
                            CheckRow(check: c, action: nil); Divider()
                        }
                    }.padding(.vertical, 2)
                }

                Text("Automation: the first time you Go from a browser, macOS asks once to allow reading the tab URL — approve it.")
                    .font(.caption).foregroundColor(.secondary)

                Text("Just enabled a grant but the row's still red? macOS only applies it when the agent relaunches — click Restart agent, then Re-check.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Button("Re-check") { model.refresh() }
                    Button("Restart agent") { exit(0) }   // KeepAlive relaunches us with the new grants live
                    Spacer()
                }
            }
            .padding(24)
        }
    }

    private func action(for title: String) -> CheckAction? {
        switch title {
        case "Accessibility":
            return CheckAction(label: "Open Settings") { requestAccessibility(); openPrivacyPane("Privacy_Accessibility") }
        case "Screen Recording":
            return CheckAction(label: "Open Settings") { requestScreenRecording(); openPrivacyPane("Privacy_ScreenCapture") }
        default:
            return nil
        }
    }
}

struct CheckRow: View {
    let check: StatusCheck
    let action: CheckAction?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if check.state != .ok, let a = action { Button(a.label) { a.run() } }
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
    }
    private var icon: String {
        switch check.state { case .ok: return "checkmark.circle.fill"
                             case .missing: return "xmark.circle.fill"
                             case .unknown: return "questionmark.circle" }
    }
    private var color: Color {
        switch check.state { case .ok: return .green; case .missing: return .red; case .unknown: return .secondary }
    }
}

struct Step: Identifiable {
    let id: Int
    let icon: String
    let title: String
    let sub: String
}

struct StepDiagram: View {
    private let steps: [Step] = [
        Step(id: 1, icon: "magnifyingglass", title: "Open the pane", sub: "Privacy & Security in System Settings"),
        Step(id: 2, icon: "switch.2",        title: "Flip it on",    sub: "Enable CommandAgent in the list"),
        Step(id: 3, icon: "checkmark.seal",  title: "Re-check here", sub: "Rows turn green when granted"),
    ]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(steps) { s in
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 46, height: 46)
                        Image(systemName: s.icon).font(.system(size: 18)).foregroundColor(.accentColor)
                    }
                    Text("Step \(s.id)").font(.caption2).foregroundColor(.secondary)
                    Text(s.title).font(.callout).bold().multilineTextAlignment(.center)
                    Text(s.sub).font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(10)
            }
        }
    }
}

// ---- Shortcuts --------------------------------------------------------------
struct ShortcutsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Shortcuts").font(.title2).bold()
                Text("Global hotkeys — they work from any app. Click Set, then press the key combo (e.g. ⌘F8). Esc cancels; Clear removes a binding. Changes apply instantly.")
                    .foregroundColor(.secondary)

                VStack(spacing: 0) {
                    ForEach(model.bindings) { b in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name)
                                Text(b.detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Group {
                                if model.recordingAction == b.action {
                                    Text("Press keys…").foregroundColor(.accentColor)
                                } else {
                                    Text(b.human).font(.system(.body, design: .rounded)).bold()
                                }
                            }.frame(width: 110, alignment: .trailing)
                            Button(model.recordingAction == b.action ? "…" : "Set") {
                                if model.recordingAction == b.action { model.cancelRecording() }
                                else { model.startRecording(b.action) }
                            }.frame(width: 46)
                            Button("Clear") { model.clearBinding(b.action) }.disabled(b.keycode == 0)
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
            .padding(24)
        }
    }
}

// ---- Dictation --------------------------------------------------------------

func readDictationSilenceTimeout() -> Double {
    if let v = readCommandConfig()["dictationSilenceTimeout"] as? Double, v >= 0.5 { return v }
    return 1.5
}

func writeDictationSilenceTimeout(_ seconds: Double) {
    var cfg = readCommandConfig()
    cfg["dictationSilenceTimeout"] = seconds
    if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: COMMAND_CONFIG))
    }
}

func whisperPostProcessEnabled() -> Bool {
    readCommandConfig()["whisperPostProcess"] as? Bool ?? false
}

func setWhisperPostProcess(_ on: Bool) {
    var cfg = readCommandConfig(); cfg["whisperPostProcess"] = on
    if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: COMMAND_CONFIG))
    }
}

let DICTATION_VOCAB_PATH = home(".claude/state/dictation-vocab.json")

func readDictationVocab() -> String {
    guard let data = FileManager.default.contents(atPath: DICTATION_VOCAB_PATH),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return "" }
    return arr.joined(separator: "\n")
}

func writeDictationVocab(_ text: String) {
    let terms = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    if let data = try? JSONSerialization.data(withJSONObject: terms, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: DICTATION_VOCAB_PATH))
    }
}

struct DictationView: View {
    @State private var silenceTimeout   = readDictationSilenceTimeout()
    @State private var vocabText        = readDictationVocab()
    @State private var vocabDirty       = false
    @State private var micGranted       = micPermissionGranted()
    @State private var speechGranted    = speechPermissionGranted()
    @State private var whisperEnabled   = whisperPostProcessEnabled()
    @State private var whisperFound     = whisperAvailable()
    @State private var installingWhisper = false
    @State private var whisperInstallMsg = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Dictation").font(.title2).bold()

                // Permissions
                GroupBox(label: Text("Permissions").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: micGranted ? "checkmark.circle.fill" : "questionmark.circle")
                                .foregroundColor(micGranted ? .green : .secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Microphone")
                                Text("Required for live transcription.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if !micGranted {
                                Button("Enable") {
                                    requestMicAndSpeech()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        micGranted    = micPermissionGranted()
                                        speechGranted = speechPermissionGranted()
                                    }
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        HStack(spacing: 10) {
                            Image(systemName: speechGranted ? "checkmark.circle.fill" : "questionmark.circle")
                                .foregroundColor(speechGranted ? .green : .secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speech Recognition")
                                Text("Required for on-device transcription.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2)
                }

                // Silence timeout
                GroupBox(label: Text("Silence Timeout").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        Slider(value: $silenceTimeout, in: 1.0...3.0, step: 0.1) {
                            Text("Silence timeout")
                        } minimumValueLabel: {
                            Text("1s").font(.caption).foregroundColor(.secondary)
                        } maximumValueLabel: {
                            Text("3s").font(.caption).foregroundColor(.secondary)
                        }
                        .onChange(of: silenceTimeout) { _, v in writeDictationSilenceTimeout(v) }

                        Text("Auto-stops after \(String(format: "%.1f", silenceTimeout))s of silence.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2)
                }

                // Whisper post-processing
                GroupBox(label: Text("Whisper Post-Processing").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Refine with whisper-cli (better accuracy)", isOn: $whisperEnabled)
                            .onChange(of: whisperEnabled) { _, v in setWhisperPostProcess(v) }

                        if whisperFound {
                            Text("whisper-cli found ✓")
                                .font(.caption).foregroundColor(.green)
                        } else if installingWhisper {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.6)
                                Text("Installing whisper-cli…").font(.caption).foregroundColor(.secondary)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Text("whisper-cli not found").font(.caption).foregroundColor(.secondary)
                                Button("Install") { installWhisper() }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        if !whisperInstallMsg.isEmpty {
                            Text(whisperInstallMsg).font(.caption2).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("When enabled, SFSpeechRecognizer shows text live while whisper refines the final result for proper nouns and acronyms.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2)
                }

                // Vocabulary
                GroupBox(label: Text("Custom Vocabulary").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One term per line. Helps the recognizer handle proper nouns, product names, and jargon.")
                            .font(.caption).foregroundColor(.secondary)

                        TextEditor(text: $vocabText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                            .border(Color.gray.opacity(0.3), width: 1)
                            .onChange(of: vocabText) { _, _ in vocabDirty = true }

                        Button("Save") {
                            writeDictationVocab(vocabText)
                            vocabDirty = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!vocabDirty)

                        Text("Your own terms, stored locally at ~/.claude/state/dictation-vocab.json.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2)
                }
            }
            .padding(24)
        }
        .onAppear {
            micGranted     = micPermissionGranted()
            speechGranted  = speechPermissionGranted()
            whisperEnabled = whisperPostProcessEnabled()
            whisperFound   = whisperAvailable()
        }
    }

    // Install whisper-cli via Homebrew (provides better dictation accuracy).
    private func installWhisper() {
        installingWhisper = true; whisperInstallMsg = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { fileExists($0) }
            guard let brew else {
                DispatchQueue.main.async {
                    installingWhisper = false
                    whisperInstallMsg = "Homebrew not found — install it from brew.sh, then try again."
                }
                return
            }
            let r = runShell(brew, ["install", "whisper-cpp"])
            DispatchQueue.main.async {
                installingWhisper = false
                whisperFound = whisperAvailable()
                whisperInstallMsg = whisperFound
                    ? "whisper-cli installed ✓"
                    : "Install failed (exit \(r.code)). In Terminal: brew install whisper-cpp"
            }
        }
    }
}

// ---- Troubleshooting --------------------------------------------------------

struct DiagItem {
    let title: String
    let ok: Bool
    let fix: String          // shown when not ok
    let action: (() -> Void)?  // optional button
    let actionLabel: String
}

struct TroubleshootingView: View {
    @State private var items: [DiagItem] = []
    @State private var fnKeysOn: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Troubleshooting").font(.title2).bold()
                    Spacer()
                    Button("Re-scan") { reload() }
                }

                Text("Live scan of everything Claude Command needs. Red rows have a fix — follow the step, then Re-scan.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { i in
                        diagRow(items[i])
                        if i < items.count - 1 { Divider() }
                    }
                }
                .background(Color.gray.opacity(0.05))
                .cornerRadius(10)

                // Static tips for things we can't probe automatically
                Divider()
                Text("Other common issues").font(.headline)

                tipRow("Hotkeys need fn key",
                       "If F6–F8 don't fire, go to System Settings > Keyboard and enable \"Use F1, F2… as standard function keys\".")
                tipRow("Browser URL not captured",
                       "First Go from each browser (Chrome, Safari, Arc…) prompts for Automation — approve it once per browser.")
                tipRow("Logs",
                       "~/Library/Logs/claude-command.log (worker) · ~/.claude/logs/command-agent.err (agent) · ~/.claude/logs/clipwatch.err (daemon)")
            }
            .padding(24)
        }
        .onAppear { reload() }
    }

    private func reload() {
        items = [
            DiagItem(
                title: "Accessibility",
                ok: axTrusted(),
                fix: "Open System Settings > Privacy & Security > Accessibility. Find CommandAgent and flip it ON. Then Re-scan.",
                action: { requestAccessibility(); openPrivacyPane("Privacy_Accessibility") },
                actionLabel: "Open Settings"
            ),
            DiagItem(
                title: "Screen Recording",
                ok: screenRecordingOK(),
                fix: "Open System Settings > Privacy & Security > Screen Recording. Toggle CommandAgent ON. Then Re-scan.",
                action: { openPrivacyPane("Privacy_ScreenCapture") },
                actionLabel: "Open Settings"
            ),
            DiagItem(
                title: "Agent running",
                ok: fileExists(home(".claude/state/command-agent.sock")),
                fix: "Agent socket missing. Run ./install-agent.sh from the claude-command folder to reinstall the LaunchAgent.",
                action: nil,
                actionLabel: ""
            ),
            DiagItem(
                title: "Hotkeys configured",
                ok: fileExists(home(".claude/state/command-hotkeys.json")),
                fix: "Hotkey config missing. Run ./set-hotkeys.sh from the claude-command folder.",
                action: nil,
                actionLabel: ""
            ),
            DiagItem(
                title: "Quick Actions installed",
                ok: fileExists(home("Library/Services/Claude - Go.workflow")),
                fix: "Right-click actions missing. Run ./install-quick-action.sh from the claude-command folder.",
                action: nil,
                actionLabel: ""
            ),
            DiagItem(
                title: "Clipboard daemon",
                ok: serviceLoaded(CLIPWATCH_LABEL),
                fix: "Clipboard history daemon not running. Run ./install-agent.sh — it installs clipwatch alongside the main agent.",
                action: nil,
                actionLabel: ""
            ),
        ]
    }

    @ViewBuilder
    private func diagRow(_ item: DiagItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(item.ok ? .green : .red)
                    .frame(width: 20)
                Text(item.title).font(.headline)
                Spacer()
                if !item.ok, let action = item.action {
                    Button(item.actionLabel) { action() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if !item.ok {
                Text(item.fix)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func tipRow(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline).bold()
            Text(body).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// ---- History ----------------------------------------------------------------
struct ClearOption: Identifiable {
    let id = UUID()
    let label: String   // shown in the confirm dialog
    let seconds: Int    // <= 0 means "everything"
}

struct HistoryView: View {
    @State private var retentionText = String(readRetentionDays())
    @State private var pendingClear: ClearOption? = nil
    @State private var status = ""

    private let clears: [ClearOption] = [
        ClearOption(label: "Last 15 minutes", seconds: 15 * 60),
        ClearOption(label: "Last hour",       seconds: 60 * 60),
        ClearOption(label: "Last 24 hours",   seconds: 24 * 60 * 60),
        ClearOption(label: "Everything",      seconds: 0),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Clipboard History").font(.title2).bold()
                Text("Every copy is saved to a searchable picker (default hotkey F6). History stays on this Mac, readable only by you, and is pruned automatically.")
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    HStack(spacing: 10) {
                        Text("Keep history for")
                        TextField("", text: $retentionText)
                            .frame(width: 54)
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitRetention() }
                        Text("days")
                        Spacer()
                        Button("Apply") { commitRetention() }.controlSize(.small)
                    }
                    .padding(8)
                }

                GroupBox(label: Text("Clear history").bold()) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Wipe recent clips — handy right after copying a password or token.")
                            .font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            ForEach(clears) { opt in
                                Button(role: opt.seconds == 0 ? .destructive : nil) {
                                    pendingClear = opt
                                } label: {
                                    Text(opt.label).frame(maxWidth: .infinity)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                }

                if !status.isEmpty {
                    Text(status).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(24)
        }
        .alert("Clear \(pendingClear?.label.lowercased() ?? "")?",
               isPresented: Binding(get: { pendingClear != nil },
                                    set: { if !$0 { pendingClear = nil } }),
               presenting: pendingClear) { opt in
            Button("Clear", role: .destructive) {
                let n = clearClipHistory(withinSeconds: opt.seconds)
                status = n == 0 ? "Nothing to clear." : "Cleared \(n) clip\(n == 1 ? "" : "s")."
            }
            Button("Cancel", role: .cancel) { }
        } message: { opt in
            Text(opt.seconds == 0
                 ? "Removes every saved clip. This can't be undone."
                 : "Removes clips copied in the \(opt.label.lowercased()). This can't be undone.")
        }
    }

    private func commitRetention() {
        let parsed = Int(retentionText.filter(\.isNumber)) ?? readRetentionDays()
        let n = max(1, min(365, parsed))
        writeRetentionDays(n)
        retentionText = String(n)
        status = "History kept for \(n) day\(n == 1 ? "" : "s")."
    }
}

// ---- channel picker (segmented; Prod greyed until a stable release exists) --
struct ChannelPicker: View {
    @Binding var channel: UpdateChannel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(UpdateChannel.allCases.enumerated()), id: \.element) { idx, c in
                let disabled = (c == .prod && !PROD_AVAILABLE)
                let selected = channel == c
                Button {
                    channel = c
                    setUpdateChannel(c)
                } label: {
                    Text(c.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .frame(width: 62)
                        .padding(.vertical, 4)
                        .background(selected ? Color.accentColor : Color.clear)
                        .foregroundColor(disabled ? Color.secondary.opacity(0.45)
                                                  : (selected ? .white : .primary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                if idx < UpdateChannel.allCases.count - 1 {
                    Divider().frame(height: 16)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
    }
}

// ---- About ------------------------------------------------------------------
struct AboutView: View {
    @ObservedObject var model: SettingsModel
    @State private var launchAtLogin = launchAtLoginEnabled()
    @State private var showIcon = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")

    @State private var updateStatus = ""
    @State private var checking = false
    @State private var installing = false
    @State private var available: UpdateInfo? = nil
    @State private var channel = currentChannel()

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private var channelHint: String {
        switch channel {
        case .alpha: return "Alpha — earliest builds, least tested."
        case .beta:  return "Beta — pre-release builds for testing."
        case .prod:  return "Stable releases only."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Claude Command").font(.title2).bold()
                Text("Select text or an image in any Mac app → hotkey or right-click → it lands in the Claude Code desktop app, with source context attached. Plus a clipboard-history picker and screenshot→Claude.")
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                // Version + updates
                HStack(spacing: 10) {
                    Text("Version \(version)").font(.caption).foregroundColor(.secondary)
                    Button(checking ? "Checking…" : "Check for Updates") { runCheck() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(checking || installing)
                }

                // Update channel
                HStack(spacing: 10) {
                    Text("Channel").font(.caption).foregroundColor(.secondary)
                    ChannelPicker(channel: $channel)
                        .disabled(checking || installing)
                    Spacer()
                }
                Text(channelHint).font(.caption2).foregroundColor(.secondary)

                if let info = available {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").foregroundColor(.accentColor)
                        Text("v\(info.latestVersion) available")
                            .font(.caption).bold()
                        Button(installing ? "Installing…" : "Update Now") { runInstall(info) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(installing)
                    }
                }
                if !updateStatus.isEmpty {
                    Text(updateStatus).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in setLaunchAtLogin(v) }
                Toggle("Show menu-bar icon", isOn: $showIcon)
                    .onChange(of: showIcon) { _, v in
                        UserDefaults.standard.set(!v, forKey: "hideMenuBarIcon")
                        if v { menuBar.showIcon() } else { menuBar.hideIcon() }
                    }

                Divider()

                Button {
                    if let u = URL(string: GITHUB_REPO_URL) { NSWorkspace.shared.open(u) }
                } label: {
                    Label("View on GitHub", systemImage: "link")
                }
                Text(GITHUB_REPO_URL).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            }
            .padding(24)
        }
    }

    private func runCheck() {
        checking = true; updateStatus = ""; available = nil
        Updater.shared.check { result in
            checking = false
            switch result {
            case .upToDate(let cur):  updateStatus = "You're on the latest version (v\(cur))."
            case .available(let info): available = info; updateStatus = info.notes.isEmpty ? "" : info.notes
            case .failed(let msg):    updateStatus = msg
            }
        }
    }

    private func runInstall(_ info: UpdateInfo) {
        installing = true
        Updater.shared.install(info,
            status: { updateStatus = $0 },
            done: { ok, msg in
                installing = false
                updateStatus = msg
            })
    }
}
