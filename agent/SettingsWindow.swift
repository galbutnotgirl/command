// SettingsWindow.swift — the menu-bar window: Set Up (live permission checks +
// a step graphic), Shortcuts (central hotkey editor), Troubleshooting, About.
// Hosted via NSHostingController so the rest of the agent stays AppKit.

import Cocoa
import SwiftUI
import Combine
import AVFoundation

// Repo URL lives in Updater.swift (GITHUB_REPO_URL) as the single source of truth.

enum SettingsTab: Equatable {
    case setup, shortcuts, history, templates
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
    @Published var customActions: [CustomAction] = []
    @Published var recordingAction: String? = nil
    @Published var bindingConflict: String? = nil
    @Published var claudeDestination: String = UserDefaults.standard.string(forKey: "claudeDestination") ?? "code"
    @Published var soundsEnabled: Bool = (UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool) ?? true
    @Published var soundVolume: Double = (UserDefaults.standard.object(forKey: "soundVolume") as? Double) ?? 0.35
    @Published var startSound: String = UserDefaults.standard.string(forKey: "startSound") ?? "Tink"
    @Published var stopSound: String = UserDefaults.standard.string(forKey: "stopSound") ?? "Tink"

    func refresh() {
        perms = permissionChecks()
        comps = componentChecks()
        bindings = loadBindings()
        customActions = loadCustomActions()
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
        let isCustom = customActions.contains { $0.id == action }
        if ev.keyCode == 51 || ev.keyCode == 117 {                         // delete / fwd-delete = clear
            recordingAction = nil
            if isCustom { clearCustomBinding(id: action) } else { clearBinding(action) }
            reregisterHotkeys()
            return true
        }
        let key = UInt32(ev.keyCode)
        guard KEYCODE_NAMES[key] != nil else { return true }                // ignore keys we can't name
        let carbonM = carbonMods(from: ev.modifierFlags)
        recordingAction = nil
        if isCustom {
            setCustomBinding(id: action, keycode: key, mods: carbonM)
            checkConflict(forAction: action, keycode: key, mods: carbonM)
        } else {
            setBinding(action: action, keycode: key, mods: carbonM)
            checkConflict(forAction: action, keycode: key, mods: carbonM)
        }
        reregisterHotkeys()
        return true
    }

    // ---- custom action CRUD ----
    func addCustomAction(_ ca: CustomAction) {
        customActions.append(ca)
        saveCustomActions(customActions)
    }
    func deleteCustomAction(id: String) {
        customActions.removeAll { $0.id == id }
        saveCustomActions(customActions)
    }
    func updateCustomAction(_ ca: CustomAction) {
        if let i = customActions.firstIndex(where: { $0.id == ca.id }) { customActions[i] = ca }
        saveCustomActions(customActions)
    }
    func setCustomBinding(id: String, keycode: UInt32, mods: UInt32) {
        if let i = customActions.firstIndex(where: { $0.id == id }) {
            customActions[i].keycode = keycode; customActions[i].mods = mods
        }
        saveCustomActions(customActions)
    }
    func clearCustomBinding(id: String) { setCustomBinding(id: id, keycode: 0, mods: 0) }

    // Check whether keycode+mods collides with any other binding (different action/id).
    // Sets bindingConflict to a human-readable message, or nil if clear.
    func checkConflict(forAction action: String, keycode: UInt32, mods: UInt32) {
        guard keycode != 0 else { bindingConflict = nil; return }
        if let other = bindings.first(where: { $0.keycode == keycode && $0.mods == mods && $0.action != action }) {
            bindingConflict = "Conflicts with \"\(other.action)\" shortcut"
            return
        }
        if let other = customActions.first(where: { $0.keycode == keycode && $0.mods == mods && $0.id != action }) {
            bindingConflict = "Conflicts with custom action \"\(other.name)\""
            return
        }
        bindingConflict = nil
    }
}

// Global helper — respects soundsEnabled + soundVolume from settingsModel.
func playUISound(_ name: String) {
    guard settingsModel.soundsEnabled else { return }
    let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
    if let s = NSSound(contentsOf: url, byReference: true) {
        s.volume = Float(settingsModel.soundVolume)
        s.play()
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
            tabButton(.templates, "Templates", "doc.text.below.ecg")
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
        case .templates:       TemplatesView()
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
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Set Up").font(.title2).bold()

                // Permissions — numbered steps
                VStack(alignment: .leading, spacing: 6) {
                    Text("Permissions").font(.headline)
                    Text("Grant these before using ClaudeCommand.")
                        .font(.caption).foregroundColor(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(model.perms.enumerated()), id: \.offset) { i, check in
                        PermStep(number: i + 1, check: check, action: permAction(for: check.title))
                        if i < model.perms.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.15), lineWidth: 1))

                Divider()

                // Component status — compact
                Text("Status").font(.headline)

                VStack(spacing: 0) {
                    ForEach(Array(model.comps.enumerated()), id: \.offset) { i, check in
                        CompRow(check: check, action: compAction(for: check.title, model: model))
                        if i < model.comps.count - 1 { Divider().padding(.leading, 28) }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.15), lineWidth: 1))

                HStack(spacing: 10) {
                    Button("Re-check") { model.refresh() }
                    Button("Restart agent") { restartApp() }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    Text("Grant still red after enabling? Restart agent — macOS applies grants on relaunch.")
                        .font(.caption).foregroundColor(.secondary)
                    Text("After a rebuild, re-grant permissions — new binary = new identity to macOS.")
                        .font(.caption).foregroundColor(.secondary)
                    Text("F5–F8 don't fire? System Settings → Keyboard → enable \"Use F1, F2… as standard function keys\".")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(24)
        }
        .onAppear { model.refresh() }
        .onReceive(refreshTimer) { _ in model.refresh() }
    }

    private func permAction(for title: String) -> CheckAction? {
        switch title {
        case "Accessibility":
            return CheckAction(label: "Enable") {
                requestAccessibility()
                openPrivacyPane("Privacy_Accessibility")
            }
        case "Screen Recording":
            return CheckAction(label: "Enable") {
                requestScreenRecording()
                openPrivacyPane("Privacy_ScreenCapture")
            }
        case let t where t.hasPrefix("Microphone"):
            return CheckAction(label: "Enable") {
                if micPermissionDenied() { openPrivacyPane("Privacy_Microphone") }
                else { requestMic() }
            }
        default:
            return nil
        }
    }

    private func compAction(for title: String, model: SettingsModel) -> CheckAction? {
        switch title {
        case "Clipboard daemon":
            let enabled = UserDefaults.standard.bool(forKey: "cliphistoryEnabled")
            return CheckAction(label: enabled ? "Restart" : "Enable") {
                if !enabled { UserDefaults.standard.set(true, forKey: "cliphistoryEnabled") }
                stopClipwatch(); startClipwatch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.refresh() }
            }
        case "Hotkeys configured":
            return CheckAction(label: "Shortcuts →") { model.tab = .shortcuts }
        case "Right-click actions":
            return CheckAction(label: "Instructions") {
                if let url = URL(string: "https://github.com/galbutnotgirl/claude-command#install") {
                    NSWorkspace.shared.open(url)
                }
            }
        default:
            return nil
        }
    }
}

// Permission step — numbered, instructional, action button when not granted
struct PermStep: View {
    let number: Int
    let check: StatusCheck
    let action: CheckAction?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(check.state == .ok ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
                    .frame(width: 28, height: 28)
                if check.state == .ok {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                } else {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(check.title).font(.callout).fontWeight(.medium)
                    Spacer()
                    if check.state == .ok {
                        Text("Granted").font(.caption).foregroundColor(.green)
                    } else if let a = action {
                        Button(a.label) { a.run() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Text(check.detail)
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if check.state == .ok && isRestartSensitive {
                    Text("Revocation only applies after agent restart.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if check.state == .missing, let hint = instructionHint {
                    Text(hint)
                        .font(.caption).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
    }

    private var isRestartSensitive: Bool {
        let t = check.title.lowercased()
        return t.contains("accessibility") || t.contains("screen")
    }

    private var instructionHint: String? {
        let t = check.title.lowercased()
        if t.contains("accessibility") {
            return "→ System Settings → Privacy & Security → Accessibility → enable ClaudeCommand"
        }
        if t.contains("screen") {
            return "→ System Settings → Privacy & Security → Screen Recording → enable ClaudeCommand"
        }
        return nil
    }
}

// Compact status row for components
struct CompRow: View {
    let check: StatusCheck
    let action: CheckAction?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 13))
                .foregroundColor(statusColor)
                .frame(width: 20)
            Text(check.title).font(.callout)
            Spacer()
            if check.state != .ok, let a = action {
                Button(a.label) { a.run() }
                    .buttonStyle(.bordered).controlSize(.small)
            } else if check.state == .ok {
                Text("OK").font(.caption).foregroundColor(.secondary)
            } else {
                Text("—").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
    }

    private var statusIcon: String {
        switch check.state {
        case .ok: return "checkmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    private var statusColor: Color {
        switch check.state { case .ok: return .green; case .missing: return .red; case .unknown: return .secondary }
    }
}

// ---- Shortcuts --------------------------------------------------------------
struct ShortcutsView: View {
    @ObservedObject var model: SettingsModel
    @State private var showingAddCustom = false

    private var destBinding: Binding<String> {
        Binding(
            get: { model.claudeDestination },
            set: { model.claudeDestination = $0; UserDefaults.standard.set($0, forKey: "claudeDestination") }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Shortcuts").font(.title2).bold()
                    Spacer()
                    Button("Export…") { exportSettings() }
                    Button("Import…") { importSettings(model: model) }
                }
                Text("Click a key field and press a combo to set it. Press Delete to clear. Esc cancels. Changes apply instantly.")
                    .foregroundColor(.secondary)

                // Destination — where every hotkey and custom action opens Claude.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude destination").font(.headline)
                    Text("All three open the Claude desktop app — Chat, Cowork, and Code are just different modes inside it.")
                        .font(.caption).foregroundColor(.secondary)
                    Picker("", selection: destBinding) {
                        Text("Chat").tag("chat")
                        Text("Cowork").tag("cowork")
                        Text("Code").tag("code")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
                .padding(.bottom, 8)

                if let conflict = model.bindingConflict {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(conflict).font(.callout).foregroundColor(.orange)
                        Spacer()
                        Button("Dismiss") { model.bindingConflict = nil }.buttonStyle(.plain)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

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

                // ---- Custom Actions ----
                HStack {
                    Text("Custom Actions").font(.headline)
                    Spacer()
                    Button(action: { showingAddCustom = true }) {
                        Label("Add", systemImage: "plus.circle")
                    }
                }
                .padding(.top, 8)

                Text("Prompt templates that wrap selected text or a screenshot. Use {selection} to place selected text inline — otherwise it's appended below the prompt. Source app + research hint go before all of it, unless \"Include source app\" is off.")
                    .font(.caption).foregroundColor(.secondary)

                if model.customActions.isEmpty {
                    Text("No custom actions yet — click Add to create one.")
                        .font(.caption).foregroundColor(.secondary).padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.customActions) { ca in
                            CustomActionRow(ca: ca, model: model)
                            Divider()
                        }
                    }
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingAddCustom) {
            CustomActionSheet(isPresented: $showingAddCustom, model: model)
        }
    }
}

struct CustomActionRow: View {
    let ca: CustomAction
    @ObservedObject var model: SettingsModel
    @State private var showingEdit = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ca.isShot ? "camera.viewfinder" : "text.cursor")
                .foregroundColor(.accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ca.name).font(.callout)
                    Text(ca.sessionMode == "add" ? "add" : "new")
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                    if !ca.includeSource {
                        Text("no src").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                    }
                }
                let preview = String(ca.prompt.prefix(70))
                Text(preview + (ca.prompt.count > 70 ? "…" : ""))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            CustomKeyBindingField(ca: ca, model: model)
            Button(action: { showingEdit = true }) {
                Image(systemName: "pencil").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            Button(action: { model.deleteCustomAction(id: ca.id) }) {
                Image(systemName: "trash").foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showingEdit) {
            CustomActionSheet(isPresented: $showingEdit, model: model, editing: ca)
        }
    }
}

struct CustomKeyBindingField: View {
    let ca: CustomAction
    @ObservedObject var model: SettingsModel
    private var isRecording: Bool { model.recordingAction == ca.id }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: 1))
            Text(isRecording ? "Press keys…" : (ca.keycode == 0 ? "—" : ca.human))
                .font(.system(.body, design: .rounded).bold())
                .foregroundColor(isRecording ? .accentColor : (ca.keycode == 0 ? .secondary : .primary))
                .lineLimit(1).padding(.horizontal, 10)
        }
        .frame(width: 120, height: 30)
        .contentShape(Rectangle())
        .onTapGesture {
            if isRecording { model.cancelRecording() } else { model.startRecording(ca.id) }
        }
        .help(isRecording ? "Press a key combo · Delete to clear · Esc to cancel" : "Click to set shortcut")
    }
}

struct CustomActionSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var model: SettingsModel
    var editing: CustomAction? = nil

    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var isShot: Bool = false
    @State private var isAutoSubmit: Bool = false
    @State private var sessionMode: String = "new"
    @State private var includeSource: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "New Custom Action" : "Edit Custom Action").font(.headline)

            TextField("Name (e.g. Summarize)", text: $name)
                .textFieldStyle(.roundedBorder)

            Toggle("Screenshot mode", isOn: $isShot)
                .help("Takes a screenshot and attaches it to the prompt")

            Picker("Session", selection: $sessionMode) {
                Text("New session").tag("new")
                Text("Add to existing chat").tag("add")
            }
            .pickerStyle(.segmented)
            .help("New session opens a fresh Claude Code window. Add pastes into the currently open chat.")

            Toggle("Include source app", isOn: $includeSource)
                .help("Prepend \"from: AppName — URL\" (plus an app-specific research hint, e.g. \"use the Slack MCP…\") before the prompt")

            Toggle("Auto-submit", isOn: $isAutoSubmit)
                .help("Press Return automatically after pasting the prompt into Claude")

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt template").font(.caption).bold()
                Text(isShot
                     ? "Sent to Claude with the screenshot attached, source context first (if enabled above)."
                     : "Final message Claude sees, top to bottom: 1) source context + research hint (if enabled above) 2) this template, with {selection} replaced by the selected text 3) if you didn't use {selection}, the selected text is appended after, on its own line.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(editing == nil ? "Add" : "Save") {
                    let trimName = name.trimmingCharacters(in: .whitespaces)
                    guard !trimName.isEmpty else { return }
                    if let existing = editing {
                        var updated = existing
                        updated.name = trimName; updated.prompt = prompt
                        updated.isShot = isShot; updated.isAutoSubmit = isAutoSubmit
                        updated.sessionMode = sessionMode; updated.includeSource = includeSource
                        model.updateCustomAction(updated)
                    } else {
                        var ca = CustomAction.makeNew(name: trimName, prompt: prompt, isShot: isShot)
                        ca.isAutoSubmit = isAutoSubmit
                        ca.sessionMode = sessionMode; ca.includeSource = includeSource
                        model.addCustomAction(ca)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            if let e = editing {
                name = e.name; prompt = e.prompt
                isShot = e.isShot; isAutoSubmit = e.isAutoSubmit
                sessionMode = e.sessionMode; includeSource = e.includeSource
            }
        }
    }
}

// ---- Templates: pre/post wrapping for go/comment/add + auto-context rules ---

struct TemplatesView: View {
    @StateObject private var model = TemplatesModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Templates").font(.title2).bold()
                Text("Text auto-inserted around the selection for Go / New / Add, plus the per-app context hints Go uses to research before acting. Defaults are shown below — edit anything, or Reset to go back.")
                    .foregroundColor(.secondary)

                ForEach(model.templates) { t in
                    CommandTemplateBox(template: t, model: model)
                }

                Divider().padding(.vertical, 4)

                HStack {
                    Text("Auto-Context Rules").font(.headline)
                    Spacer()
                    Button("Reset All to Default") { model.resetRulesToDefault() }
                        .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                    Button(action: { model.addRule() }) {
                        Label("Add", systemImage: "plus.circle")
                    }
                }
                Text("When \"Go\" fires, the matching rule below is woven into its research instruction — e.g. \"this is from Slack, use the Slack MCP.\" Matched by app bundle ID, app name, or URL host (supports leading \"*.\" glob). Use {url} in the text to insert the source URL.")
                    .font(.caption).foregroundColor(.secondary)

                VStack(spacing: 0) {
                    ForEach(model.rules) { rule in
                        EnrichRuleRow(rule: rule, model: model)
                        Divider()
                    }
                }
            }
            .padding(24)
        }
    }
}

struct CommandTemplateBox: View {
    let template: CommandTemplate
    @ObservedObject var model: TemplatesModel
    @State private var pre: String = ""
    @State private var post: String = ""

    var body: some View {
        GroupBox(label: HStack {
            Text(actionName(template.action)).bold()
            Text(actionDetail(template.action)).font(.caption).foregroundColor(.secondary)
            Spacer()
            Button("Reset") {
                model.resetTemplate(action: template.action)
                pre = model.templates.first { $0.action == template.action }?.pre ?? ""
                post = model.templates.first { $0.action == template.action }?.post ?? ""
            }
            .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Before selection").font(.caption).foregroundColor(.secondary)
                    TextField("(nothing)", text: $pre)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: pre) { _, v in model.setTemplate(action: template.action, pre: v) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.action == "go" ? "After selection — {research} inserts the auto-context line" : "After selection")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $post)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 50)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                        .onChange(of: post) { _, v in model.setTemplate(action: template.action, post: v) }
                }
            }
            .padding(.vertical, 6)
        }
        .onAppear { pre = template.pre; post = template.post }
    }
}

struct EnrichRuleRow: View {
    let rule: EnrichRule
    @ObservedObject var model: TemplatesModel
    @State private var pattern: String = ""
    @State private var text: String = ""
    @State private var match: EnrichMatchType = .host

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $match) {
                    ForEach(EnrichMatchType.allCases) { m in Text(m.label).tag(m) }
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: match) { _, v in
                    var r = rule; r.match = v; model.updateRule(r)
                }
                TextField("pattern (e.g. *.atlassian.net)", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: pattern) { _, v in
                        var r = rule; r.pattern = v; model.updateRule(r)
                    }
                Button { model.removeRule(id: rule.id) } label: {
                    Image(systemName: "minus.circle").foregroundColor(.red)
                }.buttonStyle(.plain)
            }
            TextField("Context hint sent to Claude", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onChange(of: text) { _, v in
                    var r = rule; r.text = v; model.updateRule(r)
                }
        }
        .padding(.vertical, 6)
        .onAppear { pattern = rule.pattern; text = rule.text; match = rule.match }
    }
}

// MARK: - Export / Import settings

private func exportSettings() {
    let hotkeys = (try? Data(contentsOf: URL(fileURLWithPath: CFG))) ?? Data()
    let customs = (try? Data(contentsOf: URL(fileURLWithPath: CUSTOM_ACTIONS_PATH))) ?? Data()
    let hkObj  = (try? JSONSerialization.jsonObject(with: hotkeys))  ?? []
    let caObj  = (try? JSONSerialization.jsonObject(with: customs))  ?? []
    let bundle: [String: Any] = ["hotkeys": hkObj, "customActions": caObj, "version": 1]
    guard let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted]) else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "claude-command-settings.json"
    if panel.runModal() == .OK, let url = panel.url {
        try? data.write(to: url)
    }
}

private func importSettings(model: SettingsModel) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.message = "Select a claude-command-settings.json export file"
    guard panel.runModal() == .OK, let url = panel.url,
          let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    if let hk = obj["hotkeys"], let hkData = try? JSONSerialization.data(withJSONObject: hk) {
        try? hkData.write(to: URL(fileURLWithPath: CFG))
    }
    if let ca = obj["customActions"], let caData = try? JSONSerialization.data(withJSONObject: ca) {
        try? caData.write(to: URL(fileURLWithPath: CUSTOM_ACTIONS_PATH))
    }
    reregisterHotkeys()
    model.refresh()
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

// Auto-sizing NSTextView that reports its height via intrinsicContentSize.
final class FittingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        tc.containerSize = NSSize(width: bounds.width > 0 ? bounds.width : 400, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(lm.usedRect(for: tc).height) + 4)
    }
    override func layout() { super.layout(); invalidateIntrinsicContentSize() }
}

// NSTextView wrapper: auto-sizes to content, reports selected text (sticky — keeps last non-empty selection).
struct SelectableText: NSViewRepresentable {
    let text: String
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> FittingTextView {
        let tv = FittingTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.delegate = context.coordinator
        tv.string = text
        return tv
    }

    func updateNSView(_ tv: FittingTextView, context: Context) {
        if tv.string != text { tv.string = text; tv.invalidateIntrinsicContentSize() }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var selection: String
        init(selection: Binding<String>) { _selection = selection }
        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            let r = tv.selectedRange()
            // Keep last non-empty selection — clicking the wand deselects before the action fires
            if r.length > 0 { selection = (tv.string as NSString).substring(with: r) }
        }
    }
}

// Captures fullText + preselected together at the moment the wand is tapped, so
// .sheet(item:) always presents with the selection that was live on click — no
// race against SwiftUI re-rendering selectedText out from under a separate
// isPresented flag.
private struct CorrectionRequest: Identifiable {
    let id = UUID()
    let fullText: String
    let preselected: String
}

struct HistoryEntryRow: View {
    let entry: HistoryStore.Record
    @ObservedObject private var hist: HistoryStore = .shared
    @State private var correctionRequest: CorrectionRequest? = nil
    @State private var selectedText = ""

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

                Button {
                    correctionRequest = CorrectionRequest(fullText: entry.processed, preselected: selectedText)
                } label: {
                    Image(systemName: "wand.and.sparkles").font(.caption)
                }.buttonStyle(.plain).help("Add correction — select a word first, then click")

                Button { hist.remove(id: entry.id) } label: {
                    Image(systemName: "trash").font(.caption).foregroundColor(.red)
                }.buttonStyle(.plain).help("Delete")
            }
            SelectableText(text: entry.processed, selection: $selectedText)
            if entry.processed != entry.raw {
                Text("Raw: \(entry.raw)").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
        .sheet(item: $correctionRequest) { req in
            DictCorrectionSheet(fullText: req.fullText,
                                preselected: req.preselected,
                                isPresented: Binding(
                                    get: { correctionRequest != nil },
                                    set: { if !$0 { correctionRequest = nil } }))
        }
    }
}

struct DictCorrectionSheet: View {
    let fullText: String
    let preselected: String
    @Binding var isPresented: Bool

    @State private var wrong: String = ""
    @State private var correct: String = ""
    @ObservedObject private var vocab: VocabularyStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Correction").font(.headline)

            Text("From dictation:").font(.caption).foregroundColor(.secondary)
            ScrollView {
                Text(fullText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .background(Color.secondary.opacity(0.07))
            .cornerRadius(6)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Misheard").font(.caption).foregroundColor(.secondary)
                    TextField("wrong word or phrase", text: $wrong)
                        .textFieldStyle(.roundedBorder)
                }
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .padding(.top, 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Correct").font(.caption).foregroundColor(.secondary)
                    TextField("correct word or phrase", text: $correct)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save to Corrections") {
                    let w = wrong.trimmingCharacters(in: .whitespaces)
                    let c = correct.trimmingCharacters(in: .whitespaces)
                    guard !w.isEmpty, !c.isEmpty else { return }
                    vocab.addReplacement(wrong: w, correct: c)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(wrong.trimmingCharacters(in: .whitespaces).isEmpty ||
                          correct.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 440)
        .onAppear { wrong = preselected }
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

// ---- Sound browser -----------------------------------------------------------

private let kAllSounds = ["Basso","Blow","Bottle","Frog","Funk","Glass","Hero",
                          "Morse","Ping","Pop","Purr","Sosumi","Submarine","Tink"]

struct SoundBrowserView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(kAllSounds.enumerated()), id: \.offset) { i, name in
                SoundRow(name: name, model: model)
                if i < kAllSounds.count - 1 { Divider().padding(.leading, 40) }
            }
        }
    }
}

struct SoundRow: View {
    let name: String
    @ObservedObject var model: SettingsModel
    @State private var playing = false

    private var isStart: Bool { model.startSound == name }
    private var isStop:  Bool { model.stopSound  == name }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                playing = true
                let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
                if let s = NSSound(contentsOf: url, byReference: true) {
                    s.volume = Float(model.soundVolume)
                    s.play()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { playing = false }
            } label: {
                Image(systemName: playing ? "speaker.wave.2.fill" : "play.circle")
                    .font(.system(size: 15))
                    .foregroundColor(playing ? .accentColor : .secondary)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)

            Text(name).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)

            if isStart {
                badge("Start", color: .green)
            }
            if isStop {
                badge("Stop", color: .blue)
            }

            Button("→ Start") {
                model.startSound = name
                UserDefaults.standard.set(name, forKey: "startSound")
            }
            .buttonStyle(.bordered).controlSize(.mini)
            .disabled(isStart)

            Button("→ Stop") {
                model.stopSound = name
                UserDefaults.standard.set(name, forKey: "stopSound")
            }
            .buttonStyle(.bordered).controlSize(.mini)
            .disabled(isStop)
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label).font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15)).cornerRadius(4)
            .foregroundColor(color)
    }
}

// ---- Dictation: Settings ------------------------------------------------------

struct DictSettingsView: View {
    @ObservedObject private var rec:   Recorder           = recorder
    @ObservedObject private var proc:  ProcessingSettings = .shared
    @ObservedObject private var model: SettingsModel      = settingsModel
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

                GroupBox(label: Text("Sounds").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Sound effects", isOn: Binding(
                                get: { model.soundsEnabled },
                                set: { model.soundsEnabled = $0; UserDefaults.standard.set($0, forKey: "soundsEnabled") }
                            ))
                            Spacer()
                        }
                        if model.soundsEnabled {
                            HStack(spacing: 10) {
                                Text("Volume").font(.callout).frame(width: 56, alignment: .leading)
                                Slider(value: Binding(
                                    get: { model.soundVolume },
                                    set: { model.soundVolume = $0; UserDefaults.standard.set($0, forKey: "soundVolume") }
                                ), in: 0...1)
                                Text("\(Int(model.soundVolume * 100))%")
                                    .font(.caption).foregroundColor(.secondary).frame(width: 34, alignment: .trailing)
                            }
                            Divider()
                            Text("Click ▶ to preview · → Start / → Stop to assign")
                                .font(.caption).foregroundColor(.secondary)
                            SoundBrowserView(model: model)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15)))
                        }
                    }.padding(.vertical, 8)
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
