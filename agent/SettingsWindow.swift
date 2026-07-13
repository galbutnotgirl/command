// SettingsWindow.swift — the menu-bar window: Set Up (live permission checks +
// a step graphic), Shortcuts, Context, Command History, Dictation, About.
// Hosted via NSHostingController so the rest of the agent stays AppKit.

import Cocoa
import SwiftUI
import Combine
import AVFoundation
import ClaudeCommandCore

// Repo URL lives in Updater.swift (GITHUB_REPO_URL) as the single source of truth.

enum SettingsTab: Equatable {
    case setup, shortcuts, history, templates, handoffs, background
    case dictHistory, dictCorrections, dictVocabulary, dictSettings
    case about

    var storageValue: String {
        switch self {
        case .setup: return "setup"
        case .shortcuts: return "shortcuts"
        case .history: return "history"
        case .templates: return "templates"
        case .handoffs: return "handoffs"
        case .background: return "background"
        case .dictHistory: return "dictHistory"
        case .dictCorrections: return "dictCorrections"
        case .dictVocabulary: return "dictVocabulary"
        case .dictSettings: return "dictSettings"
        case .about: return "about"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "setup": self = .setup
        case "shortcuts": self = .shortcuts
        case "history": self = .history
        case "templates": self = .templates
        case "handoffs": self = .handoffs
        case "background": self = .background
        case "dictHistory": self = .dictHistory
        case "dictCorrections": self = .dictCorrections
        case "dictVocabulary": self = .dictVocabulary
        case "dictSettings": self = .dictSettings
        case "about": self = .about
        default: return nil
        }
    }
}

// Single shared model (the local key monitor in main.swift also talks to it
// while recording a rebind).
let settingsModel = SettingsModel()
let settingsWindow = SettingsWindowController()

// One card style for every list row across Settings (Shortcuts bindings/custom
// actions, Templates rules, Dictation history/corrections/vocabulary) — was three
// different ad hoc patterns (bare Dividers with no background, a manually-drawn
// card in Setup, a plain GroupBox everywhere else), which is what made the whole
// window feel visually inconsistent. Spacing between cards, not divider lines
// inside one continuous block — reads as separate items, not one tight list.
// .tint() (set on SettingsRootView below) covers real controls — Picker,
// Toggle, segmented styles — but raw Color.accentColor/.accentColor references
// used as a plain foregroundColor/background (badges, icons, selected-row
// highlights) don't reliably re-resolve from it in practice. Use this directly
// wherever purple is the actual intent instead of routing through the ambient
// accent color.
let appPurple = Color(nsColor: purpleAccent)
// Fixed (not appearance-dependent) — for the few spots that paint a solid
// purple fill behind *white* text; that pairing needs the deep purple in
// both light and dark mode, unlike appPurple's dark-mode lightening.
let appPurpleSolid = Color(red: 112/255, green: 40/255, blue: 215/255)

private enum ShortcutRowLayout {
    static let nestedLeading: CGFloat = 28
    static let icon: CGFloat = 16
    static let label: CGFloat = 130
    static let shortcut: CGFloat = 74
}

private enum CustomActionSheetLayout {
    static let width: CGFloat = 820
    static let height: CGFloat = 680
    static let fieldColumn: CGFloat = 356
    static let triggerPicker: CGFloat = 156
}

func openHelpDoc(named name: String, fragment: String? = nil) {
    if let local = Bundle.main.url(forResource: name, withExtension: "html", subdirectory: "docs") {
        var components = URLComponents(url: local, resolvingAgainstBaseURL: false)
        if let fragment, !fragment.isEmpty { components?.fragment = fragment }
        NSWorkspace.shared.open(components?.url ?? local)
        return
    }
    guard !DOCS_SITE_URL.isEmpty else { return }
    let urlString = name == "index" ? DOCS_SITE_URL : "\(DOCS_SITE_URL)\(name).html"
    var components = URLComponents(string: urlString)
    if let fragment, !fragment.isEmpty { components?.fragment = fragment }
    if let url = components?.url { NSWorkspace.shared.open(url) }
}

extension View {
    func settingsCard() -> some View {
        self
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15), lineWidth: 1))
    }
}

// ---- model ------------------------------------------------------------------
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .setup
    @Published var perms: [StatusCheck] = []
    @Published var comps: [StatusCheck] = []
    @Published var bindings: [HotkeyBinding] = []
    @Published var customActions: [CustomAction] = []
    @Published var recordingAction: String? = nil
    @Published var bindingConflict: String? = nil
    @Published var claudeDestination: String = UserDefaults.standard.string(forKey: "claudeDestination") ?? "recent"
    @Published var codexDestination: String = UserDefaults.standard.string(forKey: "codexDestination") ?? "code"
    @Published var defaultProvider: String = UserDefaults.standard.string(forKey: "defaultProvider") ?? "claude"
    @Published var codexWorkspace: String = UserDefaults.standard.string(forKey: "codexWorkspace") ?? NSHomeDirectory()
    @Published var soundsEnabled: Bool = (UserDefaults.standard.object(forKey: VoiceSettingsKeys.soundsEnabled) as? Bool) ?? VoiceSettingsDefaults.soundsEnabled
    @Published var soundVolume: Double = (UserDefaults.standard.object(forKey: VoiceSettingsKeys.soundVolume) as? Double) ?? VoiceSettingsDefaults.soundVolume
    @Published var startSound: String = UserDefaults.standard.string(forKey: VoiceSettingsKeys.startSound) ?? VoiceSettingsDefaults.startSound
    @Published var stopSound: String = UserDefaults.standard.string(forKey: VoiceSettingsKeys.stopSound) ?? VoiceSettingsDefaults.stopSound
    @Published var dictationAssistantProvider: String = UserDefaults.standard.string(forKey: VoiceSettingsKeys.dictationAssistantProvider) ?? VoiceSettingsDefaults.dictationAssistantProvider

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
    // `recordingAction` holds a plain action string for fixed bindings, or a
    // trigger's own id for a custom action's trigger (an action's triggers
    // don't have one shared key to record against — each one does).
    func handleRecording(_ ev: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }
        if ev.keyCode == 53 { cancelRecording(); return true }              // esc cancels
        let isCustomTrigger = customActions.contains { $0.triggers.contains { $0.id == action } }
        if ev.keyCode == 51 || ev.keyCode == 117 {                         // delete / fwd-delete = clear
            recordingAction = nil
            if isCustomTrigger { clearTriggerBinding(triggerID: action) } else { clearBinding(action) }
            reregisterHotkeys()
            return true
        }
        let key = UInt32(ev.keyCode)
        guard KEYCODE_NAMES[key] != nil else { return true }                // ignore keys we can't name
        let carbonM = carbonMods(from: ev.modifierFlags)
        recordingAction = nil
        if isCustomTrigger {
            setTriggerBinding(triggerID: action, keycode: key, mods: carbonM)
        } else {
            setBinding(action: action, keycode: key, mods: carbonM)
        }
        checkConflict(forAction: action, keycode: key, mods: carbonM)
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
        // Preserve the existing triggers — the edit sheet only touches the
        // shared body (name/prompt/skill/delivery/defaults), not the trigger list.
        if let i = customActions.firstIndex(where: { $0.id == ca.id }) {
            var updated = ca
            updated.triggers = customActions[i].triggers
            customActions[i] = updated
        }
        saveCustomActions(customActions)
    }

    // ---- trigger CRUD (one action, many ways to fire it) ----
    func addTrigger(actionID: String, kind: ActionKind) {
        guard let i = customActions.firstIndex(where: { $0.id == actionID }) else { return }
        customActions[i].triggers.append(ActionTrigger(kind: kind))
        saveCustomActions(customActions)
    }
    func removeTrigger(actionID: String, triggerID: String) {
        guard let i = customActions.firstIndex(where: { $0.id == actionID }) else { return }
        customActions[i].triggers.removeAll { $0.id == triggerID }
        saveCustomActions(customActions)
    }
    func setTriggerBinding(triggerID: String, keycode: UInt32, mods: UInt32) {
        for i in customActions.indices {
            if let j = customActions[i].triggers.firstIndex(where: { $0.id == triggerID }) {
                customActions[i].triggers[j].keycode = keycode
                customActions[i].triggers[j].mods = mods
                break
            }
        }
        saveCustomActions(customActions)
    }
    func clearTriggerBinding(triggerID: String) { setTriggerBinding(triggerID: triggerID, keycode: 0, mods: 0) }
    func setTriggerKind(triggerID: String, kind: ActionKind) {
        for i in customActions.indices {
            if let j = customActions[i].triggers.firstIndex(where: { $0.id == triggerID }) {
                customActions[i].triggers[j].kind = kind
                break
            }
        }
        saveCustomActions(customActions)
    }
    func setTriggerDelivery(triggerID: String, delivery: ActionDelivery?) {
        for i in customActions.indices {
            if let j = customActions[i].triggers.firstIndex(where: { $0.id == triggerID }) {
                customActions[i].triggers[j].deliveryOverride = delivery
                customActions[i].triggers[j].sessionModeOverride = nil
                break
            }
        }
        saveCustomActions(customActions)
    }
    func setTriggerDestination(triggerID: String, destination: ClaudeDestination?) {
        for i in customActions.indices {
            if let j = customActions[i].triggers.firstIndex(where: { $0.id == triggerID }) {
                customActions[i].triggers[j].destinationOverride = destination
                break
            }
        }
        saveCustomActions(customActions)
    }
    func setTriggerProvider(triggerID: String, provider: AIProviderChoice?) {
        for i in customActions.indices {
            if let j = customActions[i].triggers.firstIndex(where: { $0.id == triggerID }) {
                customActions[i].triggers[j].providerOverride = provider
                if provider?.provider == .codex && customActions[i].triggers[j].destinationOverride == .cowork {
                    customActions[i].triggers[j].destinationOverride = nil
                }
                break
            }
        }
        saveCustomActions(customActions)
    }
    func setTriggerAutoSubmit(triggerID: String, autoSubmit: Bool?) {
        for i in customActions.indices {
            if let j = customActions[i].triggers.firstIndex(where: { $0.id == triggerID }) {
                customActions[i].triggers[j].isAutoSubmitOverride = autoSubmit
                break
            }
        }
        saveCustomActions(customActions)
    }

    // Check whether keycode+mods collides with any other binding (different action/id).
    // Sets bindingConflict to a human-readable message, or nil if clear.
    func checkConflict(forAction action: String, keycode: UInt32, mods: UInt32) {
        guard keycode != 0 else { bindingConflict = nil; return }
        if let other = bindings.first(where: { $0.keycode == keycode && $0.mods == mods && $0.action != action }) {
            bindingConflict = "Conflicts with \"\(other.action)\" shortcut"
            return
        }
        for ca in customActions {
            if let t = ca.triggers.first(where: { $0.keycode == keycode && $0.mods == mods && $0.id != action }) {
                bindingConflict = "Conflicts with custom action \"\(ca.name)\" (\(t.kind.label))"
                return
            }
        }
        bindingConflict = nil
    }
}

// NSSound does not retain itself while playing. Keep active cues alive until
// their delegate callback so short start/stop sounds are not clipped.
private final class UISoundPlayer: NSObject, NSSoundDelegate {
    static let shared = UISoundPlayer()
    private var activeSounds: [NSSound] = []

    func play(_ name: String, volume: Float) {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = volume
        sound.delegate = self
        activeSounds.append(sound)
        if !sound.play() { activeSounds.removeAll { $0 === sound } }
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        activeSounds.removeAll { $0 === sound }
    }
}

// Global helper — respects soundsEnabled + soundVolume from settingsModel.
func playUISound(_ name: String) {
    guard settingsModel.soundsEnabled else { return }
    UISoundPlayer.shared.play(name, volume: Float(settingsModel.soundVolume))
}

// ---- window controller ------------------------------------------------------
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var tabObserver: AnyCancellable?
    private let frameAutosaveName = "CommandSettingsWindowFrame"

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
        w.title = "Command"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 960, height: 600)
        w.setFrameAutosaveName(frameAutosaveName)
        w.delegate = self
        window = w
        tabObserver = settingsModel.$tab
            .receive(on: RunLoop.main)
            .sink { t in UserDefaults.standard.set(t.storageValue, forKey: "lastSettingsTab") }
    }

    // Size once on first show — large enough for all tabs without resizing on switch.
    // All tabs use ScrollView, so any overflow scrolls gracefully.
    private func sizeWindow(for tab: SettingsTab) {
        guard let w = window, !w.isVisible else { return }
        if UserDefaults.standard.object(forKey: "NSWindow Frame \(frameAutosaveName)") != nil { return }
        let cap = ((w.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 40
        let h = min(860, cap)
        w.setContentSize(NSSize(width: 1040, height: h))
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
        .frame(minWidth: 960, minHeight: 600)
        // Without this, every control that follows the system accent color — Pickers,
        // segmented controls, Toggles, text-field cursors, .accentColor(...) usages
        // sprinkled through this file — renders macOS's default blue, since the app
        // has no Xcode asset-catalog AccentColor to override it. One tint here fixes
        // all of them at once instead of patching each Color.accentColor reference.
        .tint(Color(nsColor: purpleAccent))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            tabButton(.setup, "Set Up", "checklist")
            tabButton(.about, "About", "info.circle")
            tabButton(.history, "Clipboard History", "clock.arrow.circlepath")

            Divider().padding(.vertical, 4)

            Text("SHORTCUTS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            tabButton(.shortcuts, "Shortcut Settings", "keyboard")
            tabButton(.templates, "Context", "doc.text.below.ecg")
            tabButton(.background, "Background", "terminal")
            tabButton(.handoffs, "History", "paperplane.circle")

            Divider().padding(.vertical, 4)

            Text("DICTATION")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            tabButton(.dictSettings,    "Settings",    "gear")
            tabButton(.dictVocabulary,  "Vocabulary",  "character.book.closed")
            tabButton(.dictCorrections, "Corrections", "text.badge.checkmark")
            tabButton(.dictHistory,     "History",     "clock")
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
            .background(model.tab == t ? appPurple.opacity(0.18) : Color.clear)
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
        case .handoffs:        HandoffsView()
        case .background:      HandoffSettingsView()
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
                    Text("Grant these before using Command.")
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
                    Button("Restart Command") { restartApp() }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    Text("Grant still red after enabling? Restart Command — macOS applies grants on relaunch.")
                        .font(.caption).foregroundColor(.secondary)
                    Text("If macOS asks again after a rebuild, re-grant permissions for Command.")
                        .font(.caption).foregroundColor(.secondary)
                    Text("Function-key shortcuts don't fire? Enable standard function keys in macOS Keyboard settings, or rebind prompt and dictation shortcuts.")
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
        case "Clipboard History":
            let enabled = UserDefaults.standard.bool(forKey: "cliphistoryEnabled")
            return CheckAction(label: enabled ? "Restart" : "Enable") {
                if !enabled { UserDefaults.standard.set(true, forKey: "cliphistoryEnabled") }
                stopClipwatch(); startClipwatch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.refresh() }
            }
        case "Background service":
            return CheckAction(label: "Restart") { restartApp() }
        case "Hotkeys configured":
            return CheckAction(label: "Shortcuts →") { model.tab = .shortcuts }
        case "Claude app":
            return CheckAction(label: "Install Help") { openHelpDoc(named: "install") }
        case "Claude CLI":
            return CheckAction(label: "Log In Help") { openHelpDoc(named: "troubleshooting", fragment: "claude-cli") }
        case "ChatGPT app":
            return CheckAction(label: "Install Help") { openHelpDoc(named: "install") }
        case "Codex CLI":
            return CheckAction(label: "Log In Help") { openHelpDoc(named: "troubleshooting", fragment: "codex-cli") }
        case "Codex workspace":
            return CheckAction(label: "Choose…") {
                let panel = NSOpenPanel()
                panel.title = "Choose Codex Workspace"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.directoryURL = URL(fileURLWithPath: model.codexWorkspace)
                if panel.runModal() == .OK, let url = panel.url {
                    model.codexWorkspace = url.path
                    UserDefaults.standard.set(url.path, forKey: "codexWorkspace")
                    model.refresh()
                }
            }
        case "Right-click actions":
            return CheckAction(label: "Learn") {
                openHelpDoc(named: "install", fragment: "source")
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
            Text("Revocation only applies after Command restarts.")
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
            return "→ System Settings → Privacy & Security → Accessibility → enable Command"
        }
        if t.contains("screen") {
            return "→ System Settings → Privacy & Security → Screen Recording → enable Command"
        }
        return nil
    }
}

// Compact status row for components
struct CompRow: View {
    let check: StatusCheck
    let action: CheckAction?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13))
                    .foregroundColor(statusColor)
                    .frame(width: 20)
                Text(check.title).font(.callout)
                Spacer()
                Button(expanded ? "Hide" : "Details") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if check.state != .ok, let a = action {
                    Button(a.label) { a.run() }
                        .buttonStyle(.bordered).controlSize(.small)
                } else if check.state == .ok {
                    Text("OK").font(.caption).foregroundColor(.secondary)
                } else {
                    Text("—").font(.caption).foregroundColor(.secondary)
                }
            }
            if expanded {
                Text(check.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
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
    @StateObject private var templates = TemplatesModel()
    @State private var showingAddCustom = false

    private var destBinding: Binding<String> {
        Binding(
            get: { model.claudeDestination },
            set: { model.claudeDestination = $0; UserDefaults.standard.set($0, forKey: "claudeDestination") }
        )
    }
    private var codexDestBinding: Binding<String> {
        Binding(
            get: { model.codexDestination },
            set: { model.codexDestination = $0; UserDefaults.standard.set($0, forKey: "codexDestination") }
        )
    }
    private var providerBinding: Binding<String> {
        Binding(
            get: { model.defaultProvider },
            set: { model.defaultProvider = $0; UserDefaults.standard.set($0, forKey: "defaultProvider") }
        )
    }
    private var workspaceBinding: Binding<String> {
        Binding(
            get: { model.codexWorkspace },
            set: { model.codexWorkspace = $0; UserDefaults.standard.set($0, forKey: "codexWorkspace") }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Shortcuts").font(.title2).bold()
                    Spacer()
                    Button(action: { exportGlobalBundle(sections: Set(GlobalBundleSection.allCases)) }) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export all Command settings. Import later lets you choose what to keep or overwrite.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Default assistant").font(.headline)
                    Picker("", selection: providerBinding) {
                        Text("Claude").tag("claude")
                        Text("ChatGPT").tag("codex")
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 240)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.defaultProvider == "codex" ? "Default ChatGPT destination" : "Default Claude destination").font(.headline)
                    Text("Used unless a prompt or individual trigger overrides it.")
                        .font(.caption).foregroundColor(.secondary)
                    if model.defaultProvider == "codex" {
                        Picker("", selection: codexDestBinding) {
                            Text("Chat").tag("chat")
                            Text("Codex").tag("code")
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 240)
                        if model.codexDestination == "code" {
                            Text("Default Codex workspace").font(.caption).bold()
                            TextField("Workspace path", text: workspaceBinding).textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 520)
                        }
                    } else {
                        Picker("", selection: destBinding) {
                            Text("Recent").tag("recent")
                            Text("Chat").tag("chat")
                            Text("Cowork").tag("cowork")
                            Text("Code").tag("code")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 340)
                    }
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Compose").font(.headline)
                    Text("One shared prompt with selected-text and screenshot combinations.")
                        .font(.caption).foregroundColor(.secondary)
                    BuiltInComposeCard(model: model, templates: templates)
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

                Text("Prompt groups with their own triggers, delivery, and destination.")
                    .font(.caption).foregroundColor(.secondary)

                VStack(spacing: 8) {
                    ForEach(model.customActions) { ca in
                        CustomActionRow(ca: ca, model: model)
                    }
                    if model.customActions.isEmpty {
                        Text("No user-defined custom actions yet — click Add to create one.")
                            .font(.caption).foregroundColor(.secondary).padding(.vertical, 4)
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

struct BuiltInComposeCard: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var templates: TemplatesModel
    @State private var showingEdit = false
    @State private var settings = loadBuiltInComposeSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "text.badge.checkmark").foregroundColor(appPurple).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Compose").font(.callout)
                    }
                    Text("Shared prompt. Behavior and auto-submit can vary by row.")
                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                Button(action: { showingEdit = true }) {
                    Image(systemName: "pencil").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit compose")
            }
            VStack(spacing: 6) {
                BuiltInComposeSummaryRow(def: def(for: "add"), binding: binding(for: "add"), autoSubmit: settings.effectiveAutoSubmit(for: "add"))
                BuiltInComposeSummaryRow(def: def(for: "comment"), binding: binding(for: "comment"), autoSubmit: settings.effectiveAutoSubmit(for: "comment"))
                BuiltInComposeSummaryRow(def: def(for: "go"), binding: binding(for: "go"), autoSubmit: settings.effectiveAutoSubmit(for: "go"))
                Divider().padding(.leading, ShortcutRowLayout.icon + 10)
                BuiltInComposeSummaryRow(def: def(for: "shotadd"), binding: binding(for: "shotadd"), autoSubmit: settings.effectiveAutoSubmit(for: "shotadd"))
                BuiltInComposeSummaryRow(def: def(for: "shotcomment"), binding: binding(for: "shotcomment"), autoSubmit: settings.effectiveAutoSubmit(for: "shotcomment"))
                BuiltInComposeSummaryRow(def: def(for: "shotgo"), binding: binding(for: "shotgo"), autoSubmit: settings.effectiveAutoSubmit(for: "shotgo"))
            }
            .padding(.leading, ShortcutRowLayout.nestedLeading)
        }
        .settingsCard()
        .sheet(isPresented: $showingEdit, onDismiss: { settings = loadBuiltInComposeSettings() }) {
            BuiltInComposeSheet(isPresented: $showingEdit, model: model, templates: templates)
        }
    }

    private func binding(for action: String) -> HotkeyBinding {
        model.bindings.first(where: { $0.action == action }) ?? HotkeyBinding(action: action, keycode: 0, mods: 0, enabled: true)
    }

    private func def(for action: String) -> BuiltInComposeRowDefinition {
        BUILTIN_COMPOSE_ROWS.first(where: { $0.action == action })!
    }
}

struct BuiltInComposeSummaryRow: View {
    let def: BuiltInComposeRowDefinition
    let binding: HotkeyBinding
    let autoSubmit: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: def.icon)
                .foregroundColor(appPurple)
                .frame(width: ShortcutRowLayout.icon)
                .help(def.inputLabel)
            Text(def.behaviorLabel)
                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12)).cornerRadius(4)
            if autoSubmit {
                Text("Auto-submit")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(appPurple.opacity(0.12)).cornerRadius(4)
            }
            Spacer()
            Text(binding.human)
                .font(.system(.body, design: .rounded).bold())
                .frame(width: ShortcutRowLayout.shortcut, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

enum AutoSubmitChoice: String, CaseIterable, Identifiable {
    case useDefault, on, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .useDefault: return "—"
        case .on: return "Auto-submit"
        case .off: return "Don't auto-submit"
        }
    }
    var boolValue: Bool? {
        switch self {
        case .useDefault: return nil
        case .on: return true
        case .off: return false
        }
    }
    static func from(_ value: Bool?) -> AutoSubmitChoice {
        switch value {
        case true: return .on
        case false: return .off
        case nil: return .useDefault
        }
    }
}

struct BuiltInComposeSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var model: SettingsModel
    @ObservedObject var templates: TemplatesModel

    @State private var prompt = ""
    @State private var defaultAutoSubmit = false
    @State private var overrides: [String: Bool] = [:]
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit Compose").font(.headline)
                Spacer()
                Button("Reset") { confirmingReset = true }
                    .buttonStyle(.bordered)
                    .help("Restore original built-in Compose prompt and row behavior.")
            }

            Toggle("Default auto-submit", isOn: $defaultAutoSubmit)
                .help("Used unless a row overrides it.")

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt text").font(.caption).bold()
                Text("Shared across selected-text and screenshot compose rows.")
                    .font(.caption).foregroundColor(.secondary)
                TextEditor(text: $prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            }

            if !templates.builtInComposeTemplatesAreUnified {
                Text("Prompt variants were different before. Saving here will unify them.")
                    .font(.caption2).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Triggers").font(.caption).bold()
                ForEach(BUILTIN_COMPOSE_ROWS) { def in
                    EditableBuiltInComposeRow(def: def,
                                              binding: binding(for: def.action),
                                              autoSubmitChoice: Binding(
                                                get: { AutoSubmitChoice.from(overrides[def.action]) },
                                                set: { overrides[def.action] = $0.boolValue }
                                              ),
                                              model: model)
                }
            }

            TemplateVariablesLegend(compact: true)

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    templates.setBuiltInComposeTemplate(prompt)
                    saveBuiltInComposeSettings(BuiltInComposeSettings(autoSubmitDefault: defaultAutoSubmit,
                                                                     autoSubmitOverrides: overrides))
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 420)
        .alert("Reset built-in Compose?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                templates.resetBuiltInComposeTemplates()
                let defaults = DEFAULT_BUILTIN_COMPOSE_SETTINGS
                saveBuiltInComposeSettings(defaults)
                prompt = templates.builtInComposeTemplate
                defaultAutoSubmit = defaults.autoSubmitDefault
                overrides = defaults.autoSubmitOverrides
            }
        } message: {
            Text("This restores original built-in prompt variants, auto-submit defaults, and row overrides.")
        }
        .onAppear {
            let settings = loadBuiltInComposeSettings()
            prompt = templates.builtInComposeTemplate
            defaultAutoSubmit = settings.autoSubmitDefault
            overrides = settings.autoSubmitOverrides
        }
    }

    private func binding(for action: String) -> HotkeyBinding {
        model.bindings.first(where: { $0.action == action }) ?? HotkeyBinding(action: action, keycode: 0, mods: 0, enabled: true)
    }
}

struct EditableBuiltInComposeRow: View {
    let def: BuiltInComposeRowDefinition
    let binding: HotkeyBinding
    @Binding var autoSubmitChoice: AutoSubmitChoice
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: def.icon).foregroundColor(appPurple).frame(width: 16)
                .help(def.inputLabel)
            Text(def.behaviorLabel).font(.caption).frame(width: 120, alignment: .leading)
            Picker("", selection: $autoSubmitChoice) {
                ForEach(AutoSubmitChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .labelsHidden().frame(width: 150)
            Spacer()
            KeyBindingField(action: binding.action, binding: binding, model: model)
        }
    }
}

// One shared prompt body (name/prompt/skill/delivery), any number of ways to
// fire it. The header row is the body; each trigger gets its own sub-row
// with its own kind + hotkey, so e.g. a popup binding and a voice binding of
// the same action reuse one prompt instead of duplicating it.
struct CustomActionRow: View {
    let ca: CustomAction
    @ObservedObject var model: SettingsModel
    @State private var showingEdit = false
    @State private var confirmingDelete = false
    private var resolvedProvider: AIProvider {
        ca.provider.resolve(default: AIProvider(rawValue: model.defaultProvider) ?? .claude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: ca.delivery == .background ? "paperplane.circle" : "text.cursor")
                    .foregroundColor(appPurple).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ca.name).font(.callout)
                        Text(ca.delivery.label)
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                        Text(resolvedProvider.label)
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                        if resolvedProvider.supportsDestinations {
                            Text(ca.destination.label(for: resolvedProvider))
                                .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                        }
                        if !ca.includeSource && ca.delivery != .background {
                            Text("no src").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                        }
                        if ca.isAutoSubmit && ca.delivery != .background {
                            Text("Auto-submit")
                                .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(appPurple.opacity(0.12)).cornerRadius(4)
                        }
                    }
                }
                Spacer()
                Button(action: { showingEdit = true }) {
                    Image(systemName: "pencil").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit action")
                Button(action: { confirmingDelete = true }) {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Delete action")
            }

            ForEach(ca.triggers) { trig in
                TriggerSummaryRow(trigger: trig, action: ca,
                                  provider: ca.effectiveProvider(for: trig, default: AIProvider(rawValue: model.defaultProvider) ?? .claude))
            }
        }
        .settingsCard()
        .sheet(isPresented: $showingEdit) {
            CustomActionSheet(isPresented: $showingEdit, model: model, editing: ca)
        }
        .alert("Delete \"\(ca.name)\"?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deleteCustomAction(id: ca.id) }
        } message: {
            Text("This removes the action, its prompt, and all of its triggers.")
        }
    }
}

struct TriggerSummaryRow: View {
    let trigger: ActionTrigger
    let action: CustomAction
    let provider: AIProvider

    private var kindIcon: String {
        switch trigger.kind {
        case .text: return "text.cursor"
        case .screenshot: return "camera.viewfinder"
        case .popup: return "text.bubble"
        case .voice: return "waveform"
        }
    }

    var body: some View {
        let kindLabel = trigger.kind.label.components(separatedBy: " (").first ?? trigger.kind.label
        HStack(spacing: 10) {
            Image(systemName: kindIcon).foregroundColor(appPurple).frame(width: ShortcutRowLayout.icon)
            Text(kindLabel).font(.caption).frame(width: ShortcutRowLayout.label, alignment: .leading)
            if let delivery = trigger.deliveryOverride {
                Text(delivery.label)
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12)).cornerRadius(4)
            }
            if let provider = trigger.providerOverride {
                Text(provider.label)
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12)).cornerRadius(4)
            }
            if let destination = trigger.destinationOverride {
                Text(destination.label(for: provider))
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12)).cornerRadius(4)
            }
            if let autoSubmit = trigger.isAutoSubmitOverride {
                Text(autoSubmit ? "Auto-submit" : "Don't auto-submit")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(appPurple.opacity(0.12)).cornerRadius(4)
            }
            Spacer()
            Text(trigger.human)
                .font(.system(.body, design: .rounded).bold())
                .frame(width: ShortcutRowLayout.shortcut, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, ShortcutRowLayout.nestedLeading)
    }
}

struct TriggerKeyBindingField: View {
    let trigger: ActionTrigger
    @ObservedObject var model: SettingsModel
    private var isRecording: Bool { model.recordingAction == trigger.id }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(isRecording ? appPurple.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(isRecording ? appPurple : Color.gray.opacity(0.35), lineWidth: 1))
            Text(isRecording ? "Press keys…" : trigger.human)
                .font(.system(.body, design: .rounded).bold())
                .foregroundColor(isRecording ? appPurple : (trigger.keycode == 0 ? .secondary : .primary))
                .lineLimit(1).padding(.horizontal, 10)
        }
        .frame(width: 120, height: 30)
        .contentShape(Rectangle())
        .onTapGesture {
            if isRecording { model.cancelRecording() } else { model.startRecording(trigger.id) }
        }
        .help(isRecording ? "Press a key combo · Delete to clear · Esc to cancel" : "Click to set shortcut")
    }
}

// The shared body only — name/prompt/skill/delivery/default overrides.
// Trigger kind + hotkey editing lives inline in the row (TriggerRow above),
// not here, since one action can have several triggers.
struct CustomActionSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var model: SettingsModel
    var editing: CustomAction? = nil

    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var isAutoSubmit: Bool = false
    @State private var sessionMode: String = "new"
    @State private var includeSource: Bool = true
    @State private var delivery: ActionDelivery = .newChat
    @State private var destination: ClaudeDestination = .default
    @State private var provider: AIProviderChoice = .default
    @State private var skill: String = ""
    @State private var actionTriggers: [ActionTrigger] = []
    private var resolvedProvider: AIProvider {
        provider.resolve(default: AIProvider(rawValue: model.defaultProvider) ?? .claude)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(editing == nil ? "New Custom Action" : "Edit Custom Action").font(.headline)
                Text("Prompt defaults apply to every trigger unless a trigger row overrides them.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Action name").font(.caption).bold()
                        TextField("Summarize", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Assistant").font(.caption).bold()
                            Picker("", selection: $provider) {
                                ForEach(AIProviderChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.segmented)
                            .onChange(of: provider) { _, _ in
                                if resolvedProvider == .codex && destination == .cowork { destination = .default }
                            }
                        }
                        .frame(width: CustomActionSheetLayout.fieldColumn, alignment: .leading)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Text("Delivery").font(.caption).bold()
                                Image(systemName: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .help("Existing session pastes into open assistant. New session opens a fresh composer. Background runs a local CLI without opening assistant app.")
                            }
                            Picker("", selection: $delivery) {
                                ForEach(ActionDelivery.allCases, id: \.self) { d in Text(d.label).tag(d) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                                .help("Existing session pastes into selected assistant. New session opens a fresh composer. Background runs selected local CLI.")
                        }
                        .frame(width: CustomActionSheetLayout.fieldColumn, alignment: .leading)

                    }

                    if resolvedProvider.supportsDestinations {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Destination").font(.caption).bold()
                            Picker("", selection: $destination) {
                                ForEach(ClaudeDestination.available(for: resolvedProvider), id: \.self) { d in
                                    Text(d.label(for: resolvedProvider)).tag(d)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .help(resolvedProvider == .claude ? "Default uses global Claude destination. Chat, Cowork, and Code override it." : "Default uses global ChatGPT destination. Chat and Codex override it.")
                        }
                        .frame(maxWidth: CustomActionSheetLayout.fieldColumn, alignment: .leading)
                    }

                    if delivery == .background {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Background skill").font(.caption).bold()
                                Button("Setup guide") { openHelpDoc(named: "background") }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                            TextField("triage-capture (empty = claude -p)", text: $skill)
                                .textFieldStyle(.roundedBorder)
                        }
                    } else {
                        HStack(spacing: 18) {
                            Toggle("Include source app", isOn: $includeSource)
                                .help("Prepend \"from: AppName — URL\" before the prompt. Default for triggers that don't override it.")
                            Toggle("Auto-submit", isOn: $isAutoSubmit)
                                .help("Press Return automatically after pasting prompt into selected assistant. Default for triggers without override.")
                            Spacer()
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Prompt text").font(.caption).bold()
                        Text("Use {selection} for captured content and {file} for screenshot file paths.")
                            .font(.caption).foregroundColor(.secondary)
                        TextEditor(text: $prompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 112)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3)))
                    }

                    if editing == nil {
                        Text("New actions start with one Selected text trigger. Save, then reopen to add screenshot, popup, or voice triggers.")
                            .font(.caption2).foregroundColor(.secondary)
                    } else if let editingAction = editing {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Triggers").font(.caption).bold()
                                Spacer()
                                Menu {
                                    ForEach(ActionKind.allCases, id: \.self) { k in
                                        Button(k.label) { model.addTrigger(actionID: editingAction.id, kind: k) }
                                    }
                                } label: {
                                    Label("Add Trigger", systemImage: "plus.circle").font(.caption)
                                }
                                .menuStyle(.borderlessButton).fixedSize()
                            }
                            ForEach(actionTriggers) { trigger in
                                EditableTriggerRow(actionID: editingAction.id, trigger: trigger, model: model,
                                                   canRemove: actionTriggers.count > 1)
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(editing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: CustomActionSheetLayout.width, height: CustomActionSheetLayout.height)
        .onAppear {
            if let e = editing {
                name = e.name; prompt = e.prompt
                isAutoSubmit = e.isAutoSubmit
                delivery = e.delivery; destination = e.destination; provider = e.provider
                sessionMode = e.sessionMode; includeSource = e.includeSource
                skill = e.skill
                actionTriggers = e.triggers
            }
        }
        .onReceive(model.$customActions) { actions in
            guard let editing else { return }
            actionTriggers = actions.first(where: { $0.id == editing.id })?.triggers ?? []
        }
    }

    private func save() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let trimSkill = skill.trimmingCharacters(in: .whitespaces)
        guard !trimName.isEmpty else { return }
        if let existing = editing {
            var updated = existing
            updated.name = trimName; updated.prompt = prompt
            updated.isAutoSubmit = isAutoSubmit
            updated.delivery = delivery; updated.destination = destination; updated.provider = provider
            updated.sessionMode = delivery.sessionMode; updated.includeSource = includeSource
            updated.isHandoff = delivery == .background; updated.skill = trimSkill
            model.updateCustomAction(updated)
        } else {
            var ca = CustomAction.makeNew(name: trimName, prompt: prompt, kind: .text,
                                           isHandoff: delivery == .background, skill: trimSkill)
            ca.isAutoSubmit = isAutoSubmit
            ca.delivery = delivery; ca.destination = destination; ca.provider = provider
            ca.sessionMode = delivery.sessionMode; ca.includeSource = includeSource
            model.addCustomAction(ca)
        }
        isPresented = false
    }
}

struct EditableTriggerRow: View {
    let actionID: String
    let trigger: ActionTrigger
    @ObservedObject var model: SettingsModel
    let canRemove: Bool

    private var effectiveProvider: AIProvider {
        let global = AIProvider(rawValue: model.defaultProvider) ?? .claude
        guard let action = model.customActions.first(where: { $0.id == actionID }) else { return global }
        return action.effectiveProvider(for: trigger, default: global)
    }

    private var kindIcon: String {
        switch trigger.kind {
        case .text: return "text.cursor"
        case .screenshot: return "camera.viewfinder"
        case .popup: return "text.bubble"
        case .voice: return "waveform"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: kindIcon).foregroundColor(appPurple).frame(width: 16)
                Picker("", selection: Binding(
                    get: { trigger.kind },
                    set: { model.setTriggerKind(triggerID: trigger.id, kind: $0) }
                )) {
                    ForEach(ActionKind.allCases, id: \.self) { k in
                        Text(k.label.components(separatedBy: " (").first ?? k.label).tag(k)
                    }
                }
                .labelsHidden().frame(width: 150)
                Spacer()
                TriggerKeyBindingField(trigger: trigger, model: model)
                Button(action: { model.removeTrigger(actionID: actionID, triggerID: trigger.id) }) {
                    Image(systemName: "minus.circle").foregroundColor(.secondary)
                }
                .buttonStyle(.plain).disabled(!canRemove)
                .help(canRemove ? "Remove this trigger" : "Action needs at least one trigger")
            }

            HStack(spacing: 12) {
                LabeledPicker(caption: "Assistant") {
                    Picker("", selection: Binding(
                        get: { trigger.providerOverride },
                        set: { model.setTriggerProvider(triggerID: trigger.id, provider: $0) }
                    )) {
                        Text("—").tag(Optional<AIProviderChoice>.none)
                        Text("Claude").tag(Optional(AIProviderChoice.claude))
                        Text("ChatGPT").tag(Optional(AIProviderChoice.codex))
                    }
                }

                LabeledPicker(caption: "Delivery") {
                    Picker("", selection: Binding(
                        get: { trigger.deliveryOverride },
                        set: { model.setTriggerDelivery(triggerID: trigger.id, delivery: $0) }
                    )) {
                        Text("—").tag(Optional<ActionDelivery>.none)
                        ForEach(ActionDelivery.allCases, id: \.self) { d in
                            Text(d.label).tag(Optional(d))
                        }
                    }
                    .help("Existing session pastes into open assistant. New session opens a fresh composer. Background runs a local CLI.")
                }

                if effectiveProvider.supportsDestinations { LabeledPicker(caption: "Destination") {
                    Picker("", selection: Binding(
                        get: { trigger.destinationOverride },
                        set: { model.setTriggerDestination(triggerID: trigger.id, destination: $0) }
                    )) {
                        Text("—").tag(Optional<ClaudeDestination>.none)
                        ForEach(ClaudeDestination.available(for: effectiveProvider, includeDefault: false), id: \.self) { d in
                            Text(d.label(for: effectiveProvider)).tag(Optional(d))
                        }
                    }
                } }

                LabeledPicker(caption: "Submit") {
                    Picker("", selection: Binding(
                        get: { AutoSubmitChoice.from(trigger.isAutoSubmitOverride) },
                        set: { model.setTriggerAutoSubmit(triggerID: trigger.id, autoSubmit: $0.boolValue) }
                    )) {
                        ForEach(AutoSubmitChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

private struct LabeledPicker<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption).font(.caption2).foregroundColor(.secondary)
            content.labelsHidden().frame(width: CustomActionSheetLayout.triggerPicker)
        }
    }
}

// ---- Context: auto-context rules used by built-in and custom prompts ----------

struct TemplatesView: View {
    @StateObject private var model = TemplatesModel()
    @State private var previewSource: PreviewSource = PreviewSource(label: "Generic (no match)", appName: "Chrome", url: "", enrich: "", displayName: "")

    private let sampleSelection = "the exact text you'd have selected"

    private var sources: [PreviewSource] { previewSources(from: model.rules) }

    private var preview: String {
        return composePreview(action: "add", template: "{source}\n\n{context}\n\n{selection}",
                               source: previewSource, selection: sampleSelection)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Context").font(.title2).bold()
                    Spacer()
                }
                Text("Rules that add app/site-specific source context to prompts. Built-in prompt text now lives in Shortcuts.")
                    .foregroundColor(.secondary)

                // ---- preview first, then the variables it's built from, then the
                // boxes themselves — visually its own thing, not part of the Add/New/Go
                // boxes below it. ----
                VStack(alignment: .leading, spacing: 10) {
                    Text("Preview").font(.title3).bold()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Preview as").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $previewSource) {
                                ForEach(sources) { s in Text(s.label).tag(s) }
                            }
                            .labelsHidden().frame(width: 180)
                            .onAppear { if let first = sources.first { previewSource = first } }
                            Spacer()
                        }
                        Text(preview.isEmpty ? "(empty)" : preview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                    }
                    .settingsCard()
                }

                // Variables for Add/New/Go specifically — {url} also works inside a
                // Context rule's hint text below, but {selection}/{context}/{source}
                // are only meaningful up here, so the legend lives with what it's for.
                TemplateVariablesLegend()

                Divider()

                HStack {
                    Text("Context").font(.headline)
                    Spacer()
                    Button("Reset All to Default") { model.resetRulesToDefault() }
                        .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                    Button(action: { model.addRule() }) {
                        Label("Add", systemImage: "plus.circle")
                    }
                }
                Text("Feeds {context} above and the [from: App] line every action includes — e.g. \"this is from Slack, use the Slack MCP.\" Matched by app bundle ID, app name, or URL host (supports leading \"*.\" glob) — a host rule can also add a Path prefix to split rules that share a host, like docs.google.com/document/ vs. /spreadsheets/. Use {url} in the text to insert the source URL, and Display name to replace the [from: …] line (handy for a browser match — no need to show \"Chrome\" once the URL already says Gmail).")
                    .font(.caption).foregroundColor(.secondary)

                VStack(spacing: 8) {
                    ForEach(model.rules) { rule in
                        EnrichRuleRow(rule: rule, model: model)
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
    @State private var text: String = ""

    var body: some View {
        GroupBox(label: HStack {
            Text(actionName(template.action)).bold()
            Text(actionDetail(template.action)).font(.caption).foregroundColor(.secondary)
            Spacer()
            Button("Reset") {
                model.resetTemplate(action: template.action)
                text = model.templates.first { $0.action == template.action }?.template ?? ""
            }
            .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
        }) {
            PlaceholderHighlightingEditor(text: $text)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                .onChange(of: text) { _, v in model.setTemplate(action: template.action, template: v) }
                .padding(.vertical, 6)
        }
        .onAppear { text = template.template }
    }
}

// Colors {selection}/{prompt}/{text}/{context}/{source}/{url} in the app's purple
// wherever they appear while you type — so a template reads the way the app will
// actually build it (plain text vs. the parts that get substituted), not as one
// undifferentiated block. Plain-String in/out for the model; AttributedString only
// as the editor's own display representation.
private let TEMPLATE_PLACEHOLDER_TOKENS = ["{selection}", "{prompt}", "{text}", "{context}", "{source}", "{url}"]

// SwiftUI's AttributedString-backed TextEditor needs macOS 26 — way past this app's
// deployment target (14.0) — so this is a plain NSTextView wrapped directly (same
// approach as FittingTextView/SelectableText elsewhere in this file), recoloring
// placeholder-token ranges after every edit via textStorage, the standard AppKit
// syntax-highlighting pattern. Attribute-only changes (no character count change)
// leave NSTextView's selectedRange alone, so the cursor doesn't jump while typing.
private func applyPlaceholderColors(_ storage: NSTextStorage) {
    let full = storage.string as NSString
    storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: full.length))
    let purple = purpleAccent
    for token in TEMPLATE_PLACEHOLDER_TOKENS {
        var searchRange = NSRange(location: 0, length: full.length)
        while searchRange.location < full.length {
            let found = full.range(of: token, options: [], range: searchRange)
            if found.location == NSNotFound { break }
            storage.addAttribute(.foregroundColor, value: purple, range: found)
            let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            storage.addAttribute(.font, value: boldFont, range: found)
            let nextStart = found.location + found.length
            searchRange = NSRange(location: nextStart, length: full.length - nextStart)
        }
    }
}

final class HighlightingTextView: NSTextView {
    override func didChangeText() {
        super.didChangeText()
        applyPlaceholderColors(textStorage!)
    }
}

struct PlaceholderHighlightingEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = HighlightingTextView()
        tv.isEditable = true
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.delegate = context.coordinator
        tv.string = text
        applyPlaceholderColors(tv.textStorage!)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = tv
        scroll.drawsBackground = false
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView, tv.string != text else { return }
        tv.string = text
        applyPlaceholderColors(tv.textStorage!)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        init(text: Binding<String>) { _text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }
    }
}

// Shared legend — every placeholder available in a CommandTemplate or Context
// rule text, in one place, instead of scattered across each field's help text.
struct TemplateVariablesLegend: View {
    var compact: Bool = false

    var body: some View {
        GroupBox(label: Text("Variables").bold()) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(compact ? TEMPLATE_VARIABLES.filter { $0.token != "{url}" } : TEMPLATE_VARIABLES) { v in
                    HStack(alignment: .top, spacing: 8) {
                        Text(v.token)
                            .font(.system(size: 12, design: .monospaced)).bold()
                            .foregroundColor(appPurple)
                            .frame(width: 90, alignment: .leading)
                        Text(v.detail)
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct EnrichRuleRow: View {
    let rule: EnrichRule
    @ObservedObject var model: TemplatesModel
    @State private var pattern: String = ""
    @State private var text: String = ""
    @State private var match: EnrichMatchType = .host
    @State private var displayName: String = ""
    @State private var pathPrefix: String = ""

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
                VStack(alignment: .leading, spacing: 1) {
                    TextField("pattern (e.g. *.atlassian.net)", text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: pattern) { _, v in
                            var r = rule; r.pattern = v; model.updateRule(r)
                        }
                    // A raw host glob is ugly on its own ("*.atlassian.net") — the
                    // display name underneath it (if set) is the friendly label
                    // this rule actually shows in the [from: …] line.
                    if match == .host && !displayName.isEmpty {
                        Text(displayName).font(.caption2).foregroundColor(.secondary)
                    }
                }
                TextField("Display name (e.g. Gmail)", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 130)
                    .onChange(of: displayName) { _, v in
                        var r = rule; r.displayName = v; model.updateRule(r)
                    }
                Button { model.removeRule(id: rule.id) } label: {
                    Image(systemName: "minus.circle").foregroundColor(.red)
                }.buttonStyle(.plain)
            }
            if match == .host {
                HStack(spacing: 8) {
                    Text("Path prefix").font(.caption2).foregroundColor(.secondary)
                    TextField("optional — e.g. /document/ to mean Docs, not all of docs.google.com", text: $pathPrefix)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onChange(of: pathPrefix) { _, v in
                            var r = rule; r.pathPrefix = v; model.updateRule(r)
                        }
                }
            }
            TextField("Context hint sent to Claude", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onChange(of: text) { _, v in
                    var r = rule; r.text = v; model.updateRule(r)
                }
        }
        .settingsCard()
        .onAppear {
            pattern = rule.pattern; text = rule.text; match = rule.match
            displayName = rule.displayName; pathPrefix = rule.pathPrefix
        }
    }
}

// MARK: - Global Import / Export

enum GlobalBundleSection: String, CaseIterable, Identifiable {
    case shortcuts, templates, vocabulary, handoffSettings, appPreferences
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shortcuts: return "Shortcuts and prompts"
        case .templates: return "Prompt text and context rules"
        case .vocabulary: return "Dictation vocabulary"
        case .handoffSettings: return "Background settings"
        case .appPreferences: return "App preferences"
        }
    }
}

private enum GlobalImportMode: String, CaseIterable, Identifiable {
    case skip, merge, overwrite
    var id: String { rawValue }
    var label: String {
        switch self {
        case .skip: return "Keep current"
        case .merge: return "Merge"
        case .overwrite: return "Overwrite"
        }
    }
}

struct GlobalImportBundle: Identifiable {
    let id = UUID()
    let url: URL
    let object: [String: Any]
    let available: Set<GlobalBundleSection>
}

private func importSectionSummary(_ section: GlobalBundleSection, object: [String: Any]) -> String {
    switch section {
    case .shortcuts:
        let root = object["shortcuts"] as? [String: Any] ?? object
        let hotkeys = (root["hotkeys"] as? [Any])?.count ?? 0
        let actions = (root["customActions"] as? [Any])?.count ?? 0
        let compose = root["builtInComposeSettings"] == nil ? "no compose settings" : "compose settings"
        return "\(hotkeys) shortcuts, \(actions) custom actions, \(compose)"
    case .templates:
        let root = object["templates"] as? [String: Any] ?? object
        let prompts = (root["commandTemplates"] as? [String: Any])?.count ?? 0
        let rules = (root["enrichRules"] as? [Any])?.count ?? 0
        return "\(prompts) prompts, \(rules) context rules"
    case .vocabulary:
        let root = object["vocabulary"] as? [String: Any] ?? object
        let replacements = (root["replacements"] as? [Any])?.count ?? 0
        let terms = (root["vocab"] as? [Any])?.count ?? 0
        let fillers = (root["fillers"] as? [Any])?.count ?? 0
        return "\(replacements) corrections, \(terms) terms, \(fillers) fillers"
    case .handoffSettings:
        let root = object["handoffSettings"] as? [String: Any] ?? [:]
        return "\(root.count) settings"
    case .appPreferences:
        let root = object["appPreferences"] as? [String: Any] ?? [:]
        return "\(root.count) preferences"
    }
}

private func jsonObject(at path: String, fallback: Any) -> Any {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = try? JSONSerialization.jsonObject(with: data) else { return fallback }
    return obj
}

private func writeJSONObject(_ obj: Any, to path: String) {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

@MainActor
private func globalBundle(sections: Set<GlobalBundleSection>) -> [String: Any] {
    var bundle: [String: Any] = ["version": 4, "exportedAt": ISO8601DateFormatter().string(from: Date())]
    if sections.contains(.shortcuts) {
        bundle["shortcuts"] = [
            "hotkeys": jsonObject(at: CFG, fallback: []),
            "customActions": jsonObject(at: CUSTOM_ACTIONS_PATH, fallback: []),
            "builtInComposeSettings": jsonObject(at: BUILTIN_COMPOSE_SETTINGS_PATH, fallback: [
                "autoSubmitDefault": DEFAULT_BUILTIN_COMPOSE_SETTINGS.autoSubmitDefault,
                "autoSubmitOverrides": DEFAULT_BUILTIN_COMPOSE_SETTINGS.autoSubmitOverrides
            ])
        ]
    }
    if sections.contains(.templates) {
        bundle["templates"] = [
            "commandTemplates": jsonObject(at: COMMAND_TEMPLATES_PATH, fallback: [:]),
            "enrichRules": jsonObject(at: ENRICHMENT_RULES_PATH, fallback: [])
        ]
    }
    if sections.contains(.vocabulary) {
        bundle["vocabulary"] = jsonObject(at: VocabularyStore.diskURL().path, fallback: [:])
    }
    if sections.contains(.handoffSettings) {
        bundle["handoffSettings"] = jsonObject(at: HandoffConfig.settingsFile, fallback: [:])
    }
    if sections.contains(.appPreferences) {
        bundle["appPreferences"] = [
            "defaultProvider": UserDefaults.standard.string(forKey: "defaultProvider") ?? "claude",
            "claudeDestination": UserDefaults.standard.string(forKey: "claudeDestination") ?? "recent",
            "codexDestination": UserDefaults.standard.string(forKey: "codexDestination") ?? "code",
            "codexWorkspace": UserDefaults.standard.string(forKey: "codexWorkspace") ?? NSHomeDirectory(),
            "clipRetentionDays": readRetentionDays(),
            "commandRetentionDays": readCommandRetentionDays(),
            "handoffRetentionDays": readHandoffRetentionDays(),
            VoiceSettingsKeys.soundsEnabled: settingsModel.soundsEnabled,
            VoiceSettingsKeys.soundVolume: settingsModel.soundVolume,
            VoiceSettingsKeys.startSound: settingsModel.startSound,
            VoiceSettingsKeys.stopSound: settingsModel.stopSound,
            VoiceSettingsKeys.dictationAssistantProvider: settingsModel.dictationAssistantProvider,
            VoiceSettingsKeys.fillerRemoval: UserDefaults.standard.object(forKey: VoiceSettingsKeys.fillerRemoval) as? Bool ?? VoiceSettingsDefaults.fillerRemoval,
            VoiceSettingsKeys.smartFormatting: UserDefaults.standard.object(forKey: VoiceSettingsKeys.smartFormatting) as? Bool ?? VoiceSettingsDefaults.smartFormatting,
            VoiceSettingsKeys.aiCleanup: UserDefaults.standard.object(forKey: VoiceSettingsKeys.aiCleanup) as? Bool ?? VoiceSettingsDefaults.aiCleanup
        ]
    }
    return bundle
}

@MainActor
private func exportGlobalBundle(sections: Set<GlobalBundleSection>) {
    guard !sections.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: globalBundle(sections: sections), options: [.prettyPrinted]) else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "command-export.json"
    if panel.runModal() == .OK, let url = panel.url {
        try? data.write(to: url)
    }
}

@MainActor
private func chooseGlobalImportBundle() -> GlobalImportBundle? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.message = "Select a Command export file"
    guard panel.runModal() == .OK, let url = panel.url,
          let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var available = Set<GlobalBundleSection>()
    if obj["shortcuts"] != nil || obj["hotkeys"] != nil || obj["customActions"] != nil { available.insert(.shortcuts) }
    if obj["templates"] != nil || obj["commandTemplates"] != nil || obj["enrichRules"] != nil { available.insert(.templates) }
    if obj["vocabulary"] != nil || obj["replacements"] != nil || obj["vocab"] != nil { available.insert(.vocabulary) }
    if obj["handoffSettings"] != nil { available.insert(.handoffSettings) }
    if obj["appPreferences"] != nil { available.insert(.appPreferences) }
    return GlobalImportBundle(url: url, object: obj, available: available)
}

@MainActor
private func applyGlobalImport(_ bundle: GlobalImportBundle, modes: [GlobalBundleSection: GlobalImportMode], model: SettingsModel) {
    let obj = bundle.object
    if let mode = modes[.shortcuts], mode != .skip {
        if let shortcuts = obj["shortcuts"] as? [String: Any] {
            if let hotkeys = shortcuts["hotkeys"] { writeJSONObject(mergedArray(currentPath: CFG, incoming: hotkeys, key: "action", mode: mode), to: CFG) }
            if let actions = shortcuts["customActions"] { writeJSONObject(mergedArray(currentPath: CUSTOM_ACTIONS_PATH, incoming: actions, key: "id", mode: mode), to: CUSTOM_ACTIONS_PATH) }
            if let compose = shortcuts["builtInComposeSettings"] { writeJSONObject(mergedDictionary(currentPath: BUILTIN_COMPOSE_SETTINGS_PATH, incoming: compose, mode: mode), to: BUILTIN_COMPOSE_SETTINGS_PATH) }
        } else {
            if let hotkeys = obj["hotkeys"] { writeJSONObject(mergedArray(currentPath: CFG, incoming: hotkeys, key: "action", mode: mode), to: CFG) }
            if let actions = obj["customActions"] { writeJSONObject(mergedArray(currentPath: CUSTOM_ACTIONS_PATH, incoming: actions, key: "id", mode: mode), to: CUSTOM_ACTIONS_PATH) }
            if let compose = obj["builtInComposeSettings"] { writeJSONObject(mergedDictionary(currentPath: BUILTIN_COMPOSE_SETTINGS_PATH, incoming: compose, mode: mode), to: BUILTIN_COMPOSE_SETTINGS_PATH) }
        }
    }
    if let mode = modes[.templates], mode != .skip {
        if let templates = obj["templates"] as? [String: Any] {
            if let t = templates["commandTemplates"] { writeJSONObject(mergedDictionary(currentPath: COMMAND_TEMPLATES_PATH, incoming: t, mode: mode), to: COMMAND_TEMPLATES_PATH) }
            if let r = templates["enrichRules"] { writeJSONObject(mergedEnrichRules(incoming: r, mode: mode), to: ENRICHMENT_RULES_PATH) }
        } else {
            if let t = obj["commandTemplates"] { writeJSONObject(mergedDictionary(currentPath: COMMAND_TEMPLATES_PATH, incoming: t, mode: mode), to: COMMAND_TEMPLATES_PATH) }
            if let r = obj["enrichRules"] { writeJSONObject(mergedEnrichRules(incoming: r, mode: mode), to: ENRICHMENT_RULES_PATH) }
        }
    }
    if let mode = modes[.vocabulary], mode != .skip {
        let vocabObj: Any? = obj["vocabulary"] ?? (obj["replacements"] != nil || obj["vocab"] != nil ? obj : nil)
        if let vocabObj { writeJSONObject(mergedVocabulary(incoming: vocabObj, mode: mode), to: VocabularyStore.diskURL().path); VocabularyStore.shared.load() }
    }
    if let mode = modes[.handoffSettings], mode != .skip, let h = obj["handoffSettings"] {
        writeJSONObject(mergedDictionary(currentPath: HandoffConfig.settingsFile, incoming: h, mode: mode), to: HandoffConfig.settingsFile)
    }
    if let mode = modes[.appPreferences], mode != .skip, let prefs = obj["appPreferences"] as? [String: Any] {
        if let v = prefs["claudeDestination"] as? String {
            UserDefaults.standard.set(v, forKey: "claudeDestination")
            model.claudeDestination = v
        }
        if let v = prefs["codexDestination"] as? String, v == "chat" || v == "code" {
            UserDefaults.standard.set(v, forKey: "codexDestination")
            model.codexDestination = v
        }
        if let v = prefs["defaultProvider"] as? String, AIProvider(rawValue: v) != nil {
            UserDefaults.standard.set(v, forKey: "defaultProvider")
            model.defaultProvider = v
        }
        if let v = prefs["codexWorkspace"] as? String {
            UserDefaults.standard.set(v, forKey: "codexWorkspace")
            model.codexWorkspace = v
        }
        if let v = prefs["clipRetentionDays"] as? Int { writeRetentionDays(v) }
        if let v = prefs["commandRetentionDays"] as? Int { writeCommandRetentionDays(v) }
        if let v = prefs["handoffRetentionDays"] as? Int { writeHandoffRetentionDays(v) }
        if let v = prefs[VoiceSettingsKeys.soundsEnabled] as? Bool { UserDefaults.standard.set(v, forKey: VoiceSettingsKeys.soundsEnabled); model.soundsEnabled = v }
        if let v = prefs[VoiceSettingsKeys.soundVolume] as? Double { UserDefaults.standard.set(v, forKey: VoiceSettingsKeys.soundVolume); model.soundVolume = v }
        if let v = prefs[VoiceSettingsKeys.startSound] as? String { UserDefaults.standard.set(v, forKey: VoiceSettingsKeys.startSound); model.startSound = v }
        if let v = prefs[VoiceSettingsKeys.stopSound] as? String { UserDefaults.standard.set(v, forKey: VoiceSettingsKeys.stopSound); model.stopSound = v }
        if let v = prefs[VoiceSettingsKeys.dictationAssistantProvider] as? String, AIProviderChoice(rawValue: v) != nil {
            UserDefaults.standard.set(v, forKey: VoiceSettingsKeys.dictationAssistantProvider)
            model.dictationAssistantProvider = v
        }
        if let v = prefs[VoiceSettingsKeys.fillerRemoval] as? Bool { UserDefaults.standard.set(v, forKey: VoiceSettingsKeys.fillerRemoval) }
        if let v = prefs[VoiceSettingsKeys.smartFormatting] as? Bool { UserDefaults.standard.set(v, forKey: VoiceSettingsKeys.smartFormatting) }
        if let v = prefs[VoiceSettingsKeys.aiCleanup] as? Bool { UserDefaults.standard.set(v, forKey: VoiceSettingsKeys.aiCleanup) }
    }
    reregisterHotkeys()
    model.refresh()
}

private func mergedArray(currentPath: String, incoming: Any, key: String, mode: GlobalImportMode) -> Any {
    guard mode == .merge,
          let current = jsonObject(at: currentPath, fallback: []) as? [[String: Any]],
          let inc = incoming as? [[String: Any]] else { return incoming }
    return mergeDictionaryArrays(current: current, incoming: inc, key: key)
}

private func mergedDictionary(currentPath: String, incoming: Any, mode: GlobalImportMode) -> Any {
    guard mode == .merge,
          let current = jsonObject(at: currentPath, fallback: [:]) as? [String: Any],
          let inc = incoming as? [String: Any] else { return incoming }
    return mergeDictionaryValues(current: current, incoming: inc)
}

private func mergedEnrichRules(incoming: Any, mode: GlobalImportMode) -> Any {
    guard mode == .merge,
          let current = jsonObject(at: ENRICHMENT_RULES_PATH, fallback: []) as? [[String: Any]],
          let inc = incoming as? [[String: Any]] else { return incoming }
    return mergeEnrichRuleDictionaries(current: current, incoming: inc)
}

@MainActor
private func mergedVocabulary(incoming: Any, mode: GlobalImportMode) -> Any {
    guard mode == .merge,
          let cur = jsonObject(at: VocabularyStore.diskURL().path, fallback: [:]) as? [String: Any],
          let inc = incoming as? [String: Any] else { return incoming }
    return mergeVocabularyDictionaries(current: cur, incoming: inc)
}

struct GlobalExportSheet: View {
    @Binding var isPresented: Bool
    @State private var selected = Set(GlobalBundleSection.allCases)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.headline)
            Text("Choose what to include in one Command export file.")
                .font(.caption).foregroundColor(.secondary)
            ForEach(GlobalBundleSection.allCases) { section in
                Toggle(section.label, isOn: Binding(
                    get: { selected.contains(section) },
                    set: { on in
                        if on { selected.insert(section) } else { selected.remove(section) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Export") {
                    exportGlobalBundle(sections: selected)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct GlobalImportSheet: View {
    @Binding var isPresented: Bool
    let bundle: GlobalImportBundle
    @ObservedObject var model: SettingsModel
    @State private var modes: [GlobalBundleSection: GlobalImportMode] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import").font(.headline)
            Text(bundle.url.lastPathComponent).font(.caption).foregroundColor(.secondary)
            Text("Choose what to keep, merge, or overwrite before anything changes.")
                .font(.caption).foregroundColor(.secondary)
            if bundle.available.isEmpty {
                Text("No importable sections found.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(GlobalBundleSection.allCases) { section in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.label)
                            Text(bundle.available.contains(section) ? importSectionSummary(section, object: bundle.object) : "Not found in file")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { modes[section] ?? .skip },
                            set: { modes[section] = $0 }
                        )) {
                            ForEach(GlobalImportMode.allCases) { m in
                                Text(m.label).tag(m)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        .disabled(!bundle.available.contains(section))
                    }
                    .opacity(bundle.available.contains(section) ? 1 : 0.45)
                }
            }
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Import Selected") {
                    applyGlobalImport(bundle, modes: modes, model: model)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!modes.values.contains { $0 != .skip })
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            var initial: [GlobalBundleSection: GlobalImportMode] = [:]
            for s in GlobalBundleSection.allCases {
                initial[s] = bundle.available.contains(s) ? .merge : .skip
            }
            modes = initial
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
                    ? appPurple.opacity(0.12)
                    : Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isRecording ? appPurple : Color.gray.opacity(0.35), lineWidth: 1)
                )
            Text(isRecording ? "Press keys…" : (binding.keycode == 0 ? "—" : binding.human))
                .font(.system(.body, design: .rounded).bold())
                .foregroundColor(isRecording ? appPurple : (binding.keycode == 0 ? .secondary : .primary))
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

                Text("Red means a checked requirement is not met for that workflow — not a crash. Grant needed permissions in Set Up, then Re-scan here.")
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
                       "Function-key shortcuts don't fire? Enable standard function keys in macOS Keyboard settings, or rebind prompt and dictation shortcuts.")
                tipRow("Browser URL not captured",
                       "First Go from each browser (Chrome, Safari, Arc…) prompts for Automation — approve it once per browser.")
                tipRow("Logs",
                       "~/Library/Logs/claude-command.log (shortcut actions) · ~/.claude/logs/command-agent.err (app dispatch) · ~/.claude/logs/clipwatch.err (Clipboard History)")
            }
            .padding(24)
        }
        .onAppear { reload() }
    }

    private func reload() {
        let clipboardHistoryEnabled = UserDefaults.standard.bool(forKey: "cliphistoryEnabled")
        let clipboardHistoryRunning = runShell("/usr/bin/pgrep", ["-f", "clipwatch.py"]).code == 0
        items = [
            DiagItem(
                title: "Accessibility",
                ok: axTrusted(),
                fix: "Open System Settings > Privacy & Security > Accessibility. Find Command and flip it ON. Then Re-scan.",
                action: { requestAccessibility(); openPrivacyPane("Privacy_Accessibility") },
                actionLabel: "Open Settings"
            ),
            DiagItem(
                title: "Screen Recording",
                ok: screenRecordingOK(),
                fix: "Open System Settings > Privacy & Security > Screen Recording. Toggle Command ON. Then Re-scan.",
                action: { openPrivacyPane("Privacy_ScreenCapture") },
                actionLabel: "Open Settings"
            ),
            DiagItem(
                title: "Background service",
                ok: fileExists(home(".claude/state/command-agent.sock")),
                fix: "Background service is not ready. Restart Command. If it still fails, reinstall from the Install Guide; source checkouts can run ./install-agent.sh.",
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
                title: "Quick Actions optional",
                ok: true,
                fix: fileExists(home("Library/Services/Claude - Add.workflow"))
                    ? "Optional right-click Services are installed."
                    : "Optional right-click Services are not installed. Global shortcuts do not need them; source installs can run ./install-quick-action.sh.",
                action: nil,
                actionLabel: ""
            ),
            DiagItem(
                title: "Clipboard History",
                ok: !clipboardHistoryEnabled || clipboardHistoryRunning,
                fix: clipboardHistoryEnabled
                    ? "Clipboard History is not running. Restart Command. If it still fails, reinstall from the Install Guide; source checkouts can run ./install-agent.sh."
                    : "Clipboard History is off. Enable it in Clipboard History settings if you want the picker.",
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
    @ObservedObject private var model: SettingsModel = settingsModel
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
                                reregisterHotkeys()
                            }
                    }
                    .padding(10)
                }

                if enabled {
                    if let binding = model.bindings.first(where: { $0.action == "cliphistory" }) {
                        GroupBox(label: Text("Shortcut").bold()) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Open Clipboard History")
                                    Text("Shows the searchable picker from anywhere.")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                KeyBindingField(action: binding.action, binding: binding, model: model)
                            }
                            .padding(8)
                        }
                    }

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

// ---- Command History ---------------------------------------------------------
// Handoffs live here now as the background-command slice. Foreground command
// logging uses the same retention model and can grow into the same list.

struct HandoffsView: View {
    @State private var submissions: [HandoffSubmission] = loadHandoffSubmissions(limit: nil)
    @State private var foreground: [ForegroundCommandRecord] = loadForegroundCommandHistory(limit: nil)
    @State private var query = ""
    @State private var statusFilter: String = "all"   // all | running | succeeded | failed
    @State private var pendingDelete: HandoffSubmission? = nil
    @State private var retentionText = String(readCommandRetentionDays())

    private var filteredHandoffs: [HandoffSubmission] {
        var out = submissions
        if statusFilter != "all" { out = out.filter { $0.status == statusFilter } }
        guard !query.isEmpty else { return out }
        let q = query.lowercased()
        return out.filter {
            ($0.skill ?? "").lowercased().contains(q) ||
            $0.provider.rawValue.contains(q) ||
            ($0.workspace ?? "").lowercased().contains(q) ||
            $0.source.lowercased().contains(q) ||
            ($0.prompt ?? "").lowercased().contains(q)
        }
    }

    private var filteredForeground: [ForegroundCommandRecord] {
        var out = foreground
        if statusFilter != "all" { out = out.filter { $0.status == statusFilter } }
        guard !query.isEmpty else { return out }
        let q = query.lowercased()
        return out.filter {
            $0.action.lowercased().contains(q) ||
            $0.source.lowercased().contains(q) ||
            $0.destination.lowercased().contains(q) ||
            $0.provider.rawValue.contains(q) ||
            ($0.workspace ?? "").lowercased().contains(q) ||
            ($0.prompt ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Command History").font(.title2).bold()
                    Spacer()
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                        .help("Reload from disk")
                }
                Text("Commands sent through Command. Background runs and foreground shortcuts share the same seven-day retention foundation.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Picker("", selection: $statusFilter) {
                        Text("All").tag("all")
                        Text("Running").tag("running")
                        Text("Succeeded").tag("succeeded")
                        Text("Failed").tag("failed")
                    }
                    .pickerStyle(.segmented).frame(width: 320)
                    TextField("Search action, source, destination, skill, or prompt", text: $query)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    Text("Auto-delete command history after")
                    Stepper(value: Binding(
                        get: { Int(retentionText) ?? readCommandRetentionDays() },
                        set: {
                            retentionText = String($0)
                            writeCommandRetentionDays($0)
                            writeHandoffRetentionDays($0)
                            refresh()
                        }
                    ), in: 1...365) {
                        Text("\(retentionText) days").frame(minWidth: 70, alignment: .leading)
                    }
                    Spacer()
                }
                .font(.caption)

                if filteredForeground.isEmpty && filteredHandoffs.isEmpty {
                    Text(submissions.isEmpty && foreground.isEmpty ? "No commands yet." : "No matches.")
                        .font(.caption).foregroundColor(.secondary).padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        if !filteredForeground.isEmpty {
                            Text("Foreground").font(.headline)
                            VStack(spacing: 0) {
                                ForEach(filteredForeground) { r in
                                    ForegroundCommandRow(record: r)
                                    Divider()
                                }
                            }
                        }
                        if !filteredHandoffs.isEmpty {
                            Text("Background").font(.headline)
                            VStack(spacing: 0) {
                                ForEach(filteredHandoffs) { s in
                                    HandoffSubmissionRow(
                                        submission: s,
                                        onRetry: { retryHandoffSubmission(s) },
                                        onMarkFailed: { markHandoffSubmissionFailed(s); refresh() },
                                        onDelete: { pendingDelete = s }
                                    )
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear { refresh() }
        .alert("Delete this background run?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { s in
            Button("Delete", role: .destructive) {
                deleteHandoffSubmission(s)
                refresh()
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Removes the run record, its captured content, and its log. This can't be undone.")
        }
    }

    private func refresh() {
        pruneForegroundCommandHistory()
        pruneHandoffSubmissions()
        submissions = loadHandoffSubmissions(limit: nil)
        foreground = loadForegroundCommandHistory(limit: nil)
        retentionText = String(readCommandRetentionDays())
    }
}

struct ForegroundCommandRow: View {
    let record: ForegroundCommandRecord
    @State private var expanded = false

    private var statusColor: Color {
        record.status == "succeeded" ? .green : (record.status == "failed" ? .red : .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(record.status == "succeeded" ? "✓" : "✗")
                    .foregroundColor(statusColor).bold().frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(actionName(record.action)).bold()
                        Text(record.provider.label)
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                        Text(ClaudeDestination.displayLabel(rawValue: record.destination, provider: record.provider))
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                        Text("from \(record.source)").font(.caption).foregroundColor(.secondary)
                    }
                    Text(record.age + (record.error.map { " — \($0)" } ?? ""))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                if record.prompt != nil {
                    Button(expanded ? "Hide" : "Details") { expanded.toggle() }
                        .buttonStyle(.plain).font(.caption)
                }
            }
            if expanded, let prompt = record.prompt {
                Text(prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07))
                    .cornerRadius(6)
            }
        }
        .padding(.vertical, 8)
    }
}

struct HandoffSubmissionRow: View {
    let submission: HandoffSubmission
    let onRetry: () -> Void
    let onMarkFailed: () -> Void
    let onDelete: () -> Void
    @State private var expanded = false
    @State private var retried = false

    private var statusColor: Color {
        switch submission.status {
        case "succeeded": return .green
        case "failed": return .red
        default: return submission.isStalled ? .orange : .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(submission.statusGlyph).foregroundColor(statusColor).bold().frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(submission.skill?.isEmpty == false ? submission.provider.skillInvocation(submission.skill!) :
                             (submission.provider == .claude ? "claude -p" : "codex exec")).bold()
                        Text(submission.provider.label)
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                        Text(submission.kind == "image" ? "image" : "text")
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                        Text("from \(submission.source)").font(.caption).foregroundColor(.secondary)
                    }
                    Text(submission.age + (submission.isStalled ? " — stalled?" : "") + (submission.error.map { " — \($0)" } ?? ""))
                        .font(.caption2).foregroundColor(.secondary)
                    if let result = submission.result, !result.isEmpty {
                        Text(result)
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(appPurple)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(appPurple.opacity(0.12)).cornerRadius(4)
                    }
                }
                Spacer()
                Button(expanded ? "Hide" : "Details") { expanded.toggle() }
                    .buttonStyle(.plain).font(.caption)
                if let log = submission.logFile, FileManager.default.fileExists(atPath: log) {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: log)) } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }.buttonStyle(.plain).help("Open log")
                }
                if submission.status == "failed" {
                    Button {
                        onRetry()
                        retried = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { retried = false }
                    } label: {
                        Image(systemName: retried ? "checkmark" : "arrow.clockwise")
                    }.buttonStyle(.plain).help("Retry").disabled(retried)
                }
                if submission.isStalled {
                    Button { onMarkFailed() } label: {
                        Image(systemName: "exclamationmark.octagon").foregroundColor(.orange)
                    }.buttonStyle(.plain).help("Stuck at \"running\" — mark as failed so it can be retried")
                }
                Button { onDelete() } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                }.buttonStyle(.plain)
            }
            if expanded, let prompt = submission.prompt {
                Text(prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07))
                    .cornerRadius(6)
            }
        }
        .padding(.vertical, 8)
    }
}

// ---- channel picker (segmented; Stable greyed until a stable release exists) --
struct ChannelPicker: View {
    @Binding var channel: UpdateChannel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(UpdateChannel.allCases.enumerated()), id: \.element) { idx, c in
                let disabled = (c == .stable && !PROD_AVAILABLE)
                let selected = channel == c
                Button {
                    channel = c
                    setUpdateChannel(c)
                } label: {
                    Text(c.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .frame(width: 62)
                        .padding(.vertical, 4)
                        .background(selected ? appPurpleSolid : Color.clear)
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

// Tail of each log, not the whole file — enough to actually see what just
// happened without dumping megabytes of history into the clipboard.
@MainActor
func copyCommandDiagnosticInfo(
    model: SettingsModel = settingsModel,
    channel: UpdateChannel = currentChannel(),
    available: UpdateInfo? = nil,
    updateStatus: String = "",
    launchAtLogin: Bool = launchAtLoginEnabled(),
    showIcon: Bool = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon"),
    showDock: Bool = showDockIcon()
) {
    func oneLinePreview(_ text: String, limit: Int = 220) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.count > limit ? String(compact.prefix(limit)) + "…" : compact
    }
    func stateLabel(_ state: CheckState) -> String {
        switch state {
        case .ok: return "ok"
        case .missing: return "missing"
        case .unknown: return "unknown"
        }
    }
    func modelStatusLabel(_ status: Recorder.ModelStatus) -> String {
        switch status {
        case .notDownloaded: return "not downloaded"
        case .downloading(let progress): return "downloading \(Int(progress * 100))%"
        case .ready: return "ready"
        case .error(let message): return "error: \(oneLinePreview(message, limit: 120))"
        }
    }

    let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    let gitBranch = (Bundle.main.infoDictionary?["ClaudeCommandGitBranch"] as? String) ?? ""
    let dateFormatter = ISO8601DateFormatter()
    let os = ProcessInfo.processInfo.operatingSystemVersion
    var out = "Command \(version)\(gitBranch.isEmpty ? "" : " (\(gitBranch))")\n"
    out += "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n"
    out += "App path: \(Bundle.main.bundlePath)\n"
    out += "Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")\n"
    out += "Minimum macOS: \((Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String) ?? "unknown")\n"
    out += "Update channel: \(channel.label)\n"
    if let available {
        out += "Update check: v\(available.latestVersion) available\n"
        out += "Update download asset: \(available.downloadURL == nil ? "missing" : "present")\n"
    } else if updateStatus.isEmpty {
        out += "Update check: not checked this session\n"
    } else {
        out += "Update check: \(oneLinePreview(updateStatus, limit: 160))\n"
    }
    out += "Default assistant: \(model.defaultProvider)\n"
    out += "Default Claude destination: \(model.claudeDestination)\n"
    out += "Default ChatGPT destination: \(model.codexDestination == "chat" ? "Chat" : "Codex")\n"
    out += "Default Codex workspace: \(model.codexWorkspace)\n"
    let background = HandoffConfig.load()
    out += "Claude CLI: \(background.claudeCommand), cwd=\(background.claudeCwd.isEmpty ? "home" : background.claudeCwd), extraArgs=\(background.claudeExtraArgs.count)\n"
    out += "Codex CLI: \(background.codexCommand), cwd=\(background.codexCwd.isEmpty ? "home" : background.codexCwd), extraArgs=\(background.codexExtraArgs.count)\n"
    out += "Launch at login: \(launchAtLogin ? "on" : "off")\n"
    out += "Menu bar icon: \(showIcon ? "shown" : "hidden")\n"
    out += "Dock icon: \(showDock ? "shown" : "hidden")\n\n"

    out += "--- Shortcut bindings ---\n"
    for binding in loadBindings() {
        out += "\(binding.name): \(binding.enabled ? "enabled" : "disabled") \(binding.human)\n"
    }
    let customActions = loadCustomActions()
    if customActions.isEmpty {
        out += "Custom actions: (none)\n"
    } else {
        out += "Custom actions:\n"
        for action in customActions {
            let resolvedProvider = action.provider.resolve(default: AIProvider(rawValue: model.defaultProvider) ?? .claude)
            out += "\(action.name): \(action.enabled ? "enabled" : "disabled") provider=\(action.provider.label) delivery=\(action.delivery.label) destination=\(action.destination.label(for: resolvedProvider)) autoSubmit=\(action.isAutoSubmit ? "on" : "off")\n"
            for trigger in action.triggers {
                out += "  - \(trigger.kind.label): \(trigger.enabled ? "enabled" : "disabled") \(trigger.human)"
                if let delivery = trigger.deliveryOverride { out += " delivery=\(delivery.label)" }
                if let destination = trigger.destinationOverride {
                    let triggerProvider = action.effectiveProvider(for: trigger, default: AIProvider(rawValue: model.defaultProvider) ?? .claude)
                    out += " destination=\(destination.label(for: triggerProvider))"
                }
                if let provider = trigger.providerOverride { out += " provider=\(provider.label)" }
                if let autoSubmit = trigger.isAutoSubmitOverride { out += " autoSubmit=\(autoSubmit ? "on" : "off")" }
                out += "\n"
            }
        }
    }
    out += "\n"

    out += "--- Set Up status ---\n"
    for check in permissionChecks() {
        out += "\(check.title): \(stateLabel(check.state))\n"
    }
    for check in componentChecks() {
        out += "\(check.title): \(stateLabel(check.state))\n"
    }
    out += "Dictation model: \(modelStatusLabel(recorder.modelStatus))\n\n"

    let logs = [
        "\(HOME)/Library/Logs/claude-command.log",
        "\(HOME)/.claude/logs/command-agent.err",
        "\(HOME)/.claude/logs/clipwatch.err",
        "\(HOME)/.claude/logs/attribution.log",
    ]
    for path in logs {
        out += "--- \(path) ---\n"
        if let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) {
            out += text.split(separator: "\n").suffix(40).joined(separator: "\n")
        } else {
            out += "(not found)"
        }
        out += "\n\n"
    }

    out += "--- Recent command history (last 5 each, summaries only) ---\n"
    let foregroundRecords = loadForegroundCommandHistory(limit: 5)
    if foregroundRecords.isEmpty {
        out += "Foreground: (none)\n"
    } else {
        out += "Foreground:\n"
        for record in foregroundRecords {
            out += "\(dateFormatter.string(from: record.createdAt)) provider=\(record.provider.rawValue) status=\(record.status) action=\(actionName(record.action)) destination=\(record.destination) source=\(record.source)"
            if let error = record.error, !error.isEmpty {
                out += " error=\(oneLinePreview(error, limit: 120))"
            }
            out += "\n"
        }
    }
    let backgroundRecords = loadHandoffSubmissions(limit: 5)
    if backgroundRecords.isEmpty {
        out += "Background: (none)\n"
    } else {
        out += "Background:\n"
        for record in backgroundRecords {
            out += "\(dateFormatter.string(from: record.createdAt)) provider=\(record.provider.rawValue) status=\(record.status) kind=\(record.kind) source=\(record.source)"
            if let skill = record.skill, !skill.isEmpty { out += " skill=\(record.provider.skillInvocation(skill))" }
            if let result = record.result, !result.isEmpty { out += " result=\(oneLinePreview(result, limit: 120))" }
            if let error = record.error, !error.isEmpty { out += " error=\(oneLinePreview(error, limit: 120))" }
            if let logFile = record.logFile, !logFile.isEmpty { out += " log=\(logFile)" }
            out += "\n"
        }
    }
    out += "\n"

    out += "--- Recent dictation entries (last 3, truncated) ---\n"
    let dictationRecords = Array(HistoryStore.shared.records.prefix(3))
    if dictationRecords.isEmpty {
        out += "(none)\n"
    } else {
        for record in dictationRecords {
            out += "\(dateFormatter.string(from: record.timestamp)) mode=\(record.mode)\n"
            out += "raw: \(oneLinePreview(record.raw))\n"
            out += "processed: \(oneLinePreview(record.processed))\n"
        }
    }
    out += "\n"

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(out, forType: .string)
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
    @State private var diagCopied = false
    @State private var showingExport = false
    @State private var importBundle: GlobalImportBundle? = nil

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    // Set by build-agent.sh from `git rev-parse` at build time — empty for a
    // release zip (no .git to read), so this only ever shows on local dev builds.
    private var gitBranch: String {
        (Bundle.main.infoDictionary?["ClaudeCommandGitBranch"] as? String) ?? ""
    }

    private var channelHint: String {
        switch channel {
        case .alpha: return "Alpha — earliest builds, least tested."
        case .beta:  return "Beta — pre-release builds for testing."
        case .stable: return "Stable is visible but unavailable until the first stable release exists."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Command").font(.title2).bold()
                Text("Prompt-centered macOS shortcuts for selected text, screenshots, typed popups, voice, background runs, clipboard history, and command history.")
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                // Version + updates
                HStack(spacing: 10) {
                    Text("Version \(version)").font(.caption).foregroundColor(.secondary)
                    Button(checking ? "Checking…" : "Check for Updates") { runCheck() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(checking || installing)
                }
                if !gitBranch.isEmpty {
                    Text("Local dev build — \(gitBranch)")
                        .font(.caption2).foregroundColor(.secondary)
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
                        Image(systemName: "arrow.down.circle.fill").foregroundColor(appPurple)
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Import / Export").font(.headline)
                    Text("Move shortcuts, prompt settings, context rules, vocabulary, background settings, and app preferences in one file.")
                        .font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 10) {
                        Button {
                            showingExport = true
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            importBundle = chooseGlobalImportBundle()
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Help & Documentation").font(.headline)
                    Button {
                        if let u = URL(string: GITHUB_REPO_URL) { NSWorkspace.shared.open(u) }
                    } label: {
                        Label("View on GitHub", systemImage: "link")
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                    Button {
                        openHelpDoc(named: "index")
                    } label: {
                        Label("Documentation", systemImage: "book")
                    }
                    Button {
                        openHelpDoc(named: "guide")
                    } label: {
                        Label("User Guide", systemImage: "book.pages")
                    }
                    Button {
                        openHelpDoc(named: "install")
                    } label: {
                        Label("Install Guide", systemImage: "arrow.down.app")
                    }
                    Button {
                        openHelpDoc(named: "uninstall")
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                    Button {
                        openHelpDoc(named: "settings")
                    } label: {
                        Label("Settings Reference", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        openHelpDoc(named: "quick-reference")
                    } label: {
                        Label("Quick Reference", systemImage: "bolt")
                    }
                    Button {
                        openHelpDoc(named: "troubleshooting")
                    } label: {
                        Label("Troubleshooting", systemImage: "wrench.and.screwdriver")
                    }
                    Button {
                        openHelpDoc(named: "permissions")
                    } label: {
                        Label("Permissions", systemImage: "lock.shield")
                    }
                    Button {
                        openHelpDoc(named: "support")
                    } label: {
                        Label("Support", systemImage: "questionmark.circle")
                    }
                    Button {
                        openHelpDoc(named: "security")
                    } label: {
                        Label("Security Policy", systemImage: "lock.shield")
                    }
                    Button {
                        openHelpDoc(named: "examples")
                    } label: {
                        Label("Examples", systemImage: "sparkles")
                    }
                    Button {
                        openHelpDoc(named: "faq")
                    } label: {
                        Label("FAQ", systemImage: "questionmark.bubble")
                    }
                    Button {
                        openHelpDoc(named: "updates")
                    } label: {
                        Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        openHelpDoc(named: "privacy")
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    Button {
                        openHelpDoc(named: "changelog")
                    } label: {
                        Label("Changelog", systemImage: "clock")
                    }
                    Button {
                        openHelpDoc(named: "limitations")
                    } label: {
                        Label("Alpha Limitations", systemImage: "exclamationmark.triangle")
                    }
                    Button {
                        openHelpDoc(named: "icon-treatments")
                    } label: {
                        Label("Icon Treatments", systemImage: "waveform.path.ecg")
                    }
                    Button {
                        openHelpDoc(named: "background")
                    } label: {
                        Label("Background Architecture", systemImage: "terminal")
                    }
                    Button {
                        openHelpDoc(named: "release")
                    } label: {
                        Label("Release Checklist", systemImage: "checklist")
                    }
                }
                Text(GITHUB_REPO_URL).font(.caption).foregroundColor(.secondary).textSelection(.enabled)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Support & Reporting").font(.headline)
                    HStack(spacing: 10) {
                        Button("Copy Diagnostic Info") {
                            copyCommandDiagnosticInfo(
                                model: model,
                                channel: channel,
                                available: available,
                                updateStatus: updateStatus,
                                launchAtLogin: launchAtLogin,
                                showIcon: showIcon,
                                showDock: showDock
                            )
                            diagCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { diagCopied = false }
                        }
                        .buttonStyle(.bordered)
                        Button {
                            if let u = reportBugURL() { NSWorkspace.shared.open(u) }
                        } label: {
                            Label("Report a Bug", systemImage: "ladybug")
                        }
                        Button {
                            if let u = requestFeatureURL() { NSWorkspace.shared.open(u) }
                        } label: {
                            Label("Request Feature", systemImage: "sparkles")
                        }
                        Button {
                            if let u = securityAdvisoryURL() { NSWorkspace.shared.open(u) }
                        } label: {
                            Label("Private Security Report", systemImage: "lock.shield")
                        }
                        if diagCopied { Text("Copied").font(.caption).foregroundColor(.secondary) }
                    }
                    Text("Copy Diagnostic Info first, review it for sensitive content, then use Report a Bug for problems, Request Feature for non-bug workflow, trigger, destination, docs, or release improvements, or Private Security Report for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics.")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingExport) {
            GlobalExportSheet(isPresented: $showingExport)
        }
        .sheet(item: $importBundle) { bundle in
            GlobalImportSheet(isPresented: Binding(
                get: { importBundle != nil },
                set: { if !$0 { importBundle = nil } }
            ), bundle: bundle, model: model)
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

    // Tail of each log, not the whole file — enough to actually see what just
    // happened without dumping megabytes of history into the clipboard.
    private func copyDiagnosticInfo() {
        func oneLinePreview(_ text: String, limit: Int = 220) -> String {
            let compact = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return compact.count > limit ? String(compact.prefix(limit)) + "…" : compact
        }
        func stateLabel(_ state: CheckState) -> String {
            switch state {
            case .ok: return "ok"
            case .missing: return "missing"
            case .unknown: return "unknown"
            }
        }
        func modelStatusLabel(_ status: Recorder.ModelStatus) -> String {
            switch status {
            case .notDownloaded: return "not downloaded"
            case .downloading(let progress): return "downloading \(Int(progress * 100))%"
            case .ready: return "ready"
            case .error(let message): return "error: \(oneLinePreview(message, limit: 120))"
            }
        }

        let dateFormatter = ISO8601DateFormatter()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var out = "Command \(version)\(gitBranch.isEmpty ? "" : " (\(gitBranch))")\n"
        out += "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n"
        out += "App path: \(Bundle.main.bundlePath)\n"
        out += "Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")\n"
        out += "Minimum macOS: \((Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String) ?? "unknown")\n"
        out += "Update channel: \(channel.label)\n"
        if let available {
            out += "Update check: v\(available.latestVersion) available\n"
            out += "Update download asset: \(available.downloadURL == nil ? "missing" : "present")\n"
        } else if updateStatus.isEmpty {
            out += "Update check: not checked this session\n"
        } else {
            out += "Update check: \(oneLinePreview(updateStatus, limit: 160))\n"
        }
        out += "Default assistant: \(model.defaultProvider)\n"
        out += "Default Claude destination: \(model.claudeDestination)\n"
        out += "Default ChatGPT destination: \(model.codexDestination == "chat" ? "Chat" : "Codex")\n"
        out += "Default Codex workspace: \(model.codexWorkspace)\n"
        let background = HandoffConfig.load()
        out += "Claude CLI: \(background.claudeCommand), cwd=\(background.claudeCwd.isEmpty ? "home" : background.claudeCwd), extraArgs=\(background.claudeExtraArgs.count)\n"
        out += "Codex CLI: \(background.codexCommand), cwd=\(background.codexCwd.isEmpty ? "home" : background.codexCwd), extraArgs=\(background.codexExtraArgs.count)\n"
        out += "Launch at login: \(launchAtLogin ? "on" : "off")\n"
        out += "Menu bar icon: \(showIcon ? "shown" : "hidden")\n"
        out += "Dock icon: \(showDock ? "shown" : "hidden")\n\n"

        out += "--- Shortcut bindings ---\n"
        for binding in loadBindings() {
            out += "\(binding.name): \(binding.enabled ? "enabled" : "disabled") \(binding.human)\n"
        }
        let customActions = loadCustomActions()
        if customActions.isEmpty {
            out += "Custom actions: (none)\n"
        } else {
            out += "Custom actions:\n"
            for action in customActions {
                let resolvedProvider = action.provider.resolve(default: AIProvider(rawValue: model.defaultProvider) ?? .claude)
                out += "\(action.name): \(action.enabled ? "enabled" : "disabled") provider=\(action.provider.label) delivery=\(action.delivery.label) destination=\(action.destination.label(for: resolvedProvider)) autoSubmit=\(action.isAutoSubmit ? "on" : "off")\n"
                for trigger in action.triggers {
                    out += "  - \(trigger.kind.label): \(trigger.enabled ? "enabled" : "disabled") \(trigger.human)"
                    if let delivery = trigger.deliveryOverride { out += " delivery=\(delivery.label)" }
                    if let destination = trigger.destinationOverride {
                        let triggerProvider = action.effectiveProvider(for: trigger, default: AIProvider(rawValue: model.defaultProvider) ?? .claude)
                        out += " destination=\(destination.label(for: triggerProvider))"
                    }
                    if let provider = trigger.providerOverride { out += " provider=\(provider.label)" }
                    if let autoSubmit = trigger.isAutoSubmitOverride { out += " autoSubmit=\(autoSubmit ? "on" : "off")" }
                    out += "\n"
                }
            }
        }
        out += "\n"

        out += "--- Set Up status ---\n"
        for check in permissionChecks() {
            out += "\(check.title): \(stateLabel(check.state))\n"
        }
        for check in componentChecks() {
            out += "\(check.title): \(stateLabel(check.state))\n"
        }
        out += "Dictation model: \(modelStatusLabel(recorder.modelStatus))\n\n"

        let logs = [
            "\(HOME)/Library/Logs/claude-command.log",
            "\(HOME)/.claude/logs/command-agent.err",
            "\(HOME)/.claude/logs/clipwatch.err",
            "\(HOME)/.claude/logs/attribution.log",
        ]
        for path in logs {
            out += "--- \(path) ---\n"
            if let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) {
                out += text.split(separator: "\n").suffix(40).joined(separator: "\n")
            } else {
                out += "(not found)"
            }
            out += "\n\n"
        }

        out += "--- Recent command history (last 5 each, summaries only) ---\n"
        let foregroundRecords = loadForegroundCommandHistory(limit: 5)
        if foregroundRecords.isEmpty {
            out += "Foreground: (none)\n"
        } else {
            out += "Foreground:\n"
            for record in foregroundRecords {
                out += "\(dateFormatter.string(from: record.createdAt)) provider=\(record.provider.rawValue) status=\(record.status) action=\(actionName(record.action)) destination=\(record.destination) source=\(record.source)"
                if let error = record.error, !error.isEmpty {
                    out += " error=\(oneLinePreview(error, limit: 120))"
                }
                out += "\n"
            }
        }
        let backgroundRecords = loadHandoffSubmissions(limit: 5)
        if backgroundRecords.isEmpty {
            out += "Background: (none)\n"
        } else {
            out += "Background:\n"
            for record in backgroundRecords {
                out += "\(dateFormatter.string(from: record.createdAt)) provider=\(record.provider.rawValue) status=\(record.status) kind=\(record.kind) source=\(record.source)"
                if let skill = record.skill, !skill.isEmpty { out += " skill=\(record.provider.skillInvocation(skill))" }
                if let result = record.result, !result.isEmpty { out += " result=\(oneLinePreview(result, limit: 120))" }
                if let error = record.error, !error.isEmpty { out += " error=\(oneLinePreview(error, limit: 120))" }
                if let logFile = record.logFile, !logFile.isEmpty { out += " log=\(logFile)" }
                out += "\n"
            }
        }
        out += "\n"

        out += "--- Recent dictation entries (last 3, truncated) ---\n"
        let dictationRecords = Array(HistoryStore.shared.records.prefix(3))
        if dictationRecords.isEmpty {
            out += "(none)\n"
        } else {
            for record in dictationRecords {
                out += "\(dateFormatter.string(from: record.timestamp)) mode=\(record.mode)\n"
                out += "raw: \(oneLinePreview(record.raw))\n"
                out += "processed: \(oneLinePreview(record.processed))\n"
            }
        }
        out += "\n"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
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

                HStack {
                    Text("All Entries (\(hist.records.count))").font(.headline)
                    Spacer()
                    if !hist.records.isEmpty {
                        Button("Clear All") { hist.clearAll() }
                            .foregroundColor(.red).buttonStyle(.plain).font(.caption)
                    }
                }
                if hist.records.isEmpty {
                    Text("No dictations yet. Use the Dictate hotkey to record your first one.")
                        .font(.caption).foregroundColor(.secondary).padding(.vertical, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(hist.records) { e in
                            HistoryEntryRow(entry: e)
                        }
                    }
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
                    .background(appPurple.opacity(0.15)).cornerRadius(4)
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
        .settingsCard()
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
                HStack {
                    Text("Word Corrections").font(.title2).bold()
                    Spacer()
                }
                Text("Misheard → Correct. Applied before any other processing.")
                    .foregroundColor(.secondary)

                GroupBox(label: Text("Active Corrections").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 6) {
                        if vocab.replacements.isEmpty {
                            Text("No corrections yet.")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 6) {
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
                                    .settingsCard()
                                }
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
                HStack {
                    Text("Vocabulary").font(.title2).bold()
                    Spacer()
                }

                GroupBox(label: Text("Vocabulary Hints").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Proper nouns, product names — hints the model toward correct spelling.")
                            .font(.caption).foregroundColor(.secondary)
                        if vocab.vocab.isEmpty {
                            Text("No terms yet.").font(.caption).foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 6) {
                                ForEach(Array(vocab.vocab.enumerated()), id: \.offset) { i, term in
                                    HStack {
                                        Text(term)
                                        Spacer()
                                        Button { vocab.removeVocab(at: IndexSet([i])) } label: {
                                            Image(systemName: "trash").foregroundColor(.red)
                                        }.buttonStyle(.plain)
                                    }.font(.system(size: 13))
                                    .settingsCard()
                                }
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
                        VStack(spacing: 6) {
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
                                .settingsCard()
                            }
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
                    .foregroundColor(playing ? appPurple : .secondary)
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
                UserDefaults.standard.set(name, forKey: VoiceSettingsKeys.startSound)
            }
            .buttonStyle(.bordered).controlSize(.mini)
            .disabled(isStart)

            Button("→ Stop") {
                model.stopSound = name
                UserDefaults.standard.set(name, forKey: VoiceSettingsKeys.stopSound)
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
    private var dictationAssistantBinding: Binding<String> {
        Binding(
            get: { model.dictationAssistantProvider },
            set: {
                model.dictationAssistantProvider = $0
                UserDefaults.standard.set($0, forKey: VoiceSettingsKeys.dictationAssistantProvider)
            }
        )
    }

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

                GroupBox(label: Text("Shortcuts").font(.subheadline).bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommendation: keep dictation hotkeys here. They control recording behavior; voice-based prompt actions live under Shortcuts as custom voice triggers.")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.bindings.filter { ["dictate", "dictateadd"].contains($0.action) }) { b in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.name)
                                    Text(b.detail).font(.caption).foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if b.action == "dictateadd" {
                                    Picker("", selection: dictationAssistantBinding) {
                                        Text("Default").tag("default")
                                        Text("Claude").tag("claude")
                                        Text("ChatGPT").tag("codex")
                                    }
                                    .labelsHidden()
                                    .frame(width: 190)
                                    .help("Default follows Shortcuts -> Default assistant. Claude or ChatGPT overrides assistant dictation only.")
                                }
                                KeyBindingField(action: b.action, binding: b, model: model)
                            }
                            .settingsCard()
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
                                set: { model.soundsEnabled = $0; UserDefaults.standard.set($0, forKey: VoiceSettingsKeys.soundsEnabled) }
                            ))
                            Spacer()
                        }
                        if model.soundsEnabled {
                            HStack(spacing: 10) {
                                Text("Volume").font(.callout).frame(width: 56, alignment: .leading)
                                Slider(value: Binding(
                                    get: { model.soundVolume },
                                    set: { model.soundVolume = $0; UserDefaults.standard.set($0, forKey: VoiceSettingsKeys.soundVolume) }
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
