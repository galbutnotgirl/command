// SettingsWindow.swift — the menu-bar window: Set Up (live permission checks +
// a step graphic), Shortcuts (central hotkey editor), Troubleshooting, About.
// Hosted via NSHostingController so the rest of the agent stays AppKit.

import Cocoa
import SwiftUI
import Combine
import AVFoundation

// Repo URL lives in Updater.swift (GITHUB_REPO_URL) as the single source of truth.

enum SettingsTab: Equatable {
    case setup, shortcuts, history
    case dictHistory, dictCorrections, dictVocabulary, dictSettings
    case about
}

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
        if ev.keyCode == 51 || ev.keyCode == 117 {                         // delete / fwd-delete = clear
            recordingAction = nil
            clearBinding(action)
            reregisterHotkeys()
            return true
        }
        let key = UInt32(ev.keyCode)
        guard KEYCODE_NAMES[key] != nil else { return true }                // ignore keys we can't name
        recordingAction = nil
        setBinding(action: action, keycode: key, mods: carbonMods(from: ev.modifierFlags))
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
        w.title = "ClaudeCommand"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        // Resize to fit each tab (up to the screen) whenever the tab changes.
        tabObserver = settingsModel.$tab
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.sizeWindow(for: t) }
    }

    // Size once on first show — large enough for all tabs without resizing on switch.
    // All tabs use ScrollView, so any overflow scrolls gracefully.
    private func sizeWindow(for tab: SettingsTab) {
        guard let w = window, !w.isVisible else { return }
        let cap = ((w.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 40
        let shortcutsH = 200 + CGFloat(max(1, settingsModel.bindings.count)) * 62
        let h = min(max(920, shortcutsH), cap)
        w.setContentSize(NSSize(width: 720, height: h))
        w.center()
    }

    func windowWillClose(_ notification: Notification) {
        if settingsModel.recordingAction != nil { settingsModel.cancelRecording() }
        // Defer: window is still isVisible=true during willClose; policy check needs it gone
        DispatchQueue.main.async { applyDockPolicy() }
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
            tabButton(.history, "Clipboard History", "clock.arrow.circlepath")

            Divider().padding(.vertical, 4)

            Text("DICTATION")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            tabButton(.dictHistory,     "History",     "clock")
            tabButton(.dictCorrections, "Corrections", "text.badge.checkmark")
            tabButton(.dictVocabulary,  "Vocabulary",  "character.book.closed")
            tabButton(.dictSettings,    "Settings",    "gear")

            Divider().padding(.vertical, 4)

            tabButton(.about, "About", "info.circle")
            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tabButton(_ t: SettingsTab, _ label: String, _ icon: String) -> some View {
        Button(action: {
            // Always cancel shortcut-recording before switching tabs.
            // Without this, the local key monitor keeps swallowing keystrokes
            // (including in text fields on the Corrections/Vocabulary tabs).
            if model.recordingAction != nil { model.cancelRecording() }
            model.tab = t
        }) {
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
        case .setup:           SetupView(model: model)
        case .shortcuts:       ShortcutsView(model: model)
        case .history:         HistoryView()
        case .dictHistory:     DictHistoryView()
        case .dictCorrections: DictCorrectionsView()
        case .dictVocabulary:  DictVocabularyView()
        case .dictSettings:    DictSettingsView()
        case .about:           AboutView(model: model)
        }
    }
}

// ---- Set Up -----------------------------------------------------------------
struct CheckAction { let label: String; let run: () -> Void }

struct SetupView: View {
    @ObservedObject var model: SettingsModel
    // Live-poll so a grant flipped in System Settings turns the row green here
    // without the user having to hit Re-check.
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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

                Text("Just enabled a grant but the row's still red? macOS only applies it when the agent relaunches — click Restart agent, then Re-check.")
                    .font(.caption).foregroundColor(.secondary)
                Text("Grants reset when the app is rebuilt (new binary = new identity to macOS). Re-enable ClaudeCommand in each pane after every build.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Button("Re-check") { model.refresh() }
                    Button("Restart agent") { restartApp() }
                    Spacer()
                }

                Divider()
                Text("Common issues").font(.headline)

                setupTipRow("Hotkeys need fn key",
                    "If F6–F8 don't fire, go to System Settings > Keyboard and enable \"Use F1, F2… as standard function keys\".")
                setupTipRow("Logs",
                    "~/.claude/logs/command-agent.err (agent) · ~/.claude/logs/clipwatch.err (clipboard daemon)")
            }
            .padding(24)
        }
        .onAppear { model.refresh() }
        .onReceive(refreshTimer) { _ in model.refresh() }
    }

    private func action(for title: String) -> CheckAction? {
        switch title {
        case "Accessibility":
            return CheckAction(label: "Open Settings") { openPrivacyPane("Privacy_Accessibility") }
        case "Screen Recording":
            return CheckAction(label: "Open Settings") { openPrivacyPane("Privacy_ScreenCapture") }
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
            Image(systemName: leadingIcon)
                .font(.system(size: 15))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: statusIcon).foregroundColor(statusColor)
            if check.state != .ok, let a = action { Button(a.label) { a.run() } }
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
    }
    // Per-item icon so each permission/component is recognizable at a glance.
    private var leadingIcon: String {
        let t = check.title.lowercased()
        if t.contains("accessibility")                       { return "accessibility" }
        if t.contains("screen")                              { return "camera.on.rectangle" }
        if t.contains("microphone") || t.contains("speech")  { return "mic.fill" }
        if t.contains("agent")                               { return "bolt.horizontal.circle" }
        if t.contains("hotkey")                              { return "keyboard" }
        if t.contains("right-click") || t.contains("quick")  { return "filemenu.and.cursorarrow" }
        if t.contains("clipboard")                           { return "doc.on.clipboard" }
        return "circle"
    }
    private var statusIcon: String {
        switch check.state { case .ok: return "checkmark.circle.fill"
                             case .missing: return "xmark.circle.fill"
                             case .unknown: return "questionmark.circle" }
    }
    private var statusColor: Color {
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
        Step(id: 2, icon: "switch.2",        title: "Flip it on",    sub: "Enable ClaudeCommand in the list"),
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
                Text("Click a key field and press a combo to set it. Press Delete to clear. Esc cancels. Changes apply instantly.")
                    .foregroundColor(.secondary)

                VStack(spacing: 0) {
                    ForEach(model.bindings) { b in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name)
                                Text(b.detail).font(.caption).foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            KeyBindingField(action: b.action, binding: b, model: model)
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            .padding(24)
        }
    }
}

struct KeyBindingField: View {
    let action: String
    let binding: HotkeyBinding
    @ObservedObject var model: SettingsModel

    private var isRecording: Bool { model.recordingAction == action }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(isRecording
                    ? Color.accentColor.opacity(0.12)
                    : Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: 1)
                )
            Text(isRecording ? "Press keys…" : (binding.keycode == 0 ? "—" : binding.human))
                .font(.system(.body, design: .rounded).bold())
                .foregroundColor(isRecording ? .accentColor : (binding.keycode == 0 ? .secondary : .primary))
                .lineLimit(1)
                .padding(.horizontal, 10)
        }
        .frame(width: 120, height: 30)
        .contentShape(Rectangle())
        .onTapGesture {
            if isRecording { model.cancelRecording() }
            else { model.startRecording(action) }
        }
        .help(isRecording ? "Press a key combo · Delete to clear · Esc to cancel" : "Click to set shortcut")
    }
}

private func setupTipRow(_ title: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.subheadline).bold()
        Text(body).font(.caption).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func actionExplainRow(_ name: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(name).font(.callout).bold()
        Text(detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
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

                Text("Red means a requirement isn't met yet — not a crash. Grant permissions in the Set Up tab first, then Re-scan here.")
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
                fix: "Open System Settings > Privacy & Security > Accessibility. Find ClaudeCommand and flip it ON. Then Re-scan.",
                action: { requestAccessibility(); openPrivacyPane("Privacy_Accessibility") },
                actionLabel: "Open Settings"
            ),
            DiagItem(
                title: "Screen Recording",
                ok: screenRecordingOK(),
                fix: "Open System Settings > Privacy & Security > Screen Recording. Toggle ClaudeCommand ON. Then Re-scan.",
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
                ok: loadBindings().contains { $0.keycode > 0 },
                fix: "No hotkeys bound. Open Shortcuts tab and assign at least one key.",
                action: nil,
                actionLabel: ""
            ),
            DiagItem(
                title: "Quick Actions installed",
                ok: fileExists(home("Library/Services/Claude - Add.workflow")),
                fix: "Right-click actions missing. Run ./install-quick-action.sh from the claude-command folder.",
                action: nil,
                actionLabel: ""
            ),
            DiagItem(
                title: "Clipboard daemon",
                ok: runShell("/usr/bin/pgrep", ["-f", "clipwatch.py"]).code == 0,
                fix: "Clipboard history daemon not running. Run ./install-agent.sh to reinstall.",
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
    @State private var enabled = UserDefaults.standard.bool(forKey: "cliphistoryEnabled")
    @State private var retentionText = String(readRetentionDays())
    @State private var pendingClear: ClearOption? = nil
    @State private var status = ""
    @State private var theme = pickerTheme()

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

                GroupBox {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Enable Clipboard History").font(.callout).bold()
                            Text("Captures every copy to a searchable picker. History stays on this Mac, readable only by you.")
                                .font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $enabled)
                            .labelsHidden()
                            .onChange(of: enabled) { _, v in
                                UserDefaults.standard.set(v, forKey: "cliphistoryEnabled")
                                if v { startClipwatch() } else { stopClipwatch() }
                            }
                    }
                    .padding(10)
                }

                if enabled {
                    GroupBox {
                        HStack(spacing: 10) {
                            Text("Keep history for")
                            Stepper(value: Binding(
                                get: { Int(retentionText) ?? readRetentionDays() },
                                set: { retentionText = String($0); commitRetention() }
                            ), in: 1...365) {
                                Text("\(retentionText) days").frame(minWidth: 70, alignment: .leading)
                            }
                            Spacer()
                        }
                        .padding(8)
                    }

                    GroupBox(label: Text("Appearance").bold()) {
                        HStack(spacing: 10) {
                            Text("Picker theme")
                            Spacer()
                            Picker("", selection: $theme) {
                                Text("Auto").tag(PickerTheme.auto)
                                Text("Light").tag(PickerTheme.light)
                                Text("Dark").tag(PickerTheme.dark)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                            .onChange(of: theme) { _, v in setPickerTheme(v) }
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
    @State private var showDock = showDockIcon()

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
                Text("ClaudeCommand").font(.title2).bold()
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
                Toggle("Show in Menu Bar", isOn: $showIcon)
                    .onChange(of: showIcon) { _, v in
                        UserDefaults.standard.set(!v, forKey: "hideMenuBarIcon")
                        if v { menuBar.showIcon() } else { menuBar.hideIcon() }
                    }
                Toggle("Show Dock icon", isOn: $showDock)
                    .onChange(of: showDock) { _, v in setShowDockIcon(v); applyDockPolicy() }

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

// ---- Dictation: History -------------------------------------------------------

struct DictHistoryView: View {
    @ObservedObject private var hist:  HistoryStore    = .shared
    @ObservedObject private var vocab: VocabularyStore = .shared

    private var suggestions: [(wrong: String, correct: String, count: Int)] {
        hist.suggestions(ignoring: Set(vocab.replacements.map { $0.wrong }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Dictation History").font(.title2).bold()

                if !suggestions.isEmpty {
                    GroupBox(label: Text("Suggested Corrections").font(.subheadline).bold()) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Patterns seen ≥2× where raw and processed transcripts differ.")
                                .font(.caption).foregroundColor(.secondary)
                            ForEach(suggestions.prefix(5), id: \.wrong) { s in
                                HStack {
                                    Text(s.wrong).foregroundColor(.secondary)
                                    Image(systemName: "arrow.right").font(.caption)
                                    Text(s.correct)
                                    Text("×\(s.count)").font(.caption2).foregroundColor(.secondary)
                                    Spacer()
                                    Button("Add to Corrections") {
                                        vocab.addReplacement(wrong: s.wrong, correct: s.correct)
                                    }.buttonStyle(.bordered).controlSize(.small)
                                }.font(.system(size: 13))
                                Divider()
                            }
                        }.padding(.vertical, 6)
                    }
                }

                GroupBox(label: HStack {
                    Text("All Entries (\(hist.records.count))").font(.subheadline).bold()
                    Spacer()
                    if !hist.records.isEmpty {
                        Button("Clear All") { hist.clearAll() }
                            .foregroundColor(.red).buttonStyle(.plain).font(.caption)
                    }
                }) {
                    VStack(alignment: .leading, spacing: 0) {
                        if hist.records.isEmpty {
                            Text("No dictations yet. Use the Dictate hotkey to record your first one.")
                                .font(.caption).foregroundColor(.secondary).padding(.vertical, 12)
                        } else {
                            ForEach(hist.records) { e in
                                HistoryEntryRow(entry: e)
                                Divider()
                            }
                        }
                    }.padding(.vertical, 4)
                }
            }.padding(24)
        }
    }
}

struct HistoryEntryRow: View {
    let entry: HistoryStore.Record
    @ObservedObject private var hist:  HistoryStore    = .shared
    @ObservedObject private var vocab: VocabularyStore = .shared
    @State private var showAddCorrection = false
    @State private var corrWrong  = ""
    @State private var corrCorrect = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.mode == "insert" ? "Insert" : "→ Claude")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15)).cornerRadius(4)
                Text(RelativeDateTimeFormatter().localizedString(for: entry.timestamp, relativeTo: Date()))
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.processed, forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.caption) }
                .buttonStyle(.plain).help("Copy")

                Button { showAddCorrection.toggle() } label: {
                    Image(systemName: "plus.bubble").font(.caption)
                }.buttonStyle(.plain).help("Add correction")

                Button { hist.remove(id: entry.id) } label: {
                    Image(systemName: "trash").font(.caption).foregroundColor(.red)
                }.buttonStyle(.plain).help("Delete")
            }
            Text(entry.processed).font(.system(size: 13)).lineLimit(3)
            if entry.processed != entry.raw {
                Text("Raw: \(entry.raw)").font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
            if showAddCorrection {
                HStack(spacing: 6) {
                    TextField("Misheard", text: $corrWrong)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    TextField("Correct", text: $corrCorrect)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                    Button("Add") {
                        vocab.addReplacement(wrong: corrWrong, correct: corrCorrect)
                        corrWrong = ""; corrCorrect = ""; showAddCorrection = false
                    }.disabled(corrWrong.isEmpty || corrCorrect.isEmpty)
                    Button("Cancel") { showAddCorrection = false; corrWrong = ""; corrCorrect = "" }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }.padding(.top, 4)
            }
        }.padding(.vertical, 6)
    }
}

// ---- Dictation: Corrections ---------------------------------------------------

struct DictCorrectionsView: View {
    @ObservedObject private var vocab: VocabularyStore = .shared
    @ObservedObject private var hist:  HistoryStore    = .shared
    @State private var newWrong   = ""
    @State private var newCorrect = ""

    private var suggestions: [(wrong: String, correct: String, count: Int)] {
        hist.suggestions(ignoring: Set(vocab.replacements.map { $0.wrong }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Word Corrections").font(.title2).bold()
                Text("Misheard → Correct. Applied before any other processing.")
                    .foregroundColor(.secondary)

                GroupBox(label: Text("Active Corrections").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 6) {
                        if vocab.replacements.isEmpty {
                            Text("No corrections yet.")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            ForEach(vocab.replacements) { r in
                                HStack {
                                    Text(r.wrong).foregroundColor(.secondary)
                                    Image(systemName: "arrow.right").font(.caption)
                                    Text(r.correct)
                                    Spacer()
                                    Button { vocab.removeReplacement(id: r.id) } label: {
                                        Image(systemName: "trash").foregroundColor(.red)
                                    }.buttonStyle(.plain)
                                }.font(.system(size: 13))
                                Divider()
                            }
                        }
                        HStack(spacing: 6) {
                            TextField("Misheard", text: $newWrong)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                            Image(systemName: "arrow.right").foregroundColor(.secondary)
                            TextField("Correct", text: $newCorrect)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                            Button("Add") {
                                vocab.addReplacement(wrong: newWrong, correct: newCorrect)
                                newWrong = ""; newCorrect = ""
                            }.disabled(newWrong.isEmpty || newCorrect.isEmpty)
                        }.padding(.top, 4)
                    }.padding(.vertical, 6)
                }

                if !suggestions.isEmpty {
                    GroupBox(label: Text("Suggestions from History").font(.subheadline).bold()) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Patterns seen ≥2× where raw and processed transcripts differ.")
                                .font(.caption).foregroundColor(.secondary)
                            ForEach(suggestions, id: \.wrong) { s in
                                HStack {
                                    Text(s.wrong).foregroundColor(.secondary)
                                    Image(systemName: "arrow.right").font(.caption)
                                    Text(s.correct)
                                    Text("×\(s.count)").font(.caption2).foregroundColor(.secondary)
                                    Spacer()
                                    Button("Add") {
                                        vocab.addReplacement(wrong: s.wrong, correct: s.correct)
                                    }.buttonStyle(.borderedProminent).controlSize(.small)
                                }.font(.system(size: 13))
                                Divider()
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }.padding(24)
        }
    }
}

// ---- Dictation: Vocabulary ----------------------------------------------------

struct DictVocabularyView: View {
    @ObservedObject private var vocab: VocabularyStore = .shared
    @State private var newVocab  = ""
    @State private var newFiller = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Vocabulary").font(.title2).bold()

                GroupBox(label: Text("Vocabulary Hints").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Proper nouns, product names — hints the model toward correct spelling.")
                            .font(.caption).foregroundColor(.secondary)
                        if vocab.vocab.isEmpty {
                            Text("No terms yet.").font(.caption).foregroundColor(.secondary)
                        } else {
                            ForEach(Array(vocab.vocab.enumerated()), id: \.offset) { i, term in
                                HStack {
                                    Text(term)
                                    Spacer()
                                    Button { vocab.removeVocab(at: IndexSet([i])) } label: {
                                        Image(systemName: "trash").foregroundColor(.red)
                                    }.buttonStyle(.plain)
                                }.font(.system(size: 13))
                                Divider()
                            }
                        }
                        HStack(spacing: 6) {
                            TextField("Term", text: $newVocab).textFieldStyle(.roundedBorder)
                            Button("Add") { vocab.addVocab(newVocab); newVocab = "" }
                                .disabled(newVocab.isEmpty)
                        }.padding(.top, 4)
                    }.padding(.vertical, 6)
                }

                GroupBox(label: Text("Filler Words").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Words stripped from transcripts when filler removal is on. Toggle per entry.")
                            .font(.caption).foregroundColor(.secondary)
                        ForEach(vocab.fillers) { f in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { f.enabled },
                                    set: { _ in vocab.toggleFiller(id: f.id) }
                                )).labelsHidden().toggleStyle(.checkbox)
                                Text(f.phrase).foregroundColor(f.enabled ? .primary : .secondary)
                                if f.customPattern != nil {
                                    Text("regex").font(.caption2)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.2)).cornerRadius(3)
                                }
                                Spacer()
                                Button { vocab.removeFiller(id: f.id) } label: {
                                    Image(systemName: "trash").foregroundColor(.red)
                                }.buttonStyle(.plain)
                            }.font(.system(size: 13))
                            Divider()
                        }
                        HStack(spacing: 6) {
                            TextField("Phrase", text: $newFiller).textFieldStyle(.roundedBorder)
                            Button("Add") { vocab.addFiller(phrase: newFiller); newFiller = "" }
                                .disabled(newFiller.isEmpty)
                        }.padding(.top, 4)
                    }.padding(.vertical, 6)
                }
            }.padding(24)
        }
    }
}

// ---- Dictation: Settings ------------------------------------------------------

struct DictSettingsView: View {
    @ObservedObject private var rec:  Recorder           = recorder
    @ObservedObject private var proc: ProcessingSettings = .shared
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Dictation Settings").font(.title2).bold()
                Text("On-device transcription via Parakeet TDT — no cloud, no streaming, runs on Apple Neural Engine.")
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                GroupBox(label: Text("Model").font(.subheadline).bold()) {
                    HStack(spacing: 12) {
                        modelStatusIcon
                        modelStatusText
                        Spacer()
                        modelActionButton
                    }.padding(.vertical, 8)
                }

                GroupBox(label: Text("Microphone").font(.subheadline).bold()) {
                    HStack(spacing: 10) {
                        Image(systemName: micGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(micGranted ? .green : .red).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Microphone access")
                            Text("Required for dictation.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if !micGranted {
                            Button("Enable") {
                                AVCaptureDevice.requestAccess(for: .audio) { _ in
                                    DispatchQueue.main.async {
                                        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                                    }
                                }
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }.padding(.vertical, 6)
                }

                GroupBox(label: Text("Processing").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Filler removal (um, uh, you know…)", isOn: $proc.fillerRemoval)
                        Toggle("Smart formatting (punctuation commands, backtrack, lists)", isOn: $proc.smartFormatting)
                        Toggle("AI cleanup — Apple Intelligence, on-device (macOS 26+)", isOn: $proc.aiCleanup)
                        Text("Punctuation: \"period\", \"comma\", \"new paragraph\".\nBacktrack: \"scratch that\", \"no wait\", \"i mean\" removes the preceding phrase.")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 6)
                }
            }.padding(24)
        }
        .onAppear {
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    @ViewBuilder private var modelStatusIcon: some View {
        switch rec.modelStatus {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.title2)
        case .notDownloaded:
            Image(systemName: "arrow.down.circle").foregroundColor(.secondary).font(.title2)
        case .downloading:
            ProgressView().scaleEffect(0.8)
        case .error:
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red).font(.title2)
        }
    }

    @ViewBuilder private var modelStatusText: some View {
        switch rec.modelStatus {
        case .ready:
            VStack(alignment: .leading, spacing: 2) {
                Text("Parakeet TDT ready").bold()
                Text("On-device, ~650 MB").font(.caption).foregroundColor(.secondary)
            }
        case .notDownloaded:
            VStack(alignment: .leading, spacing: 2) {
                Text("Model not downloaded")
                Text("~650 MB, one-time, local only").font(.caption).foregroundColor(.secondary)
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading… \(Int(p * 100))%")
                ProgressView(value: p).frame(width: 200)
            }
        case .error(let msg):
            VStack(alignment: .leading, spacing: 2) {
                Text("Error").bold().foregroundColor(.red)
                Text(msg).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var modelActionButton: some View {
        switch rec.modelStatus {
        case .notDownloaded, .error:
            Button("Download") { Task { await recorder.downloadModels() } }
                .buttonStyle(.borderedProminent)
        case .ready:
            Button("Remove") { recorder.removeModels() }
                .buttonStyle(.bordered).foregroundColor(.red)
        default:
            EmptyView()
        }
    }
}
