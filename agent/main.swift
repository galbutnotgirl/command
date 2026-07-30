// ClaudeCommand — the one persistent app process. A single
// always-running, LSUIElement background app with its OWN stable TCC identity
// (com.claudecommand), granted Accessibility once. It does everything
// the short-lived Service/helper processes couldn't do reliably:
//
//   1. GLOBAL HOTKEYS — Carbon RegisterEventHotKey for every action, so they
//      fire from any app regardless of text selection (macOS Service shortcuts
//      only fire for text-input services; no-input ones never worked).
//
//   2. KEYSTROKE SERVER — Unix socket; synthesizes ⌘C / ⌘V / Return on request.
//      Long-lived + own grant → one Accessibility grant covers every app, no
//      launch latency, so submit/paste land in the right field.
//
//   3. CLIPBOARD PICKER — the Alfred-style history picker is now built in (was a
//      separate ClipHistory.app). The agent already has the grant, so it sets
//      the clipboard, refocuses the prior app, and pastes in-process. Normal
//      pick = paste + close; ⌘+pick = paste + stay open for the next one.
//
// Hotkey config: ~/.claude/state/command-hotkeys.json  (written by set-hotkeys.sh)
// Worker (sibling of this .app): send-to-claude.sh, spawned with ACTION=<x>.

import Cocoa
import Carbon.HIToolbox
import CoreGraphics
import ApplicationServices
import UserNotifications
import Darwin
import ClaudeCommandCore

let HOME = NSHomeDirectory()
let SOCK = "\(HOME)/.claude/state/command-agent.sock"
let CFG  = "\(HOME)/.claude/state/command-hotkeys.json"
let CLIPS = "\(HOME)/.claude/state/cliphistory"
// bundledResource — finds a file in .app/Contents/Resources using the executable
// path. Bundle.main.path(forResource:ofType:) can return nil when the process is
// launched directly by launchd before AppKit fully initialises NSBundle.
func bundledResource(_ name: String) -> String {
    let exe = ProcessInfo.processInfo.arguments[0]
    let contentsDir = ((exe as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    let resourcesDir = (contentsDir as NSString).appendingPathComponent("Resources")
    let bundled = (resourcesDir as NSString).appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: bundled) { return bundled }
    // Dev fallback: file in the project directory next to the .app
    let appDir     = (contentsDir  as NSString).deletingLastPathComponent
    let projectDir = (appDir       as NSString).deletingLastPathComponent
    return (projectDir as NSString).appendingPathComponent(name)
}

let WORKER: String = bundledResource("send-to-claude.sh")

// ---- keystroke synthesis (own process → one Accessibility grant) -----------
let kC: CGKeyCode = 0x08, kV: CGKeyCode = 0x09, kRet: CGKeyCode = 0x24

func ensureTrusted() {
    if AXIsProcessTrusted() { return }
    let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(o)
}

func postKey(_ k: CGKeyCode, cmd: Bool, opt: Bool = false, shift: Bool = false) {
    let s = CGEventSource(stateID: .combinedSessionState)
    guard let d = CGEvent(keyboardEventSource: s, virtualKey: k, keyDown: true),
          let u = CGEvent(keyboardEventSource: s, virtualKey: k, keyDown: false) else { return }
    var flags: CGEventFlags = []
    if cmd { flags.insert(.maskCommand) }
    if opt { flags.insert(.maskAlternate) }
    if shift { flags.insert(.maskShift) }
    d.flags = flags; u.flags = flags
    d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
}

func postKey(_ k: CGKeyCode, cmd: Bool, opt: Bool = false, shift: Bool = false, to bundle: String) -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        return false
    }
    let s = CGEventSource(stateID: .combinedSessionState)
    guard let d = CGEvent(keyboardEventSource: s, virtualKey: k, keyDown: true),
          let u = CGEvent(keyboardEventSource: s, virtualKey: k, keyDown: false) else { return false }
    var flags: CGEventFlags = []
    if cmd { flags.insert(.maskCommand) }
    if opt { flags.insert(.maskAlternate) }
    if shift { flags.insert(.maskShift) }
    d.flags = flags; u.flags = flags
    d.postToPid(app.processIdentifier); u.postToPid(app.processIdentifier)
    return true
}

func activate(_ bundle: String) {
    guard !bundle.isEmpty else { return }
    // open -b is reliable on all macOS (Tahoe: NSRunningApplication.activate()
    // doesn't steal focus from another app when called from an LSUIElement process).
    let t = Process(); t.launchPath = "/usr/bin/open"; t.arguments = ["-b", bundle]
    try? t.run()
}

// Poll until `bundle` is frontmost. LaunchServices activation can exceed 300 ms
// on a busy Mac; posting paste before focus lands silently drops dictation.
@discardableResult
func waitForActive(_ bundle: String, attempts: Int = 120) -> Bool {
    guard !bundle.isEmpty else { return false }
    for _ in 0..<max(1, attempts) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .first?.isActive == true { return true }
        usleep(10_000)
    }
    return false
}

// Post a user-facing banner (LSUIElement agent has no UI of its own otherwise).
private func enqueueNotification(_ center: UNUserNotificationCenter, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
        if let error { appendLog("[notify] delivery failed: \(error.localizedDescription)") }
    }
}

func notify(_ title: String, _ body: String) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            enqueueNotification(center, title: title, body: body)
        case .notDetermined:
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error { appendLog("[notify] authorization failed: \(error.localizedDescription)") }
                if granted { enqueueNotification(center, title: title, body: body) }
            }
        case .denied:
            appendLog("[notify] skipped because notifications are disabled")
        @unknown default:
            appendLog("[notify] skipped because notification authorization is unknown")
        }
    }
}

func clipboardHasImage() -> Bool {
    NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
}

func focusedDocumentURL(bundleIdentifier: String) -> String {
    guard AXIsProcessTrusted(), !bundleIdentifier.isEmpty else { return "" }
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    guard let application = applications.first(where: \.isActive) ?? applications.first else { return "" }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    var windowValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appElement,
        kAXFocusedWindowAttribute as CFString,
        &windowValue
    ) == .success, let windowValue else { return "" }
    let window = unsafeBitCast(windowValue, to: AXUIElement.self)
    var documentValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        window,
        kAXDocumentAttribute as CFString,
        &documentValue
    ) == .success else { return "" }
    return documentValue as? String ?? ""
}

// ---- spawn the worker on a hotkey ------------------------------------------
// Capture current text selection synchronously on the main thread.
// Called the instant a non-screenshot hotkey fires — before any async dispatch —
// so the source app still has focus and the selection is still live.
// Polls clipboard change-count for up to 200ms; returns "" if nothing copied.
// Must be called on the main thread (postKey + NSPasteboard require it).
func captureSelectionSync() -> String {
    let cc0 = NSPasteboard.general.changeCount
    postKey(kC, cmd: true)
    for _ in 0..<40 {                          // poll up to 400ms in 10ms steps
        usleep(10_000)
        if NSPasteboard.general.changeCount != cc0 {
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
    }
    return ""
}

func captureOrClipboard() -> String {
    let sel = captureSelectionSync()
    if !sel.isEmpty { return sel }
    return NSPasteboard.general.string(forType: .string) ?? ""
}

func runWorker(_ action: String, source: String, captured: String = "", customPrompt: String = "",
               customSubmit: Bool = false, customSession: String = "new", customIncludeSource: Bool = true,
               destination: String? = nil, provider: AIProvider? = nil,
               builtInAutoSubmit: Bool? = nil) {
    // Screenshot actions need Screen Recording. Without it, `screencapture` fails
    // ("could not create image from rect") and the user just re-prompts forever.
    // Gate it: fire the system prompt + open Set Up, and skip the doomed capture.
    // The grant only takes effect once this process relaunches (TCC reads it at
    // launch), so point the user at the current product restart action.
    if (action.hasPrefix("shot") || action == "customshot") && !screenRecordingOK() {
        DispatchQueue.main.async {
            requestScreenRecording()
            openPrivacyPane("Privacy_ScreenCapture")
            settingsWindow.show(tab: .setup)
            notify("Screen Recording needed",
                   "Enable Command, then restart Command to apply it.")
        }
        return
    }
    guard FileManager.default.fileExists(atPath: WORKER) else {
        let msg = "[runWorker] WORKER not found at \(WORKER) — reinstall the app"
        appendLog(msg)
        notify("Command broken", "send-to-claude.sh missing. Reinstall from the Install Guide.")
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [WORKER]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:\(HOME)/.claude/local:\(HOME)/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["ACTION"] = action
    env["SOURCE_BUNDLE"] = source
    env["AGENT_SOCK"] = SOCK
    if !captured.isEmpty { env["CAPTURED_TEXT"] = captured }
    if !customPrompt.isEmpty { env["CUSTOM_PROMPT"] = customPrompt }
    if customSubmit { env["CUSTOM_SUBMIT"] = "go" }
    if customSession == "add" { env["CUSTOM_SESSION"] = "add" }
    if !customIncludeSource { env["CUSTOM_INCLUDE_SOURCE"] = "0" }
    if let builtInAutoSubmit { env["BUILTIN_AUTO_SUBMIT"] = builtInAutoSubmit ? "1" : "0" }
    let effectiveProvider = provider ?? selectedProvider()
    let providerDefaultDestination = effectiveProvider == .claude
        ? (UserDefaults.standard.string(forKey: "claudeDestination") ?? "recent")
        : (UserDefaults.standard.string(forKey: "codexDestination") ?? "recent")
    let requestedDestination = destination ?? providerDefaultDestination
    let canonicalDestination = requestedDestination == "cowork" ? "chat" : requestedDestination
    let effectiveDestination = canonicalDestination
    env["CLAUDE_DESTINATION"] = effectiveDestination
    env["OPENAI_DESTINATION"] = effectiveDestination
    env["COMMAND_PROVIDER"] = effectiveProvider.rawValue
    let codexWorkspace = configuredCodexWorkspace()
    env["CODEX_WORKSPACE"] = codexWorkspace
    p.environment = env
    let errPipe = Pipe()
    p.standardError = errPipe
    do {
        try p.run()
        DispatchQueue.global().async {
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let out = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                appendLog("[runWorker] action=\(action) exit=\(p.terminationStatus) stderr=\(out.prefix(400))")
                appendForegroundCommandHistory(action: action, source: source, destination: effectiveDestination,
                                               status: "failed", prompt: customPrompt.isEmpty ? nil : customPrompt,
                                               error: String(out.prefix(400)), provider: effectiveProvider,
                                               workspace: effectiveProvider == .codex ? codexWorkspace : nil)
            } else {
                appendForegroundCommandHistory(action: action, source: source, destination: effectiveDestination,
                                               status: "succeeded", prompt: customPrompt.isEmpty ? nil : customPrompt,
                                               error: nil, provider: effectiveProvider,
                                               workspace: effectiveProvider == .codex ? codexWorkspace : nil)
            }
        }
    } catch {
        appendLog("[runWorker] launch failed: \(error)")
        appendForegroundCommandHistory(action: action, source: source, destination: effectiveDestination,
                                       status: "failed", prompt: customPrompt.isEmpty ? nil : customPrompt,
                                       error: String(describing: error), provider: effectiveProvider,
                                       workspace: effectiveProvider == .codex ? codexWorkspace : nil)
    }
}

func dispatchBuiltInAction(_ action: String, source: String, captured: String) {
    runWorker(action, source: source, captured: captured, builtInAutoSubmit: builtInComposeAutoSubmit(action))
}

private let agentLogLock = NSLock()
private let agentLogTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()

func appendLog(_ msg: String) {
    agentLogLock.lock()
    defer { agentLogLock.unlock() }
    let timestamp = agentLogTimestampFormatter.string(from: Date())
    for path in ["\(HOME)/.claude/logs/command-agent.err",
                 "\(HOME)/.claude/logs/attribution.log"] {
        let line = "\(timestamp) \(msg)\n"
        guard let data = line.data(using: .utf8) else { continue }
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(data); fh.closeFile() }
        else { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}

// ---- clipboard history picker (built in) -----------------------------------

typealias FilterMode = ClipboardHistoryFilter
enum PickerTheme: String { case auto, light, dark }
enum PasteTarget { case prev, claude, claudeNew, openURL }

func clipboardPickerSetting(_ key: String, default fallback: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
}

func clipboardPickerModifier(_ key: String, default fallback: ClipboardPickerModifier) -> ClipboardPickerModifier {
    guard let raw = UserDefaults.standard.string(forKey: key) else { return fallback }
    return ClipboardPickerModifier(rawValue: raw) ?? fallback
}

func clipboardPickerTarget(for clip: Clip, flags: NSEvent.ModifierFlags) -> PasteTarget {
    var pressed = Set<ClipboardPickerModifier>()
    if flags.contains(.command) { pressed.insert(.command) }
    if flags.contains(.option) { pressed.insert(.option) }
    if flags.contains(.shift) { pressed.insert(.shift) }
    if flags.contains(.control) { pressed.insert(.control) }
    let bindings = [
        ClipboardPickerActionBinding(
            action: .openURL,
            modifier: clipboardPickerModifier(ClipboardPickerSettingsKeys.openURLModifier, default: .shift),
            enabled: clipboardPickerSetting(ClipboardPickerSettingsKeys.openURLEnabled, default: true)),
        ClipboardPickerActionBinding(
            action: .newSession,
            modifier: clipboardPickerModifier(ClipboardPickerSettingsKeys.newSessionModifier, default: .command),
            enabled: clipboardPickerSetting(ClipboardPickerSettingsKeys.newSessionEnabled, default: true)),
        ClipboardPickerActionBinding(
            action: .sendToAssistant,
            modifier: clipboardPickerModifier(ClipboardPickerSettingsKeys.sendAssistantModifier, default: .option),
            enabled: clipboardPickerSetting(ClipboardPickerSettingsKeys.sendAssistantEnabled, default: true)),
    ]
    switch clipboardPickerAction(isURL: clip.detectedURL != nil, pressedModifiers: pressed, bindings: bindings) {
    case .paste: return .prev
    case .newSession: return .claudeNew
    case .sendToAssistant: return .claude
    case .openURL: return .openURL
    }
}

var iconCache: [String: NSImage] = [:]

// True purple — not systemPurple which renders burgundy in some themes.
// Dynamic: the deep purple reads fine on light/white controls, but as button
// text on macOS's dark-mode gray .bordered fill it's low-contrast and hard to
// read — dark mode gets a lighter lavender instead.
let purpleAccent = NSColor(name: nil) { appearance in
    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return isDark
        ? NSColor(red: 191/255, green: 156/255, blue: 255/255, alpha: 1.0)
        : NSColor(red: 112/255, green: 40/255, blue: 215/255, alpha: 1.0)
}

func pickerTheme() -> PickerTheme {
    PickerTheme(rawValue: UserDefaults.standard.string(forKey: "pickerTheme") ?? "auto") ?? .auto
}
func setPickerTheme(_ t: PickerTheme) { UserDefaults.standard.set(t.rawValue, forKey: "pickerTheme") }

// The atom-orbital brand mark — two ellipses + nucleus dot, rendered as a template
// image (tintable, like an SF Symbol) at any size. This is the SAME drawing code
// the menu-bar status item uses (see MenuBar.swift's brandIcon()), so the mark the
// clip picker shows for anything ClaudeCommand itself produced is pixel-consistent
// with the one you see in the menu bar — not a lookalike SF Symbol, not the full-color
// .app icon (which can't be tinted grey/purple like every other filter pill here).
func brandGlyph(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { full in
        let rect = full.insetBy(dx: full.width * 0.09, dy: full.height * 0.09)
        let mid = NSPoint(x: rect.midX, y: rect.midY)
        let s = rect.width
        NSColor.black.setFill(); NSColor.black.setStroke()
        let rw = s * 0.92, rh = s * 0.56
        let lw = max(1.0, s * 0.05)
        for deg in [28.0, -28.0] {
            let oval = NSBezierPath(ovalIn: NSRect(x: -rw / 2, y: -rh / 2, width: rw, height: rh))
            var t = AffineTransform(translationByX: mid.x, byY: mid.y)
            t.rotate(byDegrees: CGFloat(deg))
            oval.transform(using: t)
            oval.lineWidth = lw; oval.stroke()
        }
        let dot = s * 0.17
        NSBezierPath(ovalIn: NSRect(x: mid.x - dot/2, y: mid.y - dot/2, width: dot, height: dot)).fill()
        return true
    }
    img.isTemplate = true
    return img
}

func appIcon(bundle: String) -> NSImage? {
    guard !bundle.isEmpty else { return nil }
    if let cached = iconCache[bundle] { return cached }
    // Dictation rows get the same waveform mark as the "Dictated" filter pill — it's
    // a voice transcript, not a copy ClaudeCommand routed through. Everything else
    // ClaudeCommand itself wrote (the "sent"/wrapped-prompt case, and the plain
    // internal sentinel) gets the brand mark, matching the "Sent" pill and the menu bar.
    if bundle == "com.claudecommand.dictation" {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? brandGlyph(size: 32)
        iconCache[bundle] = icon
        return icon
    }
    if bundle.hasPrefix("com.claudecommand") {
        let icon = brandGlyph(size: 32)
        iconCache[bundle] = icon
        return icon
    }
    // screencaptureui is a system framework process — redirect to Screenshot.app for icon
    let lookupBundle = bundle == "com.apple.screencaptureui" ? "com.apple.Screenshot" : bundle
    // Running app first — direct icon, works for apps in non-standard locations
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: lookupBundle).first,
       let icon = app.icon {
        iconCache[bundle] = icon
        return icon
    }
    // Installed app fallback
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: lookupBundle) else { return nil }
    let img = NSWorkspace.shared.icon(forFile: url.path)
    iconCache[bundle] = img
    return img
}

func ageString(_ ts: Double) -> String {
    let d = Date().timeIntervalSince1970 - ts
    if d < 60 { return "now" }
    if d < 3600 { return "\(Int(d / 60))m" }
    if d < 86400 { return "\(Int(d / 3600))h" }
    return "\(Int(d / 86400))d"
}

struct Clip {
    let type: String; let file: String; let preview: String
    let full: String; let ts: Double; let bundle: String; let origin: String
    var detectedURL: DetectedClipboardURL? {
        guard type != "image" else { return nil }
        return detectClipboardURL(full.isEmpty ? preview : full)
    }
}

func loadClips() -> [Clip] {
    let idx = (CLIPS as NSString).appendingPathComponent("index.json")
    guard let data = FileManager.default.contents(atPath: idx),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    let cutoff = Date().timeIntervalSince1970 - Double(readRetentionDays()) * 86400
    return arr.compactMap { d in
        guard let t = d["type"] as? String, let f = d["file"] as? String else { return nil }
        let ts = (d["ts"] as? Double) ?? Double((d["ts"] as? Int) ?? 0)
        if ts > 0 && ts < cutoff { return nil }
        return Clip(type: t, file: f,
                    preview: (d["preview"] as? String) ?? "",
                    full: (d["full"] as? String) ?? "",
                    ts: ts,
                    bundle: (d["bundle"] as? String) ?? "",
                    origin: (d["origin"] as? String) ?? "")
    }
}

let CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"
let CODEX_BUNDLE = "com.openai.codex"

func selectedProvider() -> AIProvider {
    AIProvider(rawValue: UserDefaults.standard.string(forKey: "defaultProvider") ?? "codex") ?? .codex
}

func configuredCodexWorkspace() -> String {
    UserDefaults.standard.string(forKey: "codexWorkspace") ?? NSHomeDirectory()
}

func dictationAssistantProvider() -> AIProvider {
    let raw = UserDefaults.standard.string(forKey: VoiceSettingsKeys.dictationAssistantProvider) ?? VoiceSettingsDefaults.dictationAssistantProvider
    guard let choice = AIProviderChoice(rawValue: raw) else { return selectedProvider() }
    return choice.resolve(default: selectedProvider())
}

func dictationAssistant2Provider() -> AIProvider {
    let raw = UserDefaults.standard.string(forKey: VoiceSettingsKeys.dictationAssistant2Provider) ?? VoiceSettingsDefaults.dictationAssistant2Provider
    guard let choice = AIProviderChoice(rawValue: raw) else { return selectedProvider() }
    return choice.resolve(default: selectedProvider())
}

func selectedProviderBundle() -> String { selectedProvider().appBundleIdentifier }

func codexExecutablePath() -> String? {
    let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                      "/Applications/ChatGPT.app/Contents/Resources/codex"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func focusedElementIsEditable() -> Bool {
    let system = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
          let focused = value else { return false }
    let element = unsafeBitCast(focused, to: AXUIElement.self)
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
        && settable.boolValue
}
let pickerW: CGFloat = 768
let pickerH: CGFloat = 565   // fixed height
let listColW: CGFloat = 359
let pickerRowH: CGFloat = 28  // compact rows

final class PickerPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Flipped stack so NSScrollView shows content top-to-bottom (not bottom-to-top).
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

// Block-based NSObject target so we can use #selector on closures.
final class ActionBlock: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block; super.init() }
    @objc func run() { block() }
}
final class PickRow: NSView {
    var onPick: ((NSEvent.ModifierFlags) -> Void)?
    override func layout() { super.layout(); layer?.cornerRadius = 6; layer?.cornerCurve = .continuous }
    @objc func clicked() {
        onPick?(NSEvent.modifierFlags)
    }
}

final class ClipPicker: NSObject, NSWindowDelegate {
    var win: PickerPanel!
    var fx: NSVisualEffectView!
    let listStack = FlippedStack()
    var previewPane: NSView!
    var prevImgV: NSImageView?     // persistent — content updated, not recreated
    var prevTxtV: NSTextField?
    var prevMetaV: NSTextField?
    var listWidthConstraint: NSLayoutConstraint?
    var filterActionBlocks: [ActionBlock] = []   // kept alive while picker lives
    var all: [Clip] = [], shown: [Clip] = [], rows: [PickRow] = []
    var selected = 0, filterMode: FilterMode = .all, prevBundle = "", query = ""
    var isPicking = false  // suppresses NSApp.hide during choose() so activate() works in macOS 14+

    func windowDidResignKey(_ notification: Notification) { if !isPicking { hide() } }

    func show(prev: String) {
        prevBundle = prev
        all = loadClips(); filterMode = .all; selected = 0; query = ""
        if win == nil { build() }
        applyTheme()
        refresh()
        listStack.scroll(NSPoint(x: 0, y: 0))
        win.setContentSize(NSSize(width: pickerW, height: pickerH)); win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { win != nil && win.isVisible }

    func applyTheme() {
        switch pickerTheme() {
        case .light: fx.appearance = NSAppearance(named: .aqua)
        case .dark:  fx.appearance = NSAppearance(named: .darkAqua)
        case .auto:  fx.appearance = nil
        }
    }

    func build() {
        win = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: pickerW, height: pickerH),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = true
        win.level = .floating; win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .transient]
        win.delegate = self   // windowDidResignKey → hide()

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 14; container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5; container.layer?.borderColor = NSColor.separatorColor.cgColor
        win.contentView = container

        fx = NSVisualEffectView()
        fx.material = .sidebar; fx.blendingMode = .behindWindow; fx.state = .active
        fx.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fx)
        NSLayoutConstraint.activate([
            fx.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fx.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fx.topAnchor.constraint(equalTo: container.topAnchor),
            fx.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        listStack.orientation = .vertical; listStack.alignment = .leading
        listStack.spacing = 0; listStack.translatesAutoresizingMaskIntoConstraints = false
    }

    func refresh() {
        shown = Array(filteredClips().prefix(50))
        selected = min(selected, max(0, shown.count - 1))
        fx.subviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if shown.isEmpty {
            let msg: String
            switch filterMode {
            case .images:   msg = "No images in history."
            case .text:     msg = query.isEmpty ? "No text clips." : "No matches."
            case .urls:     msg = query.isEmpty ? "No URLs in history." : "No matches."
            case .dictated: msg = query.isEmpty ? "Nothing dictated yet." : "No matches."
            case .sent:     msg = query.isEmpty ? "Nothing sent via Command yet." : "No matches."
            case .all:      msg = query.isEmpty ? "History empty." : "No matches."
            }
            let e = NSTextField(labelWithString: msg)
            e.font = .systemFont(ofSize: 13); e.textColor = .tertiaryLabelColor
            e.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(e)
        } else {
            for (i, c) in shown.enumerated() {
                let r = makeRow(i, c); rows.append(r); listStack.addArrangedSubview(r)
                r.widthAnchor.constraint(equalToConstant: listColW).isActive = true
            }
        }

        let header = makeHeader()
        header.translatesAutoresizingMaskIntoConstraints = false

        let topSep = makeSep(); let midSep = makeSep(); let botSep = makeSep()

        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay; scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = listStack
        listWidthConstraint?.isActive = false
        listWidthConstraint = listStack.widthAnchor.constraint(equalToConstant: listColW)
        listWidthConstraint?.isActive = true

        // Persistent preview pane — created once per refresh, subviews updated in updatePreview.
        previewPane = NSView(); previewPane.wantsLayer = true
        previewPane.translatesAutoresizingMaskIntoConstraints = false

        let metaV = NSTextField(labelWithString: "")
        metaV.font = .systemFont(ofSize: 10); metaV.textColor = .tertiaryLabelColor
        metaV.translatesAutoresizingMaskIntoConstraints = false; metaV.lineBreakMode = .byTruncatingTail
        previewPane.addSubview(metaV); prevMetaV = metaV

        let imgV = NSImageView()
        imgV.imageScaling = .scaleProportionallyDown; imgV.imageAlignment = .alignCenter
        imgV.wantsLayer = true
        imgV.layer?.cornerRadius = 6; imgV.layer?.cornerCurve = .continuous; imgV.layer?.masksToBounds = true
        imgV.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imgV.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imgV.translatesAutoresizingMaskIntoConstraints = false; imgV.isHidden = true
        previewPane.addSubview(imgV); prevImgV = imgV

        let txtV = NSTextField(wrappingLabelWithString: "")
        txtV.font = .monospacedSystemFont(ofSize: 11, weight: .regular); txtV.textColor = .labelColor
        txtV.translatesAutoresizingMaskIntoConstraints = false; txtV.isHidden = true
        previewPane.addSubview(txtV); prevTxtV = txtV

        NSLayoutConstraint.activate([
            metaV.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 12),
            metaV.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -12),
            metaV.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor, constant: -8),

            imgV.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 10),
            imgV.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -10),
            imgV.topAnchor.constraint(equalTo: previewPane.topAnchor, constant: 10),
            imgV.bottomAnchor.constraint(equalTo: metaV.topAnchor, constant: -6),

            txtV.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 12),
            txtV.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -12),
            txtV.topAnchor.constraint(equalTo: previewPane.topAnchor, constant: 12),
            txtV.bottomAnchor.constraint(lessThanOrEqualTo: metaV.topAnchor, constant: -6),
        ])

        let hintView = makeHint()
        hintView.translatesAutoresizingMaskIntoConstraints = false

        fx.addSubview(header); fx.addSubview(topSep)
        fx.addSubview(scroll); fx.addSubview(midSep); fx.addSubview(previewPane)
        fx.addSubview(botSep); fx.addSubview(hintView)

        let hH: CGFloat = 44, footH: CGFloat = 26
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            header.topAnchor.constraint(equalTo: fx.topAnchor),
            header.heightAnchor.constraint(equalToConstant: hH),

            topSep.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            topSep.topAnchor.constraint(equalTo: header.bottomAnchor),
            topSep.heightAnchor.constraint(equalToConstant: 0.5),

            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: listColW),
            scroll.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: botSep.topAnchor),

            midSep.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            midSep.widthAnchor.constraint(equalToConstant: 0.5),
            midSep.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            midSep.bottomAnchor.constraint(equalTo: botSep.topAnchor),

            previewPane.leadingAnchor.constraint(equalTo: midSep.trailingAnchor),
            previewPane.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            previewPane.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            previewPane.bottomAnchor.constraint(equalTo: botSep.topAnchor),

            botSep.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            botSep.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            botSep.bottomAnchor.constraint(equalTo: hintView.topAnchor),
            botSep.heightAnchor.constraint(equalToConstant: 0.5),

            hintView.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            hintView.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            hintView.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            hintView.heightAnchor.constraint(equalToConstant: footH),
        ])

        highlight(); updatePreview()
    }

    private func makeSep() -> NSView {
        let v = NSView(); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    func makeHeader() -> NSView {
        let v = NSView()

        let searchIcon = NSImageView()
        let searchCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(searchCfg)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        searchIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let placeholder = query.isEmpty ? "Search clipboard…" : query
        let lbl = NSTextField(labelWithString: placeholder)
        lbl.font = .systemFont(ofSize: 13)
        lbl.textColor = query.isEmpty ? .secondaryLabelColor : .labelColor
        lbl.lineBreakMode = .byTruncatingTail
        lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lbl.translatesAutoresizingMaskIntoConstraints = false

        let badge = makeFilterBadge()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let row = NSStackView(views: [badge, searchIcon, lbl])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    func makeFilterBadge() -> NSView {
        filterActionBlocks.removeAll()
        // URL detection is derived from full clip text, so retained history
        // appears here without rewriting its on-disk index.
        // Sent's sym is nil — makeFilterPill draws the brand glyph for it instead (the
        // same mark as the menu bar), so it stays pixel-consistent instead of a lookalike.
        let specs: [(sym: String?, label: String, mode: FilterMode)] = [
            ("photo",       "Images",   .images),
            (nil,           "All",      .all),
            ("doc.text",    "Text",     .text),
            ("link",        "URLs",     .urls),
            ("waveform",    "Dictated", .dictated),
            (nil,           "Sent",     .sent),
        ]
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 3
        for spec in specs {
            let active = filterMode == spec.mode
            let btn = makeFilterPill(sym: spec.sym, label: spec.label, active: active, mode: spec.mode)
            stack.addArrangedSubview(btn)
        }
        return stack
    }

    private func makeFilterPill(sym: String?, label: String, active: Bool, mode: FilterMode) -> NSView {
        let v = NSView(); v.wantsLayer = true
        v.layer?.cornerRadius = 5; v.layer?.cornerCurve = .continuous
        v.layer?.backgroundColor = active
            ? purpleAccent.withAlphaComponent(0.25).cgColor
            : NSColor.labelColor.withAlphaComponent(0.12).cgColor
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = active
            ? purpleAccent.withAlphaComponent(0.5).cgColor
            : NSColor.labelColor.withAlphaComponent(0.18).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false

        // Icon-only for pills that have a symbol, or the brand glyph for Sent
        // (same mark as the menu bar, tinted the same grey→purple way); text-only for "All".
        let content = NSStackView(); content.orientation = .horizontal; content.spacing = 3
        content.translatesAutoresizingMaskIntoConstraints = false
        if mode == .sent || sym != nil {
            let iv = NSImageView()
            // The brand glyph's rings sit inside a 9%-inset drawing box (see brandGlyph),
            // so at the same nominal box size it reads visibly smaller than the SF Symbols
            // beside it — bump its box up rather than the others down.
            let boxSize: CGFloat = mode == .sent ? 17 : 13
            if mode == .sent {
                iv.image = brandGlyph(size: boxSize)
            } else {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: active ? .semibold : .medium)
                iv.image = NSImage(systemSymbolName: sym!, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            }
            iv.contentTintColor = active ? purpleAccent : .labelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: boxSize).isActive = true
            iv.heightAnchor.constraint(equalToConstant: boxSize).isActive = true
            content.addArrangedSubview(iv)
        } else {
            let lbl = NSTextField(labelWithString: label)
            lbl.font = .systemFont(ofSize: 11, weight: active ? .semibold : .medium)
            lbl.textColor = active ? purpleAccent : .labelColor
            content.addArrangedSubview(lbl)
        }
        v.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.heightAnchor.constraint(equalToConstant: 22),
            v.widthAnchor.constraint(equalToConstant: 34),
        ])

        // Click handler — cycle through modes; clicking active filter resets to .all
        let target = mode  // capture
        let block = ActionBlock { [weak self] in
            guard let s = self else { return }
            s.filterMode = (s.filterMode == target) ? .all : target
            s.query = ""; s.selected = 0; s.refresh()
        }
        filterActionBlocks.append(block)   // retain until next refresh clears them
        v.addGestureRecognizer(NSClickGestureRecognizer(target: block, action: #selector(ActionBlock.run)))
        return v
    }

    func makeHint() -> NSView {
        let v = NSView()
        var hints = ["↑↓", "1-9 pick", "↩ previous"]
        if clipboardPickerSetting(ClipboardPickerSettingsKeys.newSessionEnabled, default: true) {
            let mod = clipboardPickerModifier(ClipboardPickerSettingsKeys.newSessionModifier, default: .command)
            hints.append("\(mod.symbol)↩ new session")
        }
        if clipboardPickerSetting(ClipboardPickerSettingsKeys.sendAssistantEnabled, default: true) {
            let mod = clipboardPickerModifier(ClipboardPickerSettingsKeys.sendAssistantModifier, default: .option)
            hints.append("\(mod.symbol)↩ assistant")
        }
        if clipboardPickerSetting(ClipboardPickerSettingsKeys.openURLEnabled, default: true) {
            let mod = clipboardPickerModifier(ClipboardPickerSettingsKeys.openURLModifier, default: .shift)
            hints.append("\(mod.symbol)↩ open URL")
        }
        hints.append("esc")
        let t = NSTextField(labelWithString: hints.joined(separator: " · "))
        t.font = .systemFont(ofSize: 10); t.textColor = .quaternaryLabelColor
        t.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(t)
        NSLayoutConstraint.activate([
            t.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            t.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    func makeRow(_ i: Int, _ c: Clip) -> PickRow {
        let row = PickRow(); row.wantsLayer = true
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: pickerRowH).isActive = true

        let h = NSStackView()
        h.orientation = .horizontal; h.alignment = .centerY; h.spacing = 8
        h.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        h.translatesAutoresizingMaskIntoConstraints = false

        // Source app icon (18×18) with tooltip showing app name
        let appIV = NSImageView()
        if let icon = appIcon(bundle: c.bundle) {
            appIV.image = icon
        } else {
            // "textformat" (an underlined A) reads as plain text at a glance — a doc.*
            // symbol here looked like a document/file icon, not "this is just text".
            appIV.image = NSImage(systemSymbolName: c.type == "image" ? "photo" : "textformat", accessibilityDescription: nil)
            appIV.contentTintColor = .tertiaryLabelColor
        }
        if !c.bundle.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.bundle) {
            appIV.toolTip = url.deletingPathExtension().lastPathComponent
        } else if !c.bundle.isEmpty {
            appIV.toolTip = c.bundle
        }
        appIV.wantsLayer = true
        appIV.layer?.cornerRadius = 4; appIV.layer?.cornerCurve = .continuous; appIV.layer?.masksToBounds = true
        appIV.imageScaling = .scaleProportionallyDown
        appIV.translatesAutoresizingMaskIntoConstraints = false
        appIV.widthAnchor.constraint(equalToConstant: 18).isActive = true
        appIV.heightAnchor.constraint(equalToConstant: 18).isActive = true

        // A row can be "from Chrome" AND "sent via ClaudeCommand" at once (the
        // common Add/custom-Add case) — the row icon stays the source app's so you
        // still know where it came from, but a small brand badge peeking out past
        // its trailing edge flags the "also sent" part without switching filters.
        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(appIV)
        NSLayoutConstraint.activate([
            appIV.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            appIV.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
        ])
        var containerWidth: CGFloat = 18
        if c.origin == "sent" {
            let badge = NSImageView()
            badge.image = brandGlyph(size: 11)
            badge.contentTintColor = purpleAccent
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            badge.layer?.cornerRadius = 6; badge.layer?.masksToBounds = true
            badge.translatesAutoresizingMaskIntoConstraints = false
            iconContainer.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 12),
                badge.heightAnchor.constraint(equalToConstant: 12),
                badge.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
                badge.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            ])
            containerWidth = 18 + 6   // room for the badge to peek out past the icon
        }
        iconContainer.widthAnchor.constraint(equalToConstant: containerWidth).isActive = true
        iconContainer.heightAnchor.constraint(equalToConstant: 18).isActive = true
        h.addArrangedSubview(iconContainer)

        if c.type == "image" {
            let iv = NSImageView()
            let imgPath = (CLIPS as NSString).appendingPathComponent(c.file)
            let thumbH: CGFloat = 28
            var thumbW: CGFloat = 44
            if let img = NSImage(contentsOfFile: imgPath) {
                iv.image = img
                let sz = img.size
                if sz.height > 0 { thumbW = min(max(thumbH * sz.width / sz.height, 20), 56) }
            }
            iv.imageScaling = .scaleProportionallyDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 3; iv.layer?.cornerCurve = .continuous; iv.layer?.masksToBounds = true
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: thumbW).isActive = true
            iv.heightAnchor.constraint(equalToConstant: thumbH).isActive = true
            h.addArrangedSubview(iv)
        } else {
            let one = c.preview.replacingOccurrences(of: "\n", with: " ")
            let lbl = NSTextField(labelWithString: one.isEmpty ? "(empty)" : one)
            lbl.lineBreakMode = .byTruncatingTail
            lbl.font = .systemFont(ofSize: 14); lbl.textColor = .labelColor
            lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            h.addArrangedSubview(lbl)
        }

        row.addSubview(h)

        // Index badge pinned to trailing edge — always at fixed position, never pushed by content.
        if i < 10 {
            let idxLabel = i < 9 ? "\(i + 1)" : "0"
            let badge = NSTextField(labelWithString: idxLabel)
            badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            badge.textColor = .tertiaryLabelColor
            badge.alphaValue = query.isEmpty ? 0.7 : 0.0
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.widthAnchor.constraint(equalToConstant: 14).isActive = true
            row.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
                badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: i < 10 ? -18 : 0),
            h.topAnchor.constraint(equalTo: row.topAnchor),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        row.addGestureRecognizer(NSClickGestureRecognizer(target: row, action: #selector(PickRow.clicked)))
        row.onPick = { [weak self] flags in
            guard let s = self, i < s.shown.count else { return }
            let clip = s.shown[i]
            s.choose(clip, target: clipboardPickerTarget(for: clip, flags: flags))
        }
        return row
    }

    func filteredClips() -> [Clip] {
        func searched(_ base: [Clip]) -> [Clip] {
            if query.isEmpty { return base }
            let q = query.lowercased()
            return base.filter { $0.full.lowercased().contains(q) || $0.preview.lowercased().contains(q) }
        }
        switch filterMode {
        case .images: return all.filter { $0.type == "image" }
        case .text:   return searched(all.filter { $0.type != "image" && $0.origin != "dictation" && $0.origin != "sent" })
        case .urls:   return searched(all.filter { $0.detectedURL != nil })
        case .dictated: return searched(all.filter { $0.origin == "dictation" })
        case .sent:     return searched(all.filter { $0.origin == "sent" })
        case .all:
            if query.isEmpty { return all }
            let q = query.lowercased()
            return all.filter { $0.type != "image" &&
                ($0.full.lowercased().contains(q) || $0.preview.lowercased().contains(q)) }
        }
    }

    func highlight() {
        for (k, r) in rows.enumerated() {
            r.layer?.backgroundColor = (k == selected)
                ? purpleAccent.withAlphaComponent(0.28).cgColor : NSColor.clear.cgColor
        }
        // Scroll selected row into view.
        if selected < rows.count {
            let row = rows[selected]
            row.scrollToVisible(row.bounds)
        }
        updatePreview()
    }

    func updatePreview() {
        guard let imgV = prevImgV, let txtV = prevTxtV, let metaV = prevMetaV else { return }
        guard selected < shown.count else {
            imgV.isHidden = true; txtV.isHidden = true; metaV.stringValue = ""; return
        }
        let c = shown[selected]
        let path = (CLIPS as NSString).appendingPathComponent(c.file)

        var meta: [String] = []
        if !c.bundle.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.bundle) {
            meta.append(url.deletingPathExtension().lastPathComponent)
        }
        if c.ts > 0 { meta.append(ageString(c.ts) + " ago") }
        metaV.stringValue = meta.joined(separator: "  ·  ")

        if c.type == "image", let img = NSImage(contentsOfFile: path) {
            imgV.image = img; imgV.isHidden = false; txtV.isHidden = true
        } else {
            let body = c.full.isEmpty ? c.preview : c.full
            txtV.stringValue = body.isEmpty ? "(empty)" : String(body.prefix(800))
            txtV.isHidden = false; imgV.isHidden = true
        }
    }

    func handle(_ ev: NSEvent) -> Bool {
        if !isVisible { return false }
        let cmd = ev.modifierFlags.contains(.command)
        let shift = ev.modifierFlags.contains(.shift)

        // Digit quick-pick: 1-9 selects items 0-8, 0 selects item 9.
        // Only when no search query (digits in query = search chars, not picks).
        if query.isEmpty && !cmd && !shift {
            let digitIdx: [UInt16: Int] = [18:0,19:1,20:2,21:3,23:4,22:5,26:6,28:7,25:8,29:9]
            if let idx = digitIdx[ev.keyCode], idx < shown.count {
                selected = idx; highlight()
                choose(shown[idx], target: .prev)
                return true
            }
        }

        switch ev.keyCode {
        case 53:   // esc: clear search → reset filter → close
            if !query.isEmpty { query = ""; selected = 0; refresh() }
            else if filterMode != .all { filterMode = .all; selected = 0; refresh() }
            else { hide() }
            return true
        case 125:  // ↓
            if !shown.isEmpty { selected = min(selected + 1, shown.count - 1); highlight() }
            return true
        case 126:  // ↑
            if !shown.isEmpty { selected = max(selected - 1, 0); highlight() }
            return true
        case 123:  // ← rotate filter carousel
            filterMode = filterMode.adjacent(step: -1)
            query = ""; selected = 0; refresh()
            return true
        case 124:  // → rotate filter carousel
            filterMode = filterMode.adjacent(step: 1)
            query = ""; selected = 0; refresh()
            return true
        case 36, 76:   // ↩ / numpad ↩
            if selected < shown.count {
                let clip = shown[selected]
                choose(clip, target: clipboardPickerTarget(for: clip, flags: ev.modifierFlags))
            }
            return true
        case 51:   // delete
            if !query.isEmpty { query.removeLast(); selected = 0; refresh() }
            return true
        default: break
        }
        guard let ch = ev.charactersIgnoringModifiers, !ch.isEmpty else { return true }
        if cmd { return true }
        if let u = ch.unicodeScalars.first, u.value >= 32, u.value != 127 {
            if filterMode == .images { filterMode = .all }
            query.append(ch); selected = 0; refresh()
        }
        return true
    }

    func hide() { win?.orderOut(nil); NSApp.hide(nil) }

    func choose(_ c: Clip, target: PasteTarget) {
        if target == .openURL,
           let normalized = c.detectedURL?.normalized,
           let url = URL(string: normalized) {
            win.orderOut(nil)
            NSWorkspace.shared.open(url)
            NSApp.hide(nil)
            return
        }
        let savedBundle = prevBundle
        let path = (CLIPS as NSString).appendingPathComponent(c.file)
        let pb = NSPasteboard.general
        pb.clearContents()
        if c.type == "image", let data = FileManager.default.contents(atPath: path) {
            if let img = NSImage(data: data) { pb.writeObjects([img]) } else { pb.setData(data, forType: .png) }
        } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            pb.setString(clipboardPasteText(text), forType: .string)
        }
        // Stamp AFTER writing, with the exact resulting changeCount — an exact match,
        // not a timing guess, so Clipboard History reliably attributes this re-paste
        // to com.claudecommand (in BLOCK_BUNDLES) and never re-records it as a new clip.
        if let d = try? JSONSerialization.data(withJSONObject:
            ["bundle": "com.claudecommand", "ts": Date().timeIntervalSince1970, "cc": pb.changeCount]) {
            try? d.write(to: URL(fileURLWithPath: COPY_SOURCE_PATH))
        }
        isPicking = true
        win.orderOut(nil)  // hides window; windowDidResignKey fires but isPicking suppresses hide()
        isPicking = false

        // Use Launch Services (open -b) to activate target — reliable on all macOS
        // versions, no need to be the frontmost app, no deprecated APIs.
        func openBundle(_ b: String) {
            guard !b.isEmpty else { return }
            let t = Process(); t.launchPath = "/usr/bin/open"; t.arguments = ["-b", b]
            try? t.run()
        }

        // Poll on background thread until bundle is frontmost, then hop to main.
        // 30ms minimum lets the picker window fully dismiss before we check.
        // Polls every 15ms, caps at ~510ms total. Fires as soon as app is active
        // — typically 50-150ms vs the old flat 300ms delay.
        func whenActive(_ bundle: String, then work: @escaping () -> Void) {
            guard !bundle.isEmpty else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { work() }
                return
            }
            DispatchQueue.global(qos: .userInteractive).async {
                usleep(30_000)  // min 30ms: window dismiss + focus handoff
                for _ in 0..<32 {
                    if NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
                        .first?.isActive == true { break }
                    usleep(15_000)
                }
                DispatchQueue.main.async { work() }
            }
        }

        switch target {
        case .prev:
            openBundle(savedBundle)
            whenActive(savedBundle) {
                postKey(kV, cmd: true)
                NSApp.hide(nil)
            }
        case .claude:
            let bundle = selectedProviderBundle()
            openBundle(bundle)
            whenActive(bundle) {
                if focusedElementIsEditable() { postKey(kV, cmd: true) }
                else { notify("Assistant input not ready", "Open a session and try Clipboard History again.") }
                NSApp.hide(nil)
            }
        case .claudeNew:
            let provider = selectedProvider()
            let bundle = provider.appBundleIdentifier
            if provider == .codex, let codex = codexExecutablePath() {
                let p = Process(); p.executableURL = URL(fileURLWithPath: codex)
                p.arguments = ["app", configuredCodexWorkspace()]
                try? p.run()
            } else { openBundle(bundle) }
            whenActive(bundle) {
                postKey(45, cmd: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if focusedElementIsEditable() { postKey(kV, cmd: true) }
                    else { notify("Assistant input not ready", "Open a session and try Clipboard History again.") }
                    NSApp.hide(nil)
                }
            }
        case .openURL:
            break
        }
    }
}

let picker = ClipPicker()

// ---- Carbon global hotkeys -------------------------------------------------
struct HK { let action: String; let keycode: UInt32; let mods: UInt32 }

func loadHotkeys() -> [HK] {
    let clipboardEnabled = UserDefaults.standard.bool(forKey: "cliphistoryEnabled")
    let dictationEnabled = UserDefaults.standard.bool(forKey: VoiceSettingsKeys.dictationEnabled)
    return loadBindings().flatMap { binding -> [HK] in
        guard binding.enabled,
              voiceShortcutRegistrationAllowed(
                  isVoice: isBuiltInVoiceAction(binding.action),
                  dictationEnabled: dictationEnabled
              ),
              binding.action != "cliphistory" || clipboardEnabled else { return [] }
        return binding.shortcuts.map { HK(action: binding.action, keycode: $0.keycode, mods: $0.mods) }
    }
}

var hotkeyActions: [UInt32: String] = [:]
var hotkeyKeycodes: [UInt32: UInt32] = [:]   // hotkey ID → Carbon keycode for PTT polling
var hotkeyShortcuts: [UInt32: HotkeyShortcut] = [:]
var eventTapVoiceShortcuts: [HotkeyShortcut] = []
var hotkeyRefs: [EventHotKeyRef?] = []

private final class CarbonVoiceRouteProbeBox: @unchecked Sendable {
    let hotkeyID: UInt32
    private let lock = NSLock()
    private var deliveredKinds: Set<UInt32> = []
    let delivery = DispatchSemaphore(value: 0)

    init(hotkeyID: UInt32) {
        self.hotkeyID = hotkeyID
    }

    func record(kind: UInt32) {
        lock.lock()
        let inserted = deliveredKinds.insert(kind).inserted
        lock.unlock()
        if inserted { delivery.signal() }
    }

    func deliveredCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveredKinds.count
    }
}

private let _carbonVoiceRouteProbeLock = NSLock()
private var _activeCarbonVoiceRouteProbe: CarbonVoiceRouteProbeBox?

private struct HotkeyRegistrationSnapshot {
    var expectedCarbonRegistrations = 0
    var actualCarbonRegistrations = 0
    var registrationFailures = 0
    var expectedEventTapAliases = 0
    var configuredVoiceAliases = 0
    var expectedCarbonVoiceAliases = 0
    var expectedEventTapVoiceAliases = 0
}

private var _hotkeyRegistrationSnapshot = HotkeyRegistrationSnapshot()

let hotKeyHandler: EventHandlerUPP = { (_, event, _) -> OSStatus in
    var hkID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)

    let kind = GetEventKind(event)

    let action = hotkeyActions[hkID.id]
    let isVoice = action.map(isVoiceHotkeyAction) ?? false
    _carbonVoiceRouteProbeLock.lock()
    let routeProbe = _activeCarbonVoiceRouteProbe
    _carbonVoiceRouteProbeLock.unlock()
    if isVoice, routeProbe?.hotkeyID == hkID.id {
        routeProbe?.record(kind: kind)
        return noErr
    }

    // kEventHotKeyReleased: clean PTT release via Carbon event (no polling needed).
    if kind == UInt32(kEventHotKeyReleased) {
        _carbonDictHeld.remove(hkID.id)
        if let action {
            if isVoice {
                Task { @MainActor in
                    appendLog("[hotkeys] voice release action=\(action) id=\(hkID.id) triggerMode=\(_dictTrigger.mode.rawValue) overlay=\(DictationOverlay.shared.isVisible) phase=\(recorder.state.rawValue)")
                    releaseDictationTrigger()
                }
            }
        }
        return noErr
    }

    if let action {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if action == "cliphistory" {
            DispatchQueue.main.async { if picker.isVisible { picker.hide() } else { picker.show(prev: front) } }
        } else if action == "settings" {
            DispatchQueue.main.async { settingsWindow.show(tab: .setup) }
        } else if isBuiltInVoiceAction(action) {
            // Suppress Carbon key-repeat: kEventHotKeyPressed fires on every repeat.
            // Only act on the first press; kEventHotKeyReleased clears the held state.
            if _carbonDictHeld.contains(hkID.id) { return noErr }
            _carbonDictHeld.insert(hkID.id)
            let m: DictMode = dictMode(forBuiltInVoiceAction: action)
            Task { @MainActor in
                appendLog("[hotkeys] voice press action=\(action) id=\(hkID.id) triggerMode=\(_dictTrigger.mode.rawValue) overlay=\(DictationOverlay.shared.isVisible) phase=\(recorder.state.rawValue)")
                triggerDictation(mode: m, keycode: nil, pollForRelease: false)
            }
        } else if let (ca, trig) = resolveCustomHotkeyTrigger(action) {
            if trig.kind == .voice {
                // Same press/hold/double-tap trigger as the built-in Dictate actions,
                // just feeding the transcript into this custom action instead of
                // pasting/sending it directly (see DictationOverlay.dispatchCustomAction).
                if _carbonDictHeld.contains(hkID.id) { return noErr }
                _carbonDictHeld.insert(hkID.id)
                Task { @MainActor in
                    triggerDictation(mode: .customAction(actionID: ca.id, triggerID: trig.id),
                                     keycode: nil,
                                     pollForRelease: false)
                }
                return noErr
            }
            if trig.kind == .popup {
                DispatchQueue.main.async { CustomActionTextEntryPanel.shared.show(for: ca, trigger: trig) }
                return noErr
            }
            let sel = trig.kind == .screenshot ? "" : captureOrClipboard()
            let delivery = ca.effectiveDelivery(for: trig)
            if delivery == .background {
                DispatchQueue.global().async { runCustomHandoff(ca, trigger: trig, capturedText: sel) }
            } else {
                let dest = ca.effectiveDestination(for: trig).envValue
                let provider = ca.effectiveProvider(for: trig, default: selectedProvider())
                DispatchQueue.global().async {
                    runWorker(trig.kind == .screenshot ? "customshot" : "custom", source: front, captured: sel,
                              customPrompt: ca.prompt, customSubmit: ca.autoSubmit(for: trig),
                              customSession: delivery.sessionMode, customIncludeSource: ca.shouldIncludeSource(for: trig),
                              destination: dest, provider: provider)
                }
            }
        } else {
            // Capture selection NOW (main thread, source app still focused)
            // before async dispatch; worker uses CAPTURED_TEXT, skips socket roundtrip.
            let sel = action.hasPrefix("shot") ? "" : captureSelectionSync()
            DispatchQueue.global().async { dispatchBuiltInAction(action, source: front, captured: sel) }
        }
    }
    return noErr
}

func installHotkeys() {
    var specs = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, specs.count, &specs, nil, nil)
    registerFromConfig()
}

// (Re)register every hotkey from CFG. Safe to call repeatedly — the Shortcuts
// editor calls this in-process after a rebind, so no agent restart is needed.
func registerFromConfig() {
    for ref in hotkeyRefs { if let r = ref { UnregisterEventHotKey(r) } }
    hotkeyRefs.removeAll()
    hotkeyActions.removeAll()
    hotkeyKeycodes.removeAll()
    hotkeyShortcuts.removeAll()
    eventTapVoiceShortcuts.removeAll()
    _hotkeyRegistrationSnapshot = HotkeyRegistrationSnapshot()
    let dictationEnabled = UserDefaults.standard.bool(forKey: VoiceSettingsKeys.dictationEnabled)
    let sig = OSType(0x434D4447) // 'CMDG'
    for (i, hk) in loadHotkeys().enumerated() {
        guard hk.keycode != 0 else { continue }  // keycode 0 = 'A' key; 0 means unbound
        let isVoice = isBuiltInVoiceAction(hk.action)
        if isVoice { _hotkeyRegistrationSnapshot.configuredVoiceAliases += 1 }
        // HID tap owns every modifier chord plus media voice keys. Carbon owns ordinary keys
        // like external-keyboard Home, which is more reliable for Kinesis keyboards.
        if eventTapOwnsShortcut(keycode: hk.keycode, isVoice: isVoice) {
            _hotkeyRegistrationSnapshot.expectedEventTapAliases += 1
            if isVoice {
                _hotkeyRegistrationSnapshot.expectedEventTapVoiceAliases += 1
                eventTapVoiceShortcuts.append(HotkeyShortcut(keycode: hk.keycode, mods: hk.mods))
            }
            continue
        }
        _hotkeyRegistrationSnapshot.expectedCarbonRegistrations += 1
        if isVoice { _hotkeyRegistrationSnapshot.expectedCarbonVoiceAliases += 1 }
        let hkID = UInt32(i + 1)
        let id = EventHotKeyID(signature: sig, id: hkID)
        hotkeyActions[hkID] = hk.action
        hotkeyKeycodes[hkID] = hk.keycode
        hotkeyShortcuts[hkID] = HotkeyShortcut(keycode: hk.keycode, mods: hk.mods)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hk.keycode, hk.mods, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotkeyRefs.append(ref)
            _hotkeyRegistrationSnapshot.actualCarbonRegistrations += 1
            if isVoice {
                appendLog("[hotkeys] registered voice action=\(hk.action) keycode=\(hk.keycode) mods=\(hk.mods) via carbon")
            }
        } else {
            _hotkeyRegistrationSnapshot.registrationFailures += 1
            appendLog("[hotkeys] RegisterEventHotKey failed action=\(hk.action) keycode=\(hk.keycode) mods=\(hk.mods) status=\(status)")
            hotkeyActions.removeValue(forKey: hkID)
            hotkeyKeycodes.removeValue(forKey: hkID)
            hotkeyShortcuts.removeValue(forKey: hkID)
        }
    }
    // Custom action aliases each receive their own registration and route back
    // to the same owning trigger.
    var triggerSlot = 0
    for ca in loadCustomActions() where ca.enabled {
        for trig in ca.triggers where trig.enabled {
            guard voiceShortcutRegistrationAllowed(isVoice: trig.kind == .voice,
                                                     dictationEnabled: dictationEnabled) else { continue }
            for shortcut in trig.shortcuts {
                guard shortcut.keycode != 0 else { continue }
                let isVoice = trig.kind == .voice
                if isVoice { _hotkeyRegistrationSnapshot.configuredVoiceAliases += 1 }
                if eventTapOwnsShortcut(keycode: shortcut.keycode, isVoice: isVoice) {
                    _hotkeyRegistrationSnapshot.expectedEventTapAliases += 1
                    if isVoice {
                        _hotkeyRegistrationSnapshot.expectedEventTapVoiceAliases += 1
                        eventTapVoiceShortcuts.append(shortcut)
                    }
                    continue
                }
                _hotkeyRegistrationSnapshot.expectedCarbonRegistrations += 1
                if isVoice { _hotkeyRegistrationSnapshot.expectedCarbonVoiceAliases += 1 }
                let hkID = UInt32(100 + triggerSlot)
                triggerSlot += 1
                let id = EventHotKeyID(signature: sig, id: hkID)
                hotkeyActions[hkID] = ca.actionID(for: trig)
                hotkeyKeycodes[hkID] = shortcut.keycode
                hotkeyShortcuts[hkID] = shortcut
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(shortcut.keycode, shortcut.mods, id, GetApplicationEventTarget(), 0, &ref)
                if status == noErr {
                    hotkeyRefs.append(ref)
                    _hotkeyRegistrationSnapshot.actualCarbonRegistrations += 1
                    if isVoice {
                        appendLog("[hotkeys] registered custom voice action=\(ca.name) keycode=\(shortcut.keycode) mods=\(shortcut.mods) via carbon")
                    }
                } else {
                    _hotkeyRegistrationSnapshot.registrationFailures += 1
                    appendLog("[hotkeys] RegisterEventHotKey failed custom=\(ca.name) trigger=\(trig.kind.rawValue) keycode=\(shortcut.keycode) mods=\(shortcut.mods) status=\(status)")
                    hotkeyActions.removeValue(forKey: hkID)
                    hotkeyKeycodes.removeValue(forKey: hkID)
                    hotkeyShortcuts.removeValue(forKey: hkID)
                }
            }
        }
    }
    appendLog("[hotkeys] registration health carbon=\(_hotkeyRegistrationSnapshot.actualCarbonRegistrations)/\(_hotkeyRegistrationSnapshot.expectedCarbonRegistrations) eventTapAliases=\(_hotkeyRegistrationSnapshot.expectedEventTapAliases) voiceAliases=\(_hotkeyRegistrationSnapshot.configuredVoiceAliases) failures=\(_hotkeyRegistrationSnapshot.registrationFailures)")
}

func reregisterHotkeys() { registerFromConfig() }

// Temporarily drop all global hotkeys (so recording a rebind in the Shortcuts
// editor doesn't also trigger the action that combo is currently bound to).
func unregisterAllHotkeys() {
    for ref in hotkeyRefs { if let r = ref { UnregisterEventHotKey(r) } }
    hotkeyRefs.removeAll()
    hotkeyActions.removeAll()
    _hotkeyRegistrationSnapshot.actualCarbonRegistrations = 0
}

// ---- Media-key intercept (F7/F8/F9 = prev/play/next) ----------------------
// Carbon RegisterEventHotKey never sees these keys when macOS is in media-key
// mode (the default). We tap at the HID level, check our own hotkey config,
// and fire the action while swallowing the event so Spotify etc. don't also see it.

// NX media key type → Carbon keycode for the same physical key.
let MEDIA_TO_CARBON: [Int: UInt32] = [
    4: 63,     // Fn/Globe on newer Mac keyboards
    16: 100,   // NX_KEYTYPE_PLAY      → F8
    17: 101,   // NX_KEYTYPE_NEXT      → F9
    18: 98,    // NX_KEYTYPE_PREVIOUS  → F7 (some Macs)
    19: 101,   // NX_KEYTYPE_FAST      → F9 (some Macs)
    20: 98,    // NX_KEYTYPE_REWIND    → F7 (some Macs)
]

private var _mediaEventTap: CFMachPort?
private var _mediaHookRetryScheduled = false
private var _mediaHookWaitingForAccessibility = false
private let HOTKEY_EVENT_PROBE_PREFIX: Int64 = 0x434D000000000000 // "CM" + random payload
private let VOICE_DISPATCH_EVENT_PROBE_PREFIX: Int64 = 0x434E000000000000 // "CN" + random payload
private let VOICE_ROUTE_EVENT_PROBE_PREFIX: Int64 = 0x434F000000000000 // "CO" + random payload
private let HOTKEY_EVENT_PROBE_MASK = Int64(bitPattern: 0xFFFF000000000000)
private let VOICE_ROUTE_PRESS_KIND: UInt32 = 1
private let VOICE_ROUTE_RELEASE_KIND: UInt32 = 2

private final class HotkeyEventProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var deliveredEvents = 0
    let marker: Int64
    let delivery = DispatchSemaphore(value: 0)

    init(marker: Int64) {
        self.marker = marker
    }

    func recordDelivery() {
        lock.lock()
        deliveredEvents += 1
        lock.unlock()
        delivery.signal()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveredEvents
    }
}

private let _hotkeyEventProbeLock = NSLock()
private var _activeHotkeyEventProbe: HotkeyEventProbeBox?
private var _activeVoiceDispatchEventProbe: HotkeyEventProbeBox?

private final class EventTapVoiceRouteProbeBox: @unchecked Sendable {
    let marker: Int64
    let shortcut: HotkeyShortcut
    private let lock = NSLock()
    private var deliveredKinds: Set<UInt32> = []
    let delivery = DispatchSemaphore(value: 0)

    init(marker: Int64, shortcut: HotkeyShortcut) {
        self.marker = marker
        self.shortcut = shortcut
    }

    func record(kind: UInt32) {
        lock.lock()
        let inserted = deliveredKinds.insert(kind).inserted
        lock.unlock()
        if inserted { delivery.signal() }
    }

    func deliveredCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveredKinds.count
    }
}

private var _activeEventTapVoiceRouteProbe: EventTapVoiceRouteProbeBox?

private enum HotkeyProbeDisposition: Equatable {
    case none
    case swallow
    case voiceDispatch
    case voiceRoute
}

private func hotkeyProbeDisposition(_ event: CGEvent) -> HotkeyProbeDisposition {
    let marker = event.getIntegerValueField(.eventSourceUserData)
    let prefix = marker & HOTKEY_EVENT_PROBE_MASK
    guard prefix == HOTKEY_EVENT_PROBE_PREFIX ||
          prefix == VOICE_DISPATCH_EVENT_PROBE_PREFIX ||
          prefix == VOICE_ROUTE_EVENT_PROBE_PREFIX else {
        return .none
    }
    _hotkeyEventProbeLock.lock()
    if prefix == VOICE_ROUTE_EVENT_PROBE_PREFIX {
        let routeProbe = _activeEventTapVoiceRouteProbe
        _hotkeyEventProbeLock.unlock()
        return routeProbe?.marker == marker ? .voiceRoute : .swallow
    }
    let probe = prefix == HOTKEY_EVENT_PROBE_PREFIX ? _activeHotkeyEventProbe : _activeVoiceDispatchEventProbe
    _hotkeyEventProbeLock.unlock()
    if probe?.marker == marker { probe?.recordDelivery() }
    if prefix == VOICE_DISPATCH_EVENT_PROBE_PREFIX, probe?.marker == marker {
        return .voiceDispatch
    }
    return .swallow
}

private func recordEventTapVoiceRoute(
    keycode: UInt32,
    mods: UInt32,
    kind: UInt32
) -> Bool {
    _hotkeyEventProbeLock.lock()
    let probe = _activeEventTapVoiceRouteProbe
    _hotkeyEventProbeLock.unlock()
    guard probe?.shortcut == HotkeyShortcut(keycode: keycode, mods: mods),
          voiceHotkeyTarget(keycode: keycode, mods: mods) != nil else {
        return false
    }
    probe?.record(kind: kind)
    return true
}
// NX_SYSDEFINED events fire repeating isDown=true while held (no autorepeat flag).
// Track held state per keyCode to swallow repeats without breaking double-tap detection.
private var _nxHeld: [Int: Bool] = [:]
private var _voiceHeldKeycodes: Set<UInt32> = []

private enum VoiceHotkeyTarget {
    case builtIn(DictMode)
    case custom(actionID: String, triggerID: String)
}

private func isBuiltInVoiceAction(_ action: String) -> Bool {
    action == "dictate" || action == "dictateadd" || action == "dictateadd2"
}

private func resolveCustomHotkeyTrigger(_ action: String) -> (CustomAction, ActionTrigger)? {
    guard let (actionID, triggerID) = parseTriggerActionID(action),
          let customAction = loadCustomActions().first(where: { $0.id == actionID }),
          let trigger = customAction.triggers.first(where: { $0.id == triggerID }) else {
        return nil
    }
    return (customAction, trigger)
}

private func isVoiceHotkeyAction(_ action: String) -> Bool {
    isBuiltInVoiceAction(action) || resolveCustomHotkeyTrigger(action)?.1.kind == .voice
}

private func dictMode(forBuiltInVoiceAction action: String) -> DictMode {
    if action == "dictate" { return .insert }
    if action == "dictateadd2" { return .claude2 }
    return .claude
}

private func voiceHotkeyTarget(keycode: UInt32, mods: UInt32) -> VoiceHotkeyTarget? {
    guard UserDefaults.standard.bool(forKey: VoiceSettingsKeys.dictationEnabled) else { return nil }
    if let hk = loadHotkeys().first(where: { $0.keycode == keycode && $0.mods == mods && isBuiltInVoiceAction($0.action) }) {
        return .builtIn(dictMode(forBuiltInVoiceAction: hk.action))
    }
    if let (ca, trig) = triggerMatching(keycode: keycode, mods: mods), trig.kind == .voice {
        return .custom(actionID: ca.id, triggerID: trig.id)
    }
    return nil
}

@MainActor
private func triggerVoiceHotkey(_ target: VoiceHotkeyTarget, keycode: CGKeyCode) {
    appendLog("[dictation] trigger request target=\(String(describing: target)) keycode=\(keycode) triggerMode=\(_dictTrigger.mode.rawValue) overlay=\(DictationOverlay.shared.isVisible) phase=\(recorder.state.rawValue)")
    switch target {
    case .builtIn(let mode):
        triggerDictation(mode: mode, keycode: keycode, pollForRelease: false)
    case .custom(let actionID, let triggerID):
        triggerDictation(mode: .customAction(actionID: actionID, triggerID: triggerID),
                         keycode: keycode, pollForRelease: false)
    }
}

private func physicalModifierMask(fallback flags: NSEvent.ModifierFlags = []) -> UInt32 {
    var cm: UInt32 = 0
    if flags.contains(.command) ||
        CGEventSource.keyState(.hidSystemState, key: 55) ||
        CGEventSource.keyState(.hidSystemState, key: 54) { cm |= 256 }
    if flags.contains(.shift) ||
        CGEventSource.keyState(.hidSystemState, key: 56) ||
        CGEventSource.keyState(.hidSystemState, key: 60) { cm |= 512 }
    if flags.contains(.option) ||
        CGEventSource.keyState(.hidSystemState, key: 58) ||
        CGEventSource.keyState(.hidSystemState, key: 61) { cm |= 2048 }
    if flags.contains(.control) ||
        CGEventSource.keyState(.hidSystemState, key: 59) ||
        CGEventSource.keyState(.hidSystemState, key: 62) { cm |= 4096 }
    return cm
}

private func physicalModifierMask(cgFlags f: CGEventFlags) -> UInt32 {
    var cm = physicalModifierMask()
    if f.contains(.maskCommand) { cm |= 256 }
    if f.contains(.maskShift) { cm |= 512 }
    if f.contains(.maskAlternate) { cm |= 2048 }
    if f.contains(.maskControl) { cm |= 4096 }
    return cm
}

private func isModifierKeyDown(keycode: UInt32, flags: CGEventFlags) -> Bool {
    switch keycode {
    case 54, 55: return flags.contains(.maskCommand) || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keycode))
    case 56, 60: return flags.contains(.maskShift) || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keycode))
    case 58, 61: return flags.contains(.maskAlternate) || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keycode))
    case 59, 62: return flags.contains(.maskControl) || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keycode))
    case 63: return flags.contains(.maskSecondaryFn) || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keycode))
    default: return false
    }
}

private func releaseVoiceHotkey(keycode: UInt32) {
    _voiceHeldKeycodes.remove(keycode)
    appendLog("[eventTap] voice up kc=\(keycode)")
    DispatchQueue.main.async {
        Task { @MainActor in
            appendLog("[dictation] release request keycode=\(keycode) triggerMode=\(_dictTrigger.mode.rawValue) overlay=\(DictationOverlay.shared.isVisible) phase=\(recorder.state.rawValue)")
            releaseDictationTrigger()
        }
    }
}

// ---- Dictation trigger state machine (matches DictationLab v2) ----------------
// Single tap → PTT (hold to talk; CGEventSource poll releases on key-up)
// Quick tap then second tap → lock (hands-free; keep recording until next tap)
// Tap while locked → stop + paste
private var _dictTrigger = DictationTriggerCoordinator()
private var _dictPTTimer: Timer? = nil
private var _dictDeferredStopTimer: Timer? = nil
private var _carbonDictHeld: Set<UInt32> = []   // tracks held Carbon hotkey IDs; suppresses key-repeat

@MainActor
func resetDictTrigMode() {
    _dictPTTimer?.invalidate(); _dictPTTimer = nil
    _dictDeferredStopTimer?.invalidate(); _dictDeferredStopTimer = nil
    _dictTrigger.reset()
}

@MainActor
private func releaseDictationTrigger(at now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
    _dictPTTimer?.invalidate(); _dictPTTimer = nil
    let action = _dictTrigger.release(at: now)
    appendLog("[dictation] release transition action=\(String(describing: action)) triggerMode=\(_dictTrigger.mode.rawValue) phase=\(recorder.state.rawValue)")

    switch action {
    case .deferStop(let seconds):
        _dictDeferredStopTimer?.invalidate()
        _dictDeferredStopTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { timer in
            MainActor.assumeIsolated {
                timer.invalidate()
                _dictDeferredStopTimer = nil
                let deferredAction = _dictTrigger.deferredStopFired()
                appendLog("[dictation] deferred release action=\(String(describing: deferredAction)) triggerMode=\(_dictTrigger.mode.rawValue) phase=\(recorder.state.rawValue)")
                if deferredAction == .stopRecording, DictationOverlay.shared.isVisible {
                    DictationOverlay.shared.stopRecording()
                }
            }
        }
    case .stopRecording:
        _dictDeferredStopTimer?.invalidate(); _dictDeferredStopTimer = nil
        if DictationOverlay.shared.isVisible { DictationOverlay.shared.stopRecording() }
    case .none:
        break
    case .startRecording, .lockRecording:
        appendLog("[dictation] unexpected release action=\(String(describing: action))")
    }
}

@MainActor
func triggerDictation(mode: DictMode, keycode: CGKeyCode?, pollForRelease: Bool = true) {
    let healthAction = dictationTriggerHealthAction(
        triggerIsIdle: _dictTrigger.mode == .idle,
        overlayVisible: DictationOverlay.shared.isVisible,
        capturePhase: recorder.state
    )
    switch healthAction {
    case .proceed:
        break
    case .resetStaleTrigger:
        appendLog("[dictation] reconciled stale trigger mode=\(_dictTrigger.mode.rawValue) phase=\(recorder.state.rawValue)")
        resetDictTrigMode()
    case .resetStaleOverlay:
        appendLog("[dictation] reconciled stale overlay phase=\(recorder.state.rawValue)")
        DictationOverlay.shared.hide()
    case .waitForFinishing:
        appendLog("[dictation] trigger blocked while previous session finishes")
        DictationOverlay.shared.showUnavailable(
            title: "Previous dictation is finishing",
            detail: "Stop speaking until your transcript appears, then hold the shortcut again."
        )
        return
    }

    let action = _dictTrigger.press(at: Date().timeIntervalSinceReferenceDate)
    appendLog("[dictation] press transition action=\(String(describing: action)) triggerMode=\(_dictTrigger.mode.rawValue) phase=\(recorder.state.rawValue)")
    switch action {
    case .startRecording:
        if !DictationOverlay.shared.isVisible {
            guard DictationOverlay.shared.show(mode: mode) else {
                resetDictTrigMode()
                return
            }
        }
        guard pollForRelease, let keycode else { return }
        _dictPTTimer?.invalidate()
        _dictPTTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard _dictTrigger.mode == .pushToTalk else { timer.invalidate(); return }
                if !CGEventSource.keyState(.hidSystemState, key: keycode) {
                    timer.invalidate()
                    releaseDictationTrigger()
                }
            }
        }
    case .lockRecording:
        _dictPTTimer?.invalidate(); _dictPTTimer = nil
        _dictDeferredStopTimer?.invalidate(); _dictDeferredStopTimer = nil
    case .stopRecording:
        _dictPTTimer?.invalidate(); _dictPTTimer = nil
        _dictDeferredStopTimer?.invalidate(); _dictDeferredStopTimer = nil
        if DictationOverlay.shared.isVisible { DictationOverlay.shared.stopRecording() }
    case .none, .deferStop:
        appendLog("[dictation] unexpected press action=\(String(describing: action))")
    }
}

func fireMediaAction(_ carbon: UInt32, mods: UInt32 = 0) {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

    if let hk = loadHotkeys().first(where: { $0.keycode == carbon && $0.mods == mods }) {
        if hk.action.hasPrefix("shot") {
            let pg = runShell("/usr/bin/pgrep", ["-x", "screencapture"])
            if pg.code == 0 { _ = runShell("/usr/bin/pkill", ["-x", "screencapture"]); return }
        }
        if hk.action == "cliphistory" {
            if picker.isVisible { picker.hide() } else { picker.show(prev: front) }
        } else if hk.action == "settings" {
            settingsWindow.show(tab: .setup)
        } else if isBuiltInVoiceAction(hk.action) {
            Task { @MainActor in triggerDictation(mode: dictMode(forBuiltInVoiceAction: hk.action), keycode: CGKeyCode(carbon)) }
        } else {
            let sel = hk.action.hasPrefix("shot") ? "" : captureSelectionSync()
            DispatchQueue.global().async { dispatchBuiltInAction(hk.action, source: front, captured: sel) }
        }
    } else if let (ca, trig) = triggerMatching(keycode: carbon, mods: mods) {
        if trig.kind == .screenshot {
            let pg = runShell("/usr/bin/pgrep", ["-x", "screencapture"])
            if pg.code == 0 { _ = runShell("/usr/bin/pkill", ["-x", "screencapture"]); return }
        }
        if trig.kind == .voice {
            Task { @MainActor in triggerDictation(mode: .customAction(actionID: ca.id, triggerID: trig.id), keycode: CGKeyCode(carbon)) }
            return
        }
        if trig.kind == .popup {
            CustomActionTextEntryPanel.shared.show(for: ca, trigger: trig)
            return
        }
        let sel = trig.kind == .screenshot ? "" : captureOrClipboard()
        let delivery = ca.effectiveDelivery(for: trig)
        if delivery == .background {
            DispatchQueue.global().async { runCustomHandoff(ca, trigger: trig, capturedText: sel) }
        } else {
            let dest = ca.effectiveDestination(for: trig).envValue
            let provider = ca.effectiveProvider(for: trig, default: selectedProvider())
            DispatchQueue.global().async {
                runWorker(trig.kind == .screenshot ? "customshot" : "custom", source: front, captured: sel,
                          customPrompt: ca.prompt, customSubmit: ca.autoSubmit(for: trig),
                          customSession: delivery.sessionMode, customIncludeSource: ca.shouldIncludeSource(for: trig),
                          destination: dest, provider: provider)
            }
        }
    }
}

// Finds the (action, trigger) pair bound to a specific keycode/mods combo —
// used by both the media-key path above and hotkey-conflict checks below.
func triggerMatching(keycode: UInt32, mods: UInt32) -> (CustomAction, ActionTrigger)? {
    for ca in loadCustomActions() where ca.enabled {
        let shortcut = HotkeyShortcut(keycode: keycode, mods: mods)
        if let t = ca.triggers.first(where: { $0.enabled && $0.shortcuts.contains(shortcut) }) {
            return (ca, t)
        }
    }
    return nil
}

func startMediaKeyHook() {
    guard _mediaEventTap == nil else { return }
    guard AXIsProcessTrusted() else {
        if !_mediaHookWaitingForAccessibility {
            appendLog("[eventTap] waiting for Accessibility before installing media/voice hook")
            _mediaHookWaitingForAccessibility = true
        }
        scheduleMediaKeyHookRetry()
        return
    }
    _mediaHookWaitingForAccessibility = false
    // Intercept NX_SYSDEFINED (media-key mode) plus keyDown/keyUp. Voice hotkeys
    // use keyUp to end push-to-talk without depending on Carbon release events.
    let eventMask = CGEventMask((1 << 14) |
                                (1 << CGEventType.keyDown.rawValue) |
                                (1 << CGEventType.keyUp.rawValue) |
                                (1 << CGEventType.flagsChanged.rawValue))
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: eventMask,
        callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
            let probeDisposition = hotkeyProbeDisposition(event)
            if probeDisposition == .swallow { return nil }
            let isVoiceDispatchProbe = probeDisposition == .voiceDispatch
            let isVoiceRouteProbe = probeDisposition == .voiceRoute
            let passthrough = Unmanaged.passUnretained(event)

            // --- media-key mode (NX_SYSDEFINED subtype 8) ---
            if type.rawValue == 14,
               let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
                let keyCode = Int((ns.data1 & 0xFFFF0000) >> 16)
                let isDown  = ((Int(ns.data1) & 0xFF00) >> 8) == 0xA
                let cm = physicalModifierMask(fallback: ns.modifierFlags)
                if isVoiceRouteProbe {
                    if let carbon = MEDIA_TO_CARBON[keyCode] {
                        _ = recordEventTapVoiceRoute(
                            keycode: carbon,
                            mods: cm,
                            kind: isDown ? VOICE_ROUTE_PRESS_KIND : VOICE_ROUTE_RELEASE_KIND
                        )
                    }
                    return nil
                }
                if !isDown {
                    _nxHeld[keyCode] = false   // key released — next isDown is a genuine press
                    if MEDIA_TO_CARBON[keyCode] == 63, _voiceHeldKeycodes.contains(63) {
                        releaseVoiceHotkey(keycode: 63)
                        return nil
                    }
                    return passthrough
                }
                // Swallow NX key-repeat: isDown=true fires repeatedly while held.
                // wasHeld=true means key never released: repeat, not new tap.
                if _nxHeld[keyCode] == true { return nil }
                _nxHeld[keyCode] = true
                guard let carbon = MEDIA_TO_CARBON[keyCode] else { return passthrough }
                appendLog("[eventTap] NX keyCode=\(keyCode) carbon=\(carbon) mods=\(cm)")
                if settingsModel.recordingAction != nil {
                    DispatchQueue.main.async {
                        settingsModel.recordHardwareHotkey(keycode: carbon, mods: cm)
                    }
                    return nil
                }
                if carbon == 63, let voiceTarget = voiceHotkeyTarget(keycode: carbon, mods: cm) {
                    if _voiceHeldKeycodes.contains(carbon) { return nil }
                    appendLog("[eventTap] NX voice down kc=\(carbon)")
                    _voiceHeldKeycodes.insert(carbon)
                    DispatchQueue.main.async {
                        Task { @MainActor in triggerVoiceHotkey(voiceTarget, keycode: CGKeyCode(carbon)) }
                    }
                    return nil
                }
                let bound = loadHotkeys().contains { $0.keycode == carbon && $0.mods == cm }
                    || triggerMatching(keycode: carbon, mods: cm) != nil
                appendLog("[eventTap] NX bound=\(bound) carbon=\(carbon) mods=\(cm)")
                guard bound else { return passthrough }
                DispatchQueue.main.async { fireMediaAction(carbon, mods: cm) }
                return nil
            }

            // --- modifier and modifier-chord hotkeys (Command/Fn/etc.) ---
            if type == .flagsChanged {
                let kc = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                guard MODIFIER_ONLY_KEYCODES.contains(kc) else { return passthrough }
                // Local Settings monitor records modifier chords. Keep runtime
                // dispatch paused until recorder commits or cancels.
                if settingsModel.recordingAction != nil && !isVoiceDispatchProbe { return passthrough }
                let isDown = isModifierKeyDown(keycode: kc, flags: event.flags)
                let activeMods = physicalModifierMask(cgFlags: event.flags)
                let cm = chordModifiers(activeModifiers: activeMods, primaryKeycode: kc)
                if isVoiceRouteProbe {
                    _ = recordEventTapVoiceRoute(
                        keycode: kc,
                        mods: cm,
                        kind: isDown ? VOICE_ROUTE_PRESS_KIND : VOICE_ROUTE_RELEASE_KIND
                    )
                    return nil
                }
                if isDown {
                    let voiceTarget: VoiceHotkeyTarget? = isVoiceDispatchProbe
                        ? .builtIn(.diagnostic)
                        : voiceHotkeyTarget(keycode: kc, mods: cm)
                    if let voiceTarget {
                        if _voiceHeldKeycodes.contains(kc) { return nil }
                        appendLog("[eventTap] modifier voice down kc=\(kc) mods=\(cm)")
                        _voiceHeldKeycodes.insert(kc)
                        DispatchQueue.main.async {
                            Task { @MainActor in triggerVoiceHotkey(voiceTarget, keycode: CGKeyCode(kc)) }
                        }
                        return nil
                    }
                    let bound = loadHotkeys().contains { $0.keycode == kc && $0.mods == cm }
                        || triggerMatching(keycode: kc, mods: cm) != nil
                    guard bound else { return passthrough }
                    appendLog("[eventTap] modifier action down kc=\(kc) mods=\(cm)")
                    DispatchQueue.main.async { fireMediaAction(kc, mods: cm) }
                    return nil
                }
                if _voiceHeldKeycodes.contains(kc) {
                    releaseVoiceHotkey(keycode: kc)
                    return nil
                }
                return passthrough
            }

            // --- regular keyDown/keyUp path ---
            if type == .keyDown || type == .keyUp {
                let kc = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                let f  = event.flags
                let cm = physicalModifierMask(cgFlags: f)

                if isVoiceRouteProbe {
                    guard eventTapOwnsVoiceHotkey(keycode: kc) else { return nil }
                    _ = recordEventTapVoiceRoute(
                        keycode: kc,
                        mods: cm,
                        kind: type == .keyDown ? VOICE_ROUTE_PRESS_KIND : VOICE_ROUTE_RELEASE_KIND
                    )
                    return nil
                }

                // Capture copy/cut source at keypress time — fires BEFORE app writes to
                // clipboard, so Clipboard History sees the correct bundle.
                // NSEvent.addGlobalMonitorForEvents fires AFTER the write (too late).
                // Skip our own bundle so paste-ops don't overwrite a real copy source.
                if f.contains(.maskCommand) && (kc == 8 || kc == 7) {  // Cmd+C or Cmd+X
                    let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                    let key = kc == 8 ? "C" : "X"
                    appendLog("[eventTap] Cmd+\(key) bundle=\(bundle.isEmpty ? "(empty)" : bundle)")
                    if !bundle.isEmpty && bundle != "com.claudecommand" {
                        if let d = try? JSONSerialization.data(withJSONObject:
                            ["bundle": bundle, "ts": Date().timeIntervalSince1970]) {
                            try? d.write(to: URL(fileURLWithPath: COPY_SOURCE_PATH))
                            appendLog("[eventTap] wrote last_copy.json bundle=\(bundle)")
                        }
                    } else {
                        appendLog("[eventTap] skipped write (bundle empty or claudecommand)")
                    }
                    return passthrough  // never swallow Cmd+C/X
                }

                if type == .keyDown, MEDIA_KEYCODES.contains(kc), settingsModel.recordingAction != nil {
                    DispatchQueue.main.async {
                        settingsModel.recordHardwareHotkey(keycode: kc, mods: cm)
                    }
                    return nil
                }
                if type == .keyUp, _voiceHeldKeycodes.contains(kc) {
                    appendLog("[eventTap] voice up kc=\(kc) mods=\(cm)")
                    releaseVoiceHotkey(keycode: kc)
                    return nil
                }
                if type == .keyDown,
                   event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                   _voiceHeldKeycodes.contains(kc) {
                    return nil
                }
                let voiceTarget = isVoiceDispatchProbe
                    ? VoiceHotkeyTarget.builtIn(.diagnostic)
                    : voiceHotkeyTarget(keycode: kc, mods: cm)
                if eventTapOwnsVoiceHotkey(keycode: kc), let voiceTarget {
                    guard type == .keyDown else {
                        return isVoiceDispatchProbe ? nil : passthrough
                    }
                    if _voiceHeldKeycodes.contains(kc) { return nil }
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    guard !isRepeat else { return nil }
                    appendLog("[eventTap] voice down kc=\(kc) mods=\(cm)")
                    _voiceHeldKeycodes.insert(kc)
                    DispatchQueue.main.async {
                        Task { @MainActor in triggerVoiceHotkey(voiceTarget, keycode: CGKeyCode(kc)) }
                    }
                    return nil
                }

                guard type == .keyDown else { return passthrough }
                guard MEDIA_KEYCODES.contains(kc) else { return passthrough }
                // Skip key-repeat events — only fire on the initial key-down.
                // Without this, holding a bound key fires start→stop→start... rapidly.
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                guard !isRepeat else { return nil }  // swallow repeat but don't act
                let bound = loadHotkeys().contains { $0.keycode == kc && $0.mods == cm }
                    || triggerMatching(keycode: kc, mods: cm) != nil
                appendLog("[eventTap] keyDown kc=\(kc) mods=\(cm) bound=\(bound)")
                guard bound else { return passthrough }
                DispatchQueue.main.async { fireMediaAction(kc, mods: cm) }
                return nil
            }

            return passthrough
        }, userInfo: nil)
    else {
        appendLog("[eventTap] could not create media/voice hook; retrying")
        scheduleMediaKeyHookRetry()
        return
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    _mediaEventTap = tap
    appendLog("[eventTap] media/voice hook installed")
    // macOS auto-disables event taps that block. Re-enable every 5s so hotkeys survive.
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) { tapWatchdog() }
}

func scheduleMediaKeyHookRetry() {
    guard !_mediaHookRetryScheduled else { return }
    _mediaHookRetryScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        _mediaHookRetryScheduled = false
        guard _mediaEventTap == nil else { return }
        startMediaKeyHook()
    }
}

func tapWatchdog() {
    guard let tap = _mediaEventTap else { return }
    guard AXIsProcessTrusted() else {
        CGEvent.tapEnable(tap: tap, enable: false)
        _mediaEventTap = nil
        appendLog("[tapWatchdog] disabled media event tap because Accessibility is no longer trusted")
        scheduleMediaKeyHookRetry()
        return
    }
    if !CGEvent.tapIsEnabled(tap: tap) {
        CGEvent.tapEnable(tap: tap, enable: true)
        appendLog("[tapWatchdog] re-enabled media event tap")
    }
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) { tapWatchdog() }
}

// ---- Unix-socket keystroke + picker service --------------------------------
private final class DictationProbeResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: DictationCaptureProbeResult?
    private var cancelled = false

    func store(_ result: DictationCaptureProbeResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> DictationCaptureProbeResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class DictationInsertProbeResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var execution: DictationFinalDeliveryExecution?

    func store(_ execution: DictationFinalDeliveryExecution) {
        lock.lock()
        self.execution = execution
        lock.unlock()
    }

    func load() -> DictationFinalDeliveryExecution? {
        lock.lock()
        defer { lock.unlock() }
        return execution
    }
}

@MainActor
private struct InstalledPasteboardSnapshot {
    private struct Item {
        let values: [String: Data]
    }

    private let items: [Item]
    let isRestorable: Bool

    init(_ pasteboard: NSPasteboard) {
        var complete = true
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    complete = false
                    continue
                }
                values[type.rawValue] = data
            }
            return Item(values: values)
        }
        isRestorable = complete
    }

    func restore(to pasteboard: NSPasteboard) -> Bool {
        guard isRestorable else { return false }
        pasteboard.clearContents()
        guard !items.isEmpty else {
            return pasteboard.pasteboardItems?.isEmpty ?? true
        }
        let restored = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in snapshot.values {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        guard pasteboard.writeObjects(restored) else { return false }
        return matches(pasteboard)
    }

    private func matches(_ pasteboard: NSPasteboard) -> Bool {
        let current = pasteboard.pasteboardItems ?? []
        guard current.count == items.count else { return false }
        for (item, snapshot) in zip(current, items) {
            let currentTypes = Set(item.types.map(\.rawValue))
            guard currentTypes == Set(snapshot.values.keys) else { return false }
            for (rawType, expected) in snapshot.values {
                let type = NSPasteboard.PasteboardType(rawType)
                guard item.data(forType: type) == expected else { return false }
            }
        }
        return true
    }
}

@MainActor
private final class InstalledDictationInsertProbeHarness {
    let targetBundle: String
    let previousBundle: String
    private let pasteboardSnapshot: InstalledPasteboardSnapshot
    private let receiverURL: URL

    init?(targetBundle: String, receiverPath: String) {
        guard !targetBundle.isEmpty, !receiverPath.isEmpty else { return nil }
        self.targetBundle = targetBundle
        receiverURL = URL(fileURLWithPath: receiverPath)
        previousBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        pasteboardSnapshot = InstalledPasteboardSnapshot(.general)
        guard pasteboardSnapshot.isRestorable else { return nil }
    }

    func start(
        rawText: String,
        response: DictationInsertProbeResponseBox,
        completed: DispatchSemaphore
    ) {
        Task { @MainActor in
            let execution = await DictationOverlay.shared.runInstalledInsertDeliveryProbe(
                rawText: rawText,
                targetBundle: targetBundle
            )
            response.store(execution)
            completed.signal()
        }
    }

    func receiverContains(_ expected: String) -> Bool {
        guard let data = try? Data(contentsOf: receiverURL) else { return false }
        return String(decoding: data, as: UTF8.self) == expected
    }

    func finish() -> (clipboardRestored: Bool, previousAppRestored: Bool) {
        let pasteboard = NSPasteboard.general
        let restored = pasteboardSnapshot.restore(to: pasteboard)
        DictationOverlay.shared.stampClipboardSource(
            bundle: "com.claudecommand",
            cc: pasteboard.changeCount
        )

        var previousRestored = previousBundle.isEmpty || previousBundle == targetBundle
        if !previousRestored {
            activate(previousBundle)
            previousRestored = waitForActive(previousBundle)
        }
        return (restored, previousRestored)
    }
}

private func encodeDictationInsertProbeResult(_ result: DictationInsertProbeResult) -> String {
    guard let data = try? DictationInsertProbeCoding.encode(result) else {
        return #"{"ok":false,"status":"failed","failure":"Could not encode dictation insert probe result."}"#
    }
    return String(decoding: data, as: UTF8.self)
}

func runInstalledDictationInsertProbe(targetBundle: String, receiverPath: String) -> String {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let startedAt = Date()
    guard AXIsProcessTrusted() else {
        return encodeDictationInsertProbeResult(DictationInsertProbeResult(
            status: .accessibilityUnavailable,
            failure: "Accessibility is not trusted."
        ))
    }

    var harness: InstalledDictationInsertProbeHarness?
    DispatchQueue.main.sync {
        harness = InstalledDictationInsertProbeHarness(
            targetBundle: targetBundle,
            receiverPath: receiverPath
        )
    }
    guard let harness else {
        return encodeDictationInsertProbeResult(DictationInsertProbeResult(
            status: .receiverUnavailable,
            failure: "Could not connect to focused paste receiver or safely snapshot clipboard."
        ))
    }

    let rawText = "Command delivery probe preserves final words amber turbine"
    let response = DictationInsertProbeResponseBox()
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        harness.start(rawText: rawText, response: response, completed: completed)
    }

    let pipelineCompleted = completed.wait(timeout: .now() + 10) == .success
    let execution = response.load()
    var receiverMatched = false
    if pipelineCompleted, let expected = execution?.pipeline.processedText, !expected.isEmpty {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            DispatchQueue.main.sync { receiverMatched = harness.receiverContains(expected) }
            if receiverMatched { break }
            usleep(20_000)
        }
    }

    var cleanup = (clipboardRestored: false, previousAppRestored: false)
    DispatchQueue.main.sync { cleanup = harness.finish() }

    guard pipelineCompleted, let execution else {
        return encodeDictationInsertProbeResult(DictationInsertProbeResult(
            status: .failed,
            clipboardRestored: cleanup.clipboardRestored,
            previousAppRestored: cleanup.previousAppRestored,
            durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
            failure: "Production dictation delivery pipeline did not complete within ten seconds."
        ))
    }

    let pipeline = execution.pipeline
    let insert = execution.insert
    let status: DictationInsertProbeStatus
    let failure: String?
    if !pipeline.delivered || insert == nil {
        status = .pipelineSuppressed
        failure = "Production dictation delivery pipeline suppressed non-empty probe text."
    } else if insert?.clipboardWritten != true {
        status = .clipboardWriteFailed
        failure = "Production dictation delivery did not write processed text to clipboard."
    } else if insert?.targetActive != true {
        status = .targetInactive
        failure = "Command did not activate focused dictation paste receiver."
    } else if insert?.pasteEventPosted != true {
        status = .pasteEventFailed
        failure = "Production dictation delivery did not post Command-V to target process."
    } else if !receiverMatched {
        status = .pasteTimedOut
        failure = "Focused AppKit receiver did not receive exact processed transcript."
    } else if !cleanup.clipboardRestored {
        status = .clipboardRestoreFailed
        failure = "Dictation probe could not restore prior clipboard contents exactly."
    } else if !cleanup.previousAppRestored {
        status = .previousAppRestoreFailed
        failure = "Dictation probe could not restore previously focused app."
    } else {
        status = .passed
        failure = nil
    }

    appendLog("[dictation-probe] insert delivery status=\(status.rawValue) pipeline=\(pipeline.status.rawValue) receiverMatched=\(receiverMatched) clipboardRestored=\(cleanup.clipboardRestored)")
    return encodeDictationInsertProbeResult(DictationInsertProbeResult(
        status: status,
        pipelineStatus: pipeline.status.rawValue,
        rawCharacters: pipeline.rawText.count,
        processedCharacters: pipeline.processedText.count,
        clipboardWritten: insert?.clipboardWritten ?? false,
        targetActive: insert?.targetActive ?? false,
        pasteEventPosted: insert?.pasteEventPosted ?? false,
        receiverMatched: receiverMatched,
        clipboardRestored: cleanup.clipboardRestored,
        previousAppRestored: cleanup.previousAppRestored,
        durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
        failure: failure
    ))
}

func runInstalledDictationProbe() -> String {
    let response = DictationProbeResponseBox()
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        guard !response.isCancelled() else { return }
        recorder.runCaptureProbe { result in
            response.store(result)
            completed.signal()
        }
    }

    if completed.wait(timeout: .now() + 5) == .timedOut {
        response.cancel()
        response.store(DictationCaptureProbeResult(
            status: .timedOut,
            authorization: "unknown",
            failure: "Microphone probe did not complete within five seconds."
        ))
    }
    let result = response.load() ?? DictationCaptureProbeResult(
        status: .timedOut,
        authorization: "unknown",
        failure: "Microphone probe returned no result."
    )
    guard let data = try? DictationCaptureProbeCoding.encode(result) else {
        return #"{"ok":false,"status":"timedOut","failure":"Could not encode microphone probe result."}"#
    }
    return String(decoding: data, as: UTF8.self)
}

private struct DictationLifecycleRuntimeSnapshot {
    let modelReady: Bool
    let modelStatus: String
    let capturePhase: String
    let overlayVisible: Bool
    let capturedBuffers: Int
}

private func dictationLifecycleRuntimeSnapshot() -> DictationLifecycleRuntimeSnapshot {
    var snapshot: DictationLifecycleRuntimeSnapshot?
    DispatchQueue.main.sync {
        let modelReady: Bool
        let modelStatus: String
        switch recorder.modelStatus {
        case .ready:
            modelReady = true
            modelStatus = "ready"
        case .notDownloaded:
            modelReady = false
            modelStatus = "notDownloaded"
        case .downloading(let progress):
            modelReady = false
            modelStatus = "downloading:\(Int((progress * 100).rounded()))"
        case .error(let message):
            modelReady = false
            modelStatus = "error:\(message)"
        }
        snapshot = DictationLifecycleRuntimeSnapshot(
            modelReady: modelReady,
            modelStatus: modelStatus,
            capturePhase: recorder.state.rawValue,
            overlayVisible: DictationOverlay.shared.isVisible,
            capturedBuffers: recorder.capturedBufferCount
        )
    }
    return snapshot ?? DictationLifecycleRuntimeSnapshot(
        modelReady: false,
        modelStatus: "unknown",
        capturePhase: "unknown",
        overlayVisible: false,
        capturedBuffers: 0
    )
}

private func dictationCaptureResourceSnapshot() -> DictationCaptureResourceSnapshot {
    var snapshot: DictationCaptureResourceSnapshot?
    DispatchQueue.main.sync {
        snapshot = recorder.captureResourceSnapshot(
            overlayVisible: DictationOverlay.shared.isVisible
        )
    }
    return snapshot ?? DictationCaptureResourceSnapshot(
        capturePhase: "unknown",
        overlayVisible: true,
        captureStartupBegan: true,
        audioEngineActive: true,
        audioTapActive: true,
        streamTaskActive: true,
        audioContinuationActive: true,
        bufferFeederActive: true,
        managerActive: true,
        silenceTimerActive: true
    )
}

private func encodeDictationLifecycleProbeResult(_ result: DictationLifecycleProbeResult) -> String {
    guard let data = try? DictationLifecycleProbeCoding.encode(result) else {
        return #"{"ok":false,"status":"failed","failure":"Could not encode dictation lifecycle probe result."}"#
    }
    return String(decoding: data, as: UTF8.self)
}

private func makeDictationLifecycleProbeResult(
    status: DictationLifecycleProbeStatus,
    startedAt: Date,
    modelStatus: String,
    runtime: DictationLifecycleRuntimeSnapshot,
    health: DictationSessionHealth?,
    failure: String? = nil
) -> String {
    encodeDictationLifecycleProbeResult(DictationLifecycleProbeResult(
        status: status,
        sessionID: health?.sessionID ?? 0,
        modelStatus: modelStatus,
        capturePhase: runtime.capturePhase,
        terminalStage: health?.stage.rawValue ?? "none",
        capturedBuffers: health?.capturedBuffers ?? runtime.capturedBuffers,
        transcriptionUpdates: health?.transcriptionUpdates ?? 0,
        finalCharacters: health?.finalCharacters ?? 0,
        inputDevice: health?.inputDevice ?? "unknown",
        durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
        failure: failure ?? health?.failure
    ))
}

private func cancelInstalledDictationLifecycleProbe() {
    dispatchPrecondition(condition: .notOnQueue(.main))
    DispatchQueue.main.sync {
        recorder.cancel()
        DictationOverlay.shared.hide()
        resetDictTrigMode()
    }
}

func runInstalledDictationLifecycleProbe() -> String {
    let startedAt = Date()
    let initial = dictationLifecycleRuntimeSnapshot()
    guard initial.modelReady else {
        return makeDictationLifecycleProbeResult(
            status: .modelUnavailable,
            startedAt: startedAt,
            modelStatus: initial.modelStatus,
            runtime: initial,
            health: nil,
            failure: "Parakeet model is not ready."
        )
    }
    guard [DictationCapturePhase.idle.rawValue, DictationCapturePhase.error.rawValue]
            .contains(initial.capturePhase),
          !initial.overlayVisible else {
        return makeDictationLifecycleProbeResult(
            status: .recorderBusy,
            startedAt: startedAt,
            modelStatus: initial.modelStatus,
            runtime: initial,
            health: latestDictationSessionHealth(),
            failure: "Dictation recorder is busy before lifecycle probe."
        )
    }

    let previousHealth = latestDictationSessionHealth()
    appendLog("[dictation-probe] lifecycle requested previousSession=\(previousHealth?.sessionID ?? 0)")
    DispatchQueue.main.async {
        triggerDictation(mode: .diagnostic, keycode: nil, pollForRelease: false)
    }

    let captureDeadline = Date().addingTimeInterval(12)
    var probeHealth: DictationSessionHealth?
    while Date() < captureDeadline {
        let runtime = dictationLifecycleRuntimeSnapshot()
        if let health = latestDictationSessionHealth(),
           health.mode == String(describing: DictMode.diagnostic),
           health != previousHealth {
            probeHealth = health
            if health.stage == .failed || health.stage == .cancelled {
                cancelInstalledDictationLifecycleProbe()
                return makeDictationLifecycleProbeResult(
                    status: .failed,
                    startedAt: startedAt,
                    modelStatus: initial.modelStatus,
                    runtime: runtime,
                    health: health,
                    failure: health.failure ?? "Production dictation capture failed before release."
                )
            }
            if runtime.capturedBuffers >= 4 { break }
        }
        if runtime.capturePhase == DictationCapturePhase.error.rawValue {
            cancelInstalledDictationLifecycleProbe()
            return makeDictationLifecycleProbeResult(
                status: .failed,
                startedAt: startedAt,
                modelStatus: initial.modelStatus,
                runtime: runtime,
                health: probeHealth,
                failure: probeHealth?.failure ?? "Production recorder entered error state."
            )
        }
        usleep(50_000)
    }

    guard let capturedHealth = probeHealth else {
        let runtime = dictationLifecycleRuntimeSnapshot()
        cancelInstalledDictationLifecycleProbe()
        return makeDictationLifecycleProbeResult(
            status: .startRejected,
            startedAt: startedAt,
            modelStatus: initial.modelStatus,
            runtime: runtime,
            health: nil,
            failure: "Production dictation trigger did not create a session."
        )
    }
    guard dictationLifecycleRuntimeSnapshot().capturedBuffers >= 4 else {
        let runtime = dictationLifecycleRuntimeSnapshot()
        cancelInstalledDictationLifecycleProbe()
        return makeDictationLifecycleProbeResult(
            status: .captureTimedOut,
            startedAt: startedAt,
            modelStatus: initial.modelStatus,
            runtime: runtime,
            health: capturedHealth,
            failure: "Production dictation did not capture four audio buffers within 12 seconds."
        )
    }

    DispatchQueue.main.sync {
        releaseDictationTrigger()
    }

    let finishDeadline = Date().addingTimeInterval(15)
    while Date() < finishDeadline {
        let runtime = dictationLifecycleRuntimeSnapshot()
        if let health = latestDictationSessionHealth(), health.sessionID == capturedHealth.sessionID {
            probeHealth = health
            if health.stage == .failed || health.stage == .cancelled {
                cancelInstalledDictationLifecycleProbe()
                return makeDictationLifecycleProbeResult(
                    status: .failed,
                    startedAt: startedAt,
                    modelStatus: initial.modelStatus,
                    runtime: runtime,
                    health: health,
                    failure: health.failure ?? "Production dictation failed while finishing."
                )
            }
            if (health.stage == .completed || health.stage == .empty),
               runtime.capturePhase == DictationCapturePhase.idle.rawValue,
               !runtime.overlayVisible {
                appendLog("[dictation-probe] lifecycle passed \(health.diagnosticSummary)")
                return makeDictationLifecycleProbeResult(
                    status: .passed,
                    startedAt: startedAt,
                    modelStatus: initial.modelStatus,
                    runtime: runtime,
                    health: health
                )
            }
        }
        usleep(50_000)
    }

    let runtime = dictationLifecycleRuntimeSnapshot()
    cancelInstalledDictationLifecycleProbe()
    return makeDictationLifecycleProbeResult(
        status: .finishTimedOut,
        startedAt: startedAt,
        modelStatus: initial.modelStatus,
        runtime: runtime,
        health: probeHealth,
        failure: "Production dictation did not reach a clean terminal state within 15 seconds."
    )
}

private func encodeDictationRecoveryProbeResult(_ result: DictationRecoveryProbeResult) -> String {
    guard let data = try? DictationRecoveryProbeCoding.encode(result) else {
        return #"{"ok":false,"status":"failed","failure":"Could not encode dictation recovery probe result."}"#
    }
    return String(decoding: data, as: UTF8.self)
}

private func makeDictationRecoveryProbeResult(
    status: DictationRecoveryProbeStatus,
    startedAt: Date,
    injectedHealth: DictationSessionHealth? = nil,
    cleanup: DictationCaptureResourceSnapshot,
    recovery: DictationLifecycleProbeResult? = nil,
    failure: String? = nil
) -> String {
    encodeDictationRecoveryProbeResult(DictationRecoveryProbeResult(
        status: status,
        injectedSessionID: injectedHealth?.sessionID ?? 0,
        injectedBuffers: injectedHealth?.capturedBuffers ?? 0,
        injectedTerminalStage: injectedHealth?.stage.rawValue ?? "none",
        cleanup: cleanup,
        recovery: recovery,
        durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
        failure: failure
    ))
}

func runInstalledDictationRecoveryProbe() -> String {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let startedAt = Date()
    let initial = dictationLifecycleRuntimeSnapshot()
    let initialResources = dictationCaptureResourceSnapshot()
    guard initial.modelReady else {
        return makeDictationRecoveryProbeResult(
            status: .modelUnavailable,
            startedAt: startedAt,
            cleanup: initialResources,
            failure: "Parakeet model is not ready."
        )
    }
    guard [DictationCapturePhase.idle.rawValue, DictationCapturePhase.error.rawValue]
            .contains(initial.capturePhase),
          !initial.overlayVisible,
          initialResources.fullyReleased else {
        return makeDictationRecoveryProbeResult(
            status: .recorderBusy,
            startedAt: startedAt,
            cleanup: initialResources,
            failure: "Dictation recorder has active resources before recovery probe."
        )
    }

    let previousHealth = latestDictationSessionHealth()
    var armed = false
    DispatchQueue.main.sync {
        armed = recorder.armDiagnosticCaptureFailure(afterBuffers: 2)
        if armed {
            triggerDictation(mode: .diagnostic, keycode: nil, pollForRelease: false)
        }
    }
    guard armed else {
        return makeDictationRecoveryProbeResult(
            status: .recorderBusy,
            startedAt: startedAt,
            cleanup: dictationCaptureResourceSnapshot(),
            failure: "Could not arm diagnostic capture failure."
        )
    }

    let failureDeadline = Date().addingTimeInterval(12)
    var injectedHealth: DictationSessionHealth?
    while Date() < failureDeadline {
        if let health = latestDictationSessionHealth(),
           health.mode == String(describing: DictMode.diagnostic),
           health != previousHealth {
            injectedHealth = health
            if health.stage == .failed { break }
            if health.stage == .completed || health.stage == .empty || health.stage == .cancelled {
                cancelInstalledDictationLifecycleProbe()
                return makeDictationRecoveryProbeResult(
                    status: .failureNotObserved,
                    startedAt: startedAt,
                    injectedHealth: health,
                    cleanup: dictationCaptureResourceSnapshot(),
                    failure: "Injected capture failure did not reach failed terminal health."
                )
            }
        }
        usleep(50_000)
    }

    guard let failedHealth = injectedHealth,
          failedHealth.stage == .failed,
          failedHealth.capturedBuffers >= 2,
          failedHealth.failure == "diagnostic injected capture failure" else {
        cancelInstalledDictationLifecycleProbe()
        return makeDictationRecoveryProbeResult(
            status: .failureNotObserved,
            startedAt: startedAt,
            injectedHealth: injectedHealth,
            cleanup: dictationCaptureResourceSnapshot(),
            failure: "Injected failure was not observed after live microphone buffers."
        )
    }

    let cleanupDeadline = Date().addingTimeInterval(3)
    var cleanup = dictationCaptureResourceSnapshot()
    while Date() < cleanupDeadline, !cleanup.fullyReleased {
        usleep(50_000)
        cleanup = dictationCaptureResourceSnapshot()
    }
    guard cleanup.fullyReleased,
          cleanup.capturePhase == DictationCapturePhase.error.rawValue else {
        cancelInstalledDictationLifecycleProbe()
        return makeDictationRecoveryProbeResult(
            status: .cleanupTimedOut,
            startedAt: startedAt,
            injectedHealth: failedHealth,
            cleanup: cleanup,
            failure: "Capture resources remained active after injected failure."
        )
    }

    let recoveryJSON = runInstalledDictationLifecycleProbe()
    guard let recoveryData = recoveryJSON.data(using: .utf8),
          let recovery = try? DictationLifecycleProbeCoding.decode(recoveryData) else {
        return makeDictationRecoveryProbeResult(
            status: .failed,
            startedAt: startedAt,
            injectedHealth: failedHealth,
            cleanup: cleanup,
            failure: "Could not decode immediate retry result."
        )
    }
    guard recovery.ok else {
        return makeDictationRecoveryProbeResult(
            status: .recoveryFailed,
            startedAt: startedAt,
            injectedHealth: failedHealth,
            cleanup: cleanup,
            recovery: recovery,
            failure: recovery.failure ?? "Immediate production dictation retry failed."
        )
    }

    appendLog("[dictation-probe] recovery passed injectedSession=\(failedHealth.sessionID) retrySession=\(recovery.sessionID)")
    return makeDictationRecoveryProbeResult(
        status: .passed,
        startedAt: startedAt,
        injectedHealth: failedHealth,
        cleanup: cleanup,
        recovery: recovery
    )
}

private func encodeDictationWatchdogProbeResult(_ result: DictationWatchdogProbeResult) -> String {
    guard let data = try? DictationWatchdogProbeCoding.encode(result) else {
        return #"{"ok":false,"status":"failed","failure":"Could not encode dictation watchdog probe result."}"#
    }
    return String(decoding: data, as: UTF8.self)
}

private func dictationWatchdogCounts() -> (warnings: Int, resets: Int) {
    var counts = (warnings: 0, resets: 0)
    DispatchQueue.main.sync {
        counts = (
            warnings: DictationOverlay.shared.captureWatchdogWarningCount,
            resets: DictationOverlay.shared.captureWatchdogRecoveryCount
        )
    }
    return counts
}

private func makeDictationWatchdogProbeResult(
    status: DictationWatchdogProbeStatus,
    scenario: DictationWatchdogProbeScenario = .startup,
    startedAt: Date,
    stalledHealth: DictationSessionHealth? = nil,
    warningCount: Int = 0,
    resetCount: Int = 0,
    releasedDuringStartup: Bool = false,
    cleanup: DictationCaptureResourceSnapshot,
    recovery: DictationLifecycleProbeResult? = nil,
    failure: String? = nil
) -> String {
    encodeDictationWatchdogProbeResult(DictationWatchdogProbeResult(
        status: status,
        scenario: scenario,
        stalledSessionID: stalledHealth?.sessionID ?? 0,
        stalledCapturedBuffers: stalledHealth?.capturedBuffers ?? 0,
        stalledTerminalStage: stalledHealth?.stage.rawValue ?? "none",
        warningCount: warningCount,
        resetCount: resetCount,
        releasedDuringStartup: releasedDuringStartup,
        cleanup: cleanup,
        recovery: recovery,
        durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
        failure: failure
    ))
}

func runInstalledDictationWatchdogProbe(
    scenario: DictationWatchdogProbeScenario = .startup
) -> String {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let startedAt = Date()
    let initial = dictationLifecycleRuntimeSnapshot()
    let initialResources = dictationCaptureResourceSnapshot()
    guard initial.modelReady else {
        return makeDictationWatchdogProbeResult(
            status: .modelUnavailable,
            scenario: scenario,
            startedAt: startedAt,
            cleanup: initialResources,
            failure: "Parakeet model is not ready."
        )
    }
    guard [DictationCapturePhase.idle.rawValue, DictationCapturePhase.error.rawValue]
            .contains(initial.capturePhase),
          !initial.overlayVisible,
          initialResources.fullyReleased else {
        return makeDictationWatchdogProbeResult(
            status: .recorderBusy,
            scenario: scenario,
            startedAt: startedAt,
            cleanup: initialResources,
            failure: "Dictation recorder has active resources before watchdog probe."
        )
    }

    let previousHealth = latestDictationSessionHealth()
    let countsBefore = dictationWatchdogCounts()
    var armed = false
    DispatchQueue.main.sync {
        switch scenario {
        case .startup:
            armed = recorder.armDiagnosticStartupStall()
        case .midstream:
            armed = recorder.armDiagnosticMidstreamStall(afterBuffers: 3)
        }
        if armed {
            triggerDictation(mode: .diagnostic, keycode: nil, pollForRelease: false)
        }
    }
    guard armed else {
        return makeDictationWatchdogProbeResult(
            status: .recorderBusy,
            scenario: scenario,
            startedAt: startedAt,
            cleanup: dictationCaptureResourceSnapshot(),
            failure: "Could not arm diagnostic \(scenario.rawValue) stall."
        )
    }

    let startupDeadline = Date().addingTimeInterval(scenario == .startup ? 2 : 5)
    var stalledHealth: DictationSessionHealth?
    var setupCapturedBuffers = 0
    var setupReady = false
    while Date() < startupDeadline {
        if let health = latestDictationSessionHealth(),
           health.mode == String(describing: DictMode.diagnostic),
           health != previousHealth {
            stalledHealth = health
        }
        var phase = DictationCapturePhase.idle
        var overlayVisible = false
        DispatchQueue.main.sync {
            phase = recorder.state
            setupCapturedBuffers = recorder.capturedBufferCount
            overlayVisible = DictationOverlay.shared.isVisible
        }
        switch scenario {
        case .startup:
            setupReady = stalledHealth?.stage == .starting
                && phase == .starting
                && setupCapturedBuffers == 0
                && overlayVisible
        case .midstream:
            setupReady = stalledHealth != nil
                && phase == .listening
                && setupCapturedBuffers >= 3
                && overlayVisible
        }
        if setupReady { break }
        usleep(25_000)
    }
    guard let startingHealth = stalledHealth, setupReady else {
        cancelInstalledDictationLifecycleProbe()
        return makeDictationWatchdogProbeResult(
            status: .startRejected,
            scenario: scenario,
            startedAt: startedAt,
            stalledHealth: stalledHealth,
            cleanup: dictationCaptureResourceSnapshot(),
            failure: "Diagnostic \(scenario.rawValue) stall did not reach its capture checkpoint."
        )
    }

    var releasedDuringStartup = false
    if scenario == .startup {
        DispatchQueue.main.sync {
            releasedDuringStartup = recorder.state == .starting
                && recorder.capturedBufferCount == 0
                && DictationOverlay.shared.isVisible
            releaseDictationTrigger(at: Date().timeIntervalSinceReferenceDate + 1)
        }
    }

    let watchdogDeadline = Date().addingTimeInterval(10)
    var cleanup = dictationCaptureResourceSnapshot()
    var countsAfter = countsBefore
    while Date() < watchdogDeadline {
        if let health = latestDictationSessionHealth(), health.sessionID == startingHealth.sessionID {
            stalledHealth = health
        }
        cleanup = dictationCaptureResourceSnapshot()
        countsAfter = dictationWatchdogCounts()
        if stalledHealth?.stage == .cancelled,
           countsAfter.warnings > countsBefore.warnings,
           countsAfter.resets > countsBefore.resets,
           cleanup.fullyReleased {
            break
        }
        usleep(50_000)
    }

    let warningDelta = countsAfter.warnings - countsBefore.warnings
    let resetDelta = countsAfter.resets - countsBefore.resets
    guard stalledHealth?.stage == .cancelled,
          warningDelta == 1,
          resetDelta == 1 else {
        cancelInstalledDictationLifecycleProbe()
        return makeDictationWatchdogProbeResult(
            status: .watchdogNotObserved,
            scenario: scenario,
            startedAt: startedAt,
            stalledHealth: stalledHealth,
            warningCount: warningDelta,
            resetCount: resetDelta,
            releasedDuringStartup: releasedDuringStartup,
            cleanup: dictationCaptureResourceSnapshot(),
            failure: "\(scenario.rawValue.capitalized) stall did not produce one warning and one automatic reset."
        )
    }
    let scenarioEvidencePassed: Bool
    switch scenario {
    case .startup:
        scenarioEvidencePassed = releasedDuringStartup
            && (stalledHealth?.capturedBuffers ?? -1) == 0
    case .midstream:
        scenarioEvidencePassed = !releasedDuringStartup
            && (stalledHealth?.capturedBuffers ?? 0) >= 3
    }
    guard scenarioEvidencePassed, cleanup.fullyReleased,
          cleanup.capturePhase == DictationCapturePhase.idle.rawValue else {
        cancelInstalledDictationLifecycleProbe()
        return makeDictationWatchdogProbeResult(
            status: .cleanupTimedOut,
            scenario: scenario,
            startedAt: startedAt,
            stalledHealth: stalledHealth,
            warningCount: warningDelta,
            resetCount: resetDelta,
            releasedDuringStartup: releasedDuringStartup,
            cleanup: cleanup,
            failure: "Watchdog did not fully release stalled \(scenario.rawValue) resources."
        )
    }

    let recoveryJSON = runInstalledDictationLifecycleProbe()
    guard let recoveryData = recoveryJSON.data(using: .utf8),
          let recovery = try? DictationLifecycleProbeCoding.decode(recoveryData) else {
        return makeDictationWatchdogProbeResult(
            status: .failed,
            scenario: scenario,
            startedAt: startedAt,
            stalledHealth: stalledHealth,
            warningCount: warningDelta,
            resetCount: resetDelta,
            releasedDuringStartup: releasedDuringStartup,
            cleanup: cleanup,
            failure: "Could not decode immediate watchdog retry result."
        )
    }
    guard recovery.ok else {
        return makeDictationWatchdogProbeResult(
            status: .recoveryFailed,
            scenario: scenario,
            startedAt: startedAt,
            stalledHealth: stalledHealth,
            warningCount: warningDelta,
            resetCount: resetDelta,
            releasedDuringStartup: releasedDuringStartup,
            cleanup: cleanup,
            recovery: recovery,
            failure: recovery.failure ?? "Immediate dictation retry failed after watchdog reset."
        )
    }

    appendLog("[dictation-probe] \(scenario.rawValue) watchdog passed stalledSession=\(startingHealth.sessionID) buffers=\(stalledHealth?.capturedBuffers ?? 0) retrySession=\(recovery.sessionID)")
    return makeDictationWatchdogProbeResult(
        status: .passed,
        scenario: scenario,
        startedAt: startedAt,
        stalledHealth: stalledHealth,
        warningCount: warningDelta,
        resetCount: resetDelta,
        releasedDuringStartup: releasedDuringStartup,
        cleanup: cleanup,
        recovery: recovery
    )
}

private func encodeVoiceDispatchProbeResult(_ result: VoiceDispatchProbeResult) -> String {
    guard let data = try? VoiceDispatchProbeCoding.encode(result) else {
        return #"{"ok":false,"status":"eventCreationFailed","failure":"Could not encode voice dispatch probe result."}"#
    }
    return String(decoding: data, as: UTF8.self)
}

private func makeVoiceDispatchProbeResult(
    status: VoiceDispatchProbeStatus,
    startedAt: Date,
    hotkeyRuntime: InstalledHotkeyRuntimeSnapshot,
    dictationRuntime: DictationLifecycleRuntimeSnapshot,
    deliveredEvents: Int = 0,
    health: DictationSessionHealth? = nil,
    resourcesReleased: Bool = false,
    failure: String? = nil
) -> String {
    encodeVoiceDispatchProbeResult(VoiceDispatchProbeResult(
        status: status,
        eventTapDeliveredEvents: deliveredEvents,
        configuredVoiceAliases: hotkeyRuntime.registrations.configuredVoiceAliases,
        sessionID: health?.sessionID ?? 0,
        capturedBuffers: health?.capturedBuffers ?? dictationRuntime.capturedBuffers,
        terminalStage: health?.stage.rawValue ?? "none",
        capturePhase: dictationRuntime.capturePhase,
        resourcesReleased: resourcesReleased,
        durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
        failure: failure ?? health?.failure
    ))
}

func runInstalledVoiceDispatchProbe() -> String {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let startedAt = Date()
    let initialHotkey = installedHotkeyRuntimeSnapshot()
    let initialDictation = dictationLifecycleRuntimeSnapshot()
    guard initialHotkey.accessibilityTrusted else {
        return makeVoiceDispatchProbeResult(
            status: .accessibilityUnavailable,
            startedAt: startedAt,
            hotkeyRuntime: initialHotkey,
            dictationRuntime: initialDictation,
            failure: "Accessibility is not trusted."
        )
    }
    guard initialHotkey.eventTapInstalled else {
        return makeVoiceDispatchProbeResult(
            status: .eventTapMissing,
            startedAt: startedAt,
            hotkeyRuntime: initialHotkey,
            dictationRuntime: initialDictation,
            failure: "Media and voice event tap is not installed."
        )
    }
    guard initialHotkey.eventTapEnabled else {
        return makeVoiceDispatchProbeResult(
            status: .eventTapDisabled,
            startedAt: startedAt,
            hotkeyRuntime: initialHotkey,
            dictationRuntime: initialDictation,
            failure: "Media and voice event tap is disabled."
        )
    }
    guard initialDictation.modelReady else {
        return makeVoiceDispatchProbeResult(
            status: .modelUnavailable,
            startedAt: startedAt,
            hotkeyRuntime: initialHotkey,
            dictationRuntime: initialDictation,
            failure: "Parakeet model is not ready."
        )
    }
    guard [DictationCapturePhase.idle.rawValue, DictationCapturePhase.error.rawValue]
            .contains(initialDictation.capturePhase),
          !initialDictation.overlayVisible,
          dictationCaptureResourceSnapshot().fullyReleased else {
        return makeVoiceDispatchProbeResult(
            status: .recorderBusy,
            startedAt: startedAt,
            hotkeyRuntime: initialHotkey,
            dictationRuntime: initialDictation,
            failure: "Dictation recorder is busy before voice dispatch probe."
        )
    }

    let marker = VOICE_DISPATCH_EVENT_PROBE_PREFIX | Int64.random(in: 1..<(1 << 48))
    let probe = HotkeyEventProbeBox(marker: marker)
    _hotkeyEventProbeLock.lock()
    guard _activeHotkeyEventProbe == nil,
          _activeVoiceDispatchEventProbe == nil,
          _activeEventTapVoiceRouteProbe == nil else {
        _hotkeyEventProbeLock.unlock()
        return makeVoiceDispatchProbeResult(
            status: .probeBusy,
            startedAt: startedAt,
            hotkeyRuntime: initialHotkey,
            dictationRuntime: initialDictation,
            failure: "Another hotkey probe is active."
        )
    }
    _activeVoiceDispatchEventProbe = probe
    _hotkeyEventProbeLock.unlock()
    defer {
        _hotkeyEventProbeLock.lock()
        if _activeVoiceDispatchEventProbe === probe { _activeVoiceDispatchEventProbe = nil }
        _hotkeyEventProbeLock.unlock()
    }

    guard let source = CGEventSource(stateID: .combinedSessionState) else {
        return makeVoiceDispatchProbeResult(
            status: .eventCreationFailed,
            startedAt: startedAt,
            hotkeyRuntime: initialHotkey,
            dictationRuntime: initialDictation,
            failure: "Could not create voice dispatch event source."
        )
    }
    func postVoiceEvent(keyDown: Bool) -> Bool {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: 63,
            keyDown: keyDown
        ) else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
        return true
    }

    let previousHealth = latestDictationSessionHealth()
    guard postVoiceEvent(keyDown: true) else {
        return makeVoiceDispatchProbeResult(
            status: .eventCreationFailed,
            startedAt: startedAt,
            hotkeyRuntime: initialHotkey,
            dictationRuntime: initialDictation,
            failure: "Could not create tagged voice key-down event."
        )
    }

    let captureDeadline = Date().addingTimeInterval(12)
    var probeHealth: DictationSessionHealth?
    while Date() < captureDeadline {
        let runtime = dictationLifecycleRuntimeSnapshot()
        if let health = latestDictationSessionHealth(),
           health.mode == String(describing: DictMode.diagnostic),
           health != previousHealth {
            probeHealth = health
            if health.stage == .failed || health.stage == .cancelled {
                cancelInstalledDictationLifecycleProbe()
                return makeVoiceDispatchProbeResult(
                    status: .failed,
                    startedAt: startedAt,
                    hotkeyRuntime: installedHotkeyRuntimeSnapshot(),
                    dictationRuntime: runtime,
                    deliveredEvents: probe.count(),
                    health: health,
                    failure: health.failure ?? "Voice dispatch capture failed before release."
                )
            }
            if probe.count() >= 1, runtime.capturedBuffers >= 4 { break }
        }
        usleep(50_000)
    }

    guard probe.count() >= 1 else {
        cancelInstalledDictationLifecycleProbe()
        return makeVoiceDispatchProbeResult(
            status: .eventDeliveryTimedOut,
            startedAt: startedAt,
            hotkeyRuntime: installedHotkeyRuntimeSnapshot(),
            dictationRuntime: dictationLifecycleRuntimeSnapshot(),
            deliveredEvents: probe.count(),
            health: probeHealth,
            failure: "Tagged voice key-down did not reach event-tap callback."
        )
    }
    guard let capturedHealth = probeHealth else {
        cancelInstalledDictationLifecycleProbe()
        return makeVoiceDispatchProbeResult(
            status: .startRejected,
            startedAt: startedAt,
            hotkeyRuntime: installedHotkeyRuntimeSnapshot(),
            dictationRuntime: dictationLifecycleRuntimeSnapshot(),
            deliveredEvents: probe.count(),
            failure: "Event-tap voice dispatch did not create a dictation session."
        )
    }
    guard dictationLifecycleRuntimeSnapshot().capturedBuffers >= 4 else {
        cancelInstalledDictationLifecycleProbe()
        return makeVoiceDispatchProbeResult(
            status: .captureTimedOut,
            startedAt: startedAt,
            hotkeyRuntime: installedHotkeyRuntimeSnapshot(),
            dictationRuntime: dictationLifecycleRuntimeSnapshot(),
            deliveredEvents: probe.count(),
            health: capturedHealth,
            failure: "Event-tap voice dispatch did not capture four audio buffers."
        )
    }
    guard postVoiceEvent(keyDown: false) else {
        cancelInstalledDictationLifecycleProbe()
        return makeVoiceDispatchProbeResult(
            status: .eventCreationFailed,
            startedAt: startedAt,
            hotkeyRuntime: installedHotkeyRuntimeSnapshot(),
            dictationRuntime: dictationLifecycleRuntimeSnapshot(),
            deliveredEvents: probe.count(),
            health: capturedHealth,
            failure: "Could not create tagged voice key-up event."
        )
    }

    let finishDeadline = Date().addingTimeInterval(15)
    while Date() < finishDeadline {
        let runtime = dictationLifecycleRuntimeSnapshot()
        if let health = latestDictationSessionHealth(), health.sessionID == capturedHealth.sessionID {
            probeHealth = health
            if health.stage == .failed || health.stage == .cancelled {
                cancelInstalledDictationLifecycleProbe()
                return makeVoiceDispatchProbeResult(
                    status: .failed,
                    startedAt: startedAt,
                    hotkeyRuntime: installedHotkeyRuntimeSnapshot(),
                    dictationRuntime: runtime,
                    deliveredEvents: probe.count(),
                    health: health,
                    failure: health.failure ?? "Voice dispatch capture failed while finishing."
                )
            }
            let resources = dictationCaptureResourceSnapshot()
            if probe.count() >= 2,
               (health.stage == .completed || health.stage == .empty),
               runtime.capturePhase == DictationCapturePhase.idle.rawValue,
               !runtime.overlayVisible,
               resources.fullyReleased {
                appendLog("[dictation-probe] voice dispatch passed events=\(probe.count()) \(health.diagnosticSummary)")
                return makeVoiceDispatchProbeResult(
                    status: .passed,
                    startedAt: startedAt,
                    hotkeyRuntime: installedHotkeyRuntimeSnapshot(),
                    dictationRuntime: runtime,
                    deliveredEvents: probe.count(),
                    health: health,
                    resourcesReleased: true
                )
            }
        }
        usleep(50_000)
    }

    let finalRuntime = dictationLifecycleRuntimeSnapshot()
    let deliveredEvents = probe.count()
    cancelInstalledDictationLifecycleProbe()
    return makeVoiceDispatchProbeResult(
        status: deliveredEvents < 2 ? .eventDeliveryTimedOut : .finishTimedOut,
        startedAt: startedAt,
        hotkeyRuntime: installedHotkeyRuntimeSnapshot(),
        dictationRuntime: finalRuntime,
        deliveredEvents: deliveredEvents,
        health: probeHealth,
        failure: deliveredEvents < 2
            ? "Tagged voice key-up did not reach event-tap callback."
            : "Event-tap voice dispatch did not reach clean terminal state."
    )
}

private struct InstalledHotkeyRuntimeSnapshot {
    let accessibilityTrusted: Bool
    let eventTapInstalled: Bool
    let eventTapEnabled: Bool
    let registrations: HotkeyRegistrationSnapshot
}

private func installedHotkeyRuntimeSnapshot() -> InstalledHotkeyRuntimeSnapshot {
    var snapshot: InstalledHotkeyRuntimeSnapshot?
    DispatchQueue.main.sync {
        let tap = _mediaEventTap
        snapshot = InstalledHotkeyRuntimeSnapshot(
            accessibilityTrusted: AXIsProcessTrusted(),
            eventTapInstalled: tap != nil,
            eventTapEnabled: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            registrations: _hotkeyRegistrationSnapshot
        )
    }
    return snapshot ?? InstalledHotkeyRuntimeSnapshot(
        accessibilityTrusted: false,
        eventTapInstalled: false,
        eventTapEnabled: false,
        registrations: HotkeyRegistrationSnapshot()
    )
}

private func encodeHotkeyHealthProbeResult(_ result: HotkeyHealthProbeResult) -> String {
    guard let data = try? HotkeyHealthProbeCoding.encode(result) else {
        return #"{"ok":false,"status":"eventCreationFailed","failure":"Could not encode hotkey health probe result."}"#
    }
    return String(decoding: data, as: UTF8.self)
}

private func makeHotkeyHealthProbeResult(
    status: HotkeyHealthProbeStatus,
    startedAt: Date,
    runtime: InstalledHotkeyRuntimeSnapshot,
    requestedEvents: Int,
    deliveredEvents: Int = 0,
    validatedCarbonVoiceAliases: Int = 0,
    validatedEventTapVoiceAliases: Int = 0,
    failure: String? = nil
) -> String {
    let registrations = runtime.registrations
    return encodeHotkeyHealthProbeResult(HotkeyHealthProbeResult(
        status: status,
        accessibilityTrusted: runtime.accessibilityTrusted,
        eventTapInstalled: runtime.eventTapInstalled,
        eventTapEnabled: runtime.eventTapEnabled,
        expectedCarbonRegistrations: registrations.expectedCarbonRegistrations,
        actualCarbonRegistrations: registrations.actualCarbonRegistrations,
        registrationFailures: registrations.registrationFailures,
        expectedEventTapAliases: registrations.expectedEventTapAliases,
        configuredVoiceAliases: registrations.configuredVoiceAliases,
        expectedCarbonVoiceAliases: registrations.expectedCarbonVoiceAliases,
        expectedEventTapVoiceAliases: registrations.expectedEventTapVoiceAliases,
        validatedCarbonVoiceAliases: validatedCarbonVoiceAliases,
        validatedEventTapVoiceAliases: validatedEventTapVoiceAliases,
        requestedEvents: requestedEvents,
        deliveredEvents: deliveredEvents,
        durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
        failure: failure
    ))
}

private func eventFlags(carbonModifiers: UInt32) -> CGEventFlags {
    var flags: CGEventFlags = []
    if carbonModifiers & 256 != 0 { flags.insert(.maskCommand) }
    if carbonModifiers & 512 != 0 { flags.insert(.maskShift) }
    if carbonModifiers & 2048 != 0 { flags.insert(.maskAlternate) }
    if carbonModifiers & 4096 != 0 { flags.insert(.maskControl) }
    return flags
}

private func postCarbonVoiceRouteEvent(hotkeyID: UInt32, kind: UInt32) -> OSStatus {
    var event: EventRef?
    let createStatus = CreateEvent(
        nil,
        OSType(kEventClassKeyboard),
        kind,
        GetCurrentEventTime(),
        EventAttributes(kEventAttributeNone),
        &event
    )
    guard createStatus == noErr, let event else { return createStatus }
    defer { ReleaseEvent(event) }

    var eventID = EventHotKeyID(signature: OSType(0x434D4447), id: hotkeyID)
    let parameterStatus = withUnsafePointer(to: &eventID) {
        SetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            $0
        )
    }
    guard parameterStatus == noErr else { return parameterStatus }
    return PostEventToQueue(
        GetMainEventQueue(),
        event,
        EventPriority(kEventPriorityStandard)
    )
}

private func primaryModifierFlag(keycode: UInt32) -> CGEventFlags {
    switch keycode {
    case 54, 55: return .maskCommand
    case 56, 60: return .maskShift
    case 58, 61: return .maskAlternate
    case 59, 62: return .maskControl
    case 63: return .maskSecondaryFn
    default: return []
    }
}

private func makeEventTapVoiceRouteEvent(
    source: CGEventSource,
    shortcut: HotkeyShortcut,
    marker: Int64,
    keyDown: Bool
) -> CGEvent? {
    let event: CGEvent?
    if MODIFIER_ONLY_KEYCODES.contains(shortcut.keycode) {
        event = CGEvent(source: source)
        event?.type = .flagsChanged
        event?.setIntegerValueField(.keyboardEventKeycode, value: Int64(shortcut.keycode))
        var flags = eventFlags(carbonModifiers: shortcut.mods)
        if keyDown { flags.formUnion(primaryModifierFlag(keycode: shortcut.keycode)) }
        event?.flags = flags
    } else {
        event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(shortcut.keycode),
            keyDown: keyDown
        )
        event?.flags = eventFlags(carbonModifiers: shortcut.mods)
    }
    event?.setIntegerValueField(.eventSourceUserData, value: marker)
    return event
}

private func runInstalledCarbonVoiceRouteProbe(
    expectedAliases: Int
) -> (validated: Int, failure: String?) {
    var routes: [(id: UInt32, shortcut: HotkeyShortcut)] = []
    DispatchQueue.main.sync {
        routes = hotkeyActions.compactMap { id, action in
            guard isVoiceHotkeyAction(action), let shortcut = hotkeyShortcuts[id] else { return nil }
            return (id, shortcut)
        }.sorted { $0.id < $1.id }
    }
    guard routes.count == expectedAliases else {
        return (0, "Registered Carbon voice alias inventory is incomplete.")
    }
    guard !routes.isEmpty else { return (0, nil) }
    var validated = 0
    for route in routes {
        let probe = CarbonVoiceRouteProbeBox(hotkeyID: route.id)
        _carbonVoiceRouteProbeLock.lock()
        guard _activeCarbonVoiceRouteProbe == nil else {
            _carbonVoiceRouteProbeLock.unlock()
            return (validated, "Another Carbon voice route probe is active.")
        }
        _activeCarbonVoiceRouteProbe = probe
        _carbonVoiceRouteProbeLock.unlock()

        let pressStatus = postCarbonVoiceRouteEvent(
            hotkeyID: route.id,
            kind: UInt32(kEventHotKeyPressed)
        )
        guard pressStatus == noErr else {
            _carbonVoiceRouteProbeLock.lock()
            _activeCarbonVoiceRouteProbe = nil
            _carbonVoiceRouteProbeLock.unlock()
            return (validated, "Could not post Carbon voice press event (status \(pressStatus)).")
        }
        var deadline = DispatchTime.now() + .seconds(3)
        while probe.deliveredCount() < 1, probe.delivery.wait(timeout: deadline) == .success {}

        let releaseStatus = postCarbonVoiceRouteEvent(
            hotkeyID: route.id,
            kind: UInt32(kEventHotKeyReleased)
        )
        guard releaseStatus == noErr else {
            _carbonVoiceRouteProbeLock.lock()
            _activeCarbonVoiceRouteProbe = nil
            _carbonVoiceRouteProbeLock.unlock()
            return (validated, "Could not post Carbon voice release event (status \(releaseStatus)).")
        }
        if probe.deliveredCount() == 1 {
            deadline = DispatchTime.now() + .seconds(3)
            while probe.deliveredCount() < 2, probe.delivery.wait(timeout: deadline) == .success {}
        }
        _carbonVoiceRouteProbeLock.lock()
        if _activeCarbonVoiceRouteProbe === probe { _activeCarbonVoiceRouteProbe = nil }
        _carbonVoiceRouteProbeLock.unlock()
        guard probe.deliveredCount() == 2 else {
            return (
                validated,
                "Carbon voice alias \(route.shortcut.human) did not deliver press and release."
            )
        }
        validated += 1
    }
    return (validated, nil)
}

private func runInstalledEventTapVoiceRouteProbe(
    expectedAliases: Int
) -> (validated: Int, failure: String?) {
    var routes: [HotkeyShortcut] = []
    DispatchQueue.main.sync {
        routes = eventTapVoiceShortcuts.sorted { $0.human < $1.human }
    }
    guard routes.count == expectedAliases else {
        return (0, "Registered event-tap voice alias inventory is incomplete.")
    }
    guard !routes.isEmpty else { return (0, nil) }
    guard let source = CGEventSource(stateID: .combinedSessionState) else {
        return (0, "Could not create event-tap voice route event source.")
    }

    var validated = 0
    for shortcut in routes {
        let marker = VOICE_ROUTE_EVENT_PROBE_PREFIX | Int64.random(in: 1..<(1 << 48))
        let probe = EventTapVoiceRouteProbeBox(marker: marker, shortcut: shortcut)
        _hotkeyEventProbeLock.lock()
        guard _activeHotkeyEventProbe == nil,
              _activeVoiceDispatchEventProbe == nil,
              _activeEventTapVoiceRouteProbe == nil else {
            _hotkeyEventProbeLock.unlock()
            return (validated, "Another event-tap voice route probe is active.")
        }
        _activeEventTapVoiceRouteProbe = probe
        _hotkeyEventProbeLock.unlock()

        guard let down = makeEventTapVoiceRouteEvent(
            source: source,
            shortcut: shortcut,
            marker: marker,
            keyDown: true
        ), let up = makeEventTapVoiceRouteEvent(
            source: source,
            shortcut: shortcut,
            marker: marker,
            keyDown: false
        ) else {
            _hotkeyEventProbeLock.lock()
            _activeEventTapVoiceRouteProbe = nil
            _hotkeyEventProbeLock.unlock()
            return (validated, "Could not create event-tap voice alias events.")
        }

        down.post(tap: .cghidEventTap)
        var deadline = DispatchTime.now() + .seconds(3)
        while probe.deliveredCount() < 1, probe.delivery.wait(timeout: deadline) == .success {}
        if probe.deliveredCount() == 1 {
            up.post(tap: .cghidEventTap)
            deadline = DispatchTime.now() + .seconds(3)
            while probe.deliveredCount() < 2, probe.delivery.wait(timeout: deadline) == .success {}
        }

        _hotkeyEventProbeLock.lock()
        if _activeEventTapVoiceRouteProbe === probe { _activeEventTapVoiceRouteProbe = nil }
        _hotkeyEventProbeLock.unlock()
        guard probe.deliveredCount() == 2 else {
            return (
                validated,
                "Event-tap voice alias \(shortcut.human) did not route press and release."
            )
        }
        validated += 1
    }
    return (validated, nil)
}

func runInstalledHotkeyHealthProbe(requestedEvents: Int) -> String {
    let startedAt = Date()
    let eventCount = min(max(requestedEvents, 2), 200)
    let initial = installedHotkeyRuntimeSnapshot()
    guard initial.accessibilityTrusted else {
        return makeHotkeyHealthProbeResult(
            status: .accessibilityUnavailable,
            startedAt: startedAt,
            runtime: initial,
            requestedEvents: eventCount,
            failure: "Accessibility is not trusted."
        )
    }
    guard initial.eventTapInstalled else {
        return makeHotkeyHealthProbeResult(
            status: .eventTapMissing,
            startedAt: startedAt,
            runtime: initial,
            requestedEvents: eventCount,
            failure: "Media and voice event tap is not installed."
        )
    }
    guard initial.eventTapEnabled else {
        return makeHotkeyHealthProbeResult(
            status: .eventTapDisabled,
            startedAt: startedAt,
            runtime: initial,
            requestedEvents: eventCount,
            failure: "Media and voice event tap is disabled."
        )
    }
    let registrations = initial.registrations
    guard registrations.registrationFailures == 0,
          registrations.actualCarbonRegistrations == registrations.expectedCarbonRegistrations else {
        return makeHotkeyHealthProbeResult(
            status: .registrationMismatch,
            startedAt: startedAt,
            runtime: initial,
            requestedEvents: eventCount,
            failure: "Carbon hotkey registration count does not match configured aliases."
        )
    }
    let carbonVoiceRoutes = runInstalledCarbonVoiceRouteProbe(
        expectedAliases: registrations.expectedCarbonVoiceAliases
    )
    guard carbonVoiceRoutes.failure == nil,
          carbonVoiceRoutes.validated == registrations.expectedCarbonVoiceAliases else {
        return makeHotkeyHealthProbeResult(
            status: .eventDeliveryTimedOut,
            startedAt: startedAt,
            runtime: installedHotkeyRuntimeSnapshot(),
            requestedEvents: eventCount,
            validatedCarbonVoiceAliases: carbonVoiceRoutes.validated,
            failure: carbonVoiceRoutes.failure ?? "Carbon voice alias route count mismatch."
        )
    }
    let eventTapVoiceRoutes = runInstalledEventTapVoiceRouteProbe(
        expectedAliases: registrations.expectedEventTapVoiceAliases
    )
    guard eventTapVoiceRoutes.failure == nil,
          eventTapVoiceRoutes.validated == registrations.expectedEventTapVoiceAliases else {
        return makeHotkeyHealthProbeResult(
            status: .eventDeliveryTimedOut,
            startedAt: startedAt,
            runtime: installedHotkeyRuntimeSnapshot(),
            requestedEvents: eventCount,
            validatedCarbonVoiceAliases: carbonVoiceRoutes.validated,
            validatedEventTapVoiceAliases: eventTapVoiceRoutes.validated,
            failure: eventTapVoiceRoutes.failure ?? "Event-tap voice alias route count mismatch."
        )
    }

    let marker = HOTKEY_EVENT_PROBE_PREFIX | Int64.random(in: 1..<(1 << 48))
    let probe = HotkeyEventProbeBox(marker: marker)
    _hotkeyEventProbeLock.lock()
    guard _activeHotkeyEventProbe == nil,
          _activeVoiceDispatchEventProbe == nil,
          _activeEventTapVoiceRouteProbe == nil else {
        _hotkeyEventProbeLock.unlock()
        return makeHotkeyHealthProbeResult(
            status: .probeBusy,
            startedAt: startedAt,
            runtime: initial,
            requestedEvents: eventCount,
            validatedCarbonVoiceAliases: carbonVoiceRoutes.validated,
            validatedEventTapVoiceAliases: eventTapVoiceRoutes.validated,
            failure: "Another hotkey health probe is active."
        )
    }
    _activeHotkeyEventProbe = probe
    _hotkeyEventProbeLock.unlock()
    defer {
        _hotkeyEventProbeLock.lock()
        if _activeHotkeyEventProbe === probe { _activeHotkeyEventProbe = nil }
        _hotkeyEventProbeLock.unlock()
    }

    guard let source = CGEventSource(stateID: .combinedSessionState) else {
        return makeHotkeyHealthProbeResult(
            status: .eventCreationFailed,
            startedAt: startedAt,
            runtime: initial,
            requestedEvents: eventCount,
            validatedCarbonVoiceAliases: carbonVoiceRoutes.validated,
            validatedEventTapVoiceAliases: eventTapVoiceRoutes.validated,
            failure: "Could not create event source."
        )
    }
    for index in 0..<eventCount {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: index.isMultiple(of: 2)
        ) else {
            return makeHotkeyHealthProbeResult(
                status: .eventCreationFailed,
                startedAt: startedAt,
                runtime: installedHotkeyRuntimeSnapshot(),
                requestedEvents: eventCount,
                deliveredEvents: probe.count(),
                validatedCarbonVoiceAliases: carbonVoiceRoutes.validated,
                validatedEventTapVoiceAliases: eventTapVoiceRoutes.validated,
                failure: "Could not create tagged keyboard event."
            )
        }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    let deadline = DispatchTime.now() + .seconds(3)
    while probe.count() < eventCount, probe.delivery.wait(timeout: deadline) == .success {}
    let delivered = probe.count()
    let final = installedHotkeyRuntimeSnapshot()
    guard delivered == eventCount else {
        return makeHotkeyHealthProbeResult(
            status: .eventDeliveryTimedOut,
            startedAt: startedAt,
            runtime: final,
            requestedEvents: eventCount,
            deliveredEvents: delivered,
            validatedCarbonVoiceAliases: carbonVoiceRoutes.validated,
            validatedEventTapVoiceAliases: eventTapVoiceRoutes.validated,
            failure: "Tagged HID events did not reach installed event-tap callback."
        )
    }
    appendLog("[hotkeys] installed health passed events=\(delivered)/\(eventCount) carbon=\(registrations.actualCarbonRegistrations)/\(registrations.expectedCarbonRegistrations) eventTapAliases=\(registrations.expectedEventTapAliases)")
    return makeHotkeyHealthProbeResult(
        status: .passed,
        startedAt: startedAt,
        runtime: final,
        requestedEvents: eventCount,
        deliveredEvents: delivered,
        validatedCarbonVoiceAliases: carbonVoiceRoutes.validated,
        validatedEventTapVoiceAliases: eventTapVoiceRoutes.validated
    )
}

func handle(_ line: String) -> String {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts.first ?? "" {
    case "copy":
        var out = ""
        DispatchQueue.main.sync { postKey(kC, cmd: true); usleep(300_000)
                                  out = NSPasteboard.general.string(forType: .string) ?? "" }
        return out
    case "paste":  DispatchQueue.main.sync { postKey(kV, cmd: true) };  return "ok"
    case "return": DispatchQueue.main.sync { postKey(kRet, cmd: false) }; return "ok"
    case "pasteapp", "returnapp":
        guard parts.count > 1 else { return "err" }
        var posted = false
        let isPaste = parts[0] == "pasteapp"
        DispatchQueue.main.sync {
            posted = postKey(isPaste ? kV : kRet, cmd: isPaste, to: parts[1])
        }
        return posted ? "ok" : "err"
    case "newtask", "newchat", "newprojectless":
        guard parts.count > 1,
              let shortcut = assistantShortcut(forSocketCommand: parts[0]) else { return "err" }
        var posted = false
        DispatchQueue.main.sync {
            posted = postKey(CGKeyCode(shortcut.keycode),
                             cmd: shortcut.command,
                             opt: shortcut.option,
                             shift: shortcut.shift,
                             to: parts[1])
        }
        return posted ? "ok" : "err"
    case "editable":
        var ready = false
        DispatchQueue.main.sync { ready = focusedElementIsEditable() }
        return ready ? "ok" : "wait"
    case "activate":
        if parts.count > 1 { let b = parts[1]; DispatchQueue.main.sync { activate(b) } }
        return "ok"
    case "clipboardhasimage":
        var hasImage = false
        DispatchQueue.main.sync { hasImage = clipboardHasImage() }
        return hasImage ? "yes" : "no"
    case "fronturl":
        guard parts.count > 1 else { return "" }
        var url = ""
        DispatchQueue.main.sync { url = focusedDocumentURL(bundleIdentifier: parts[1]) }
        return url
    case "notify":
        guard parts.count > 1 else { return "err" }
        let fields = parts[1].split(separator: " ", maxSplits: 1).map(String.init)
        guard fields.count == 2,
              let titleData = Data(base64Encoded: fields[0]),
              let bodyData = Data(base64Encoded: fields[1]),
              let title = String(data: titleData, encoding: .utf8),
              let body = String(data: bodyData, encoding: .utf8) else { return "err" }
        DispatchQueue.main.async { notify(title, body) }
        return "ok"
    case "showpicker":
        let b = parts.count > 1 ? parts[1] : ""
        DispatchQueue.main.async { picker.show(prev: b) }
        return "ok"
    case "hide":   // hide an app's windows (used to clear Claude before a screenshot)
        if parts.count > 1 { let b = parts[1]
            DispatchQueue.main.sync {   // sync: reply only once it's actually hidden
                _ = NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.hide()
            } }
        return "ok"
    case "reloadhotkeys": DispatchQueue.main.async { reregisterHotkeys() }; return "ok"
    case "showsettings":  DispatchQueue.main.async { settingsWindow.show(tab: .setup) }; return "ok"
    case "runtimepid": return "\(ProcessInfo.processInfo.processIdentifier)"
    case "dictationprobe": return runInstalledDictationProbe()
    case "dictationlifecycleprobe": return runInstalledDictationLifecycleProbe()
    case "dictationrecoveryprobe": return runInstalledDictationRecoveryProbe()
    case "dictationwatchdogprobe": return runInstalledDictationWatchdogProbe()
    case "dictationstreamwatchdogprobe": return runInstalledDictationWatchdogProbe(scenario: .midstream)
    case "dictationinsertprobe":
        guard parts.count > 1 else {
            return encodeDictationInsertProbeResult(DictationInsertProbeResult(
                status: .receiverUnavailable,
                failure: "Paste receiver bundle and output path are required."
            ))
        }
        let probeArguments = parts[1].split(separator: "\t", maxSplits: 1).map(String.init)
        guard probeArguments.count == 2 else {
            return encodeDictationInsertProbeResult(DictationInsertProbeResult(
                status: .receiverUnavailable,
                failure: "Paste receiver arguments are malformed."
            ))
        }
        return runInstalledDictationInsertProbe(
            targetBundle: probeArguments[0],
            receiverPath: probeArguments[1]
        )
    case "voicedispatchprobe": return runInstalledVoiceDispatchProbe()
    case "hotkeyhealthprobe":
        let requested = Int(parts.count > 1 ? parts[1] : "") ?? 20
        return runInstalledHotkeyHealthProbe(requestedEvents: requested)
    case "restart":
        // Reply before beginning the detached handoff so callers can distinguish
        // an accepted restart from a dead socket.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { restartApp() }
        return "ok"
    case "ping": return "pong"
    default: return "err"
    }
}

func startServer() {
    unlink(SOCK)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 {
        appendLog("[socket] create failed errno=\(errno) \(String(cString: strerror(errno)))")
        return
    }
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(SOCK.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let n = min(pathBytes.count, raw.count - 1)
        for i in 0..<n { base[i] = pathBytes[i] }
        base[n] = 0
    }
    var a = addr
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    if bound != 0 {
        appendLog("[socket] bind failed path=\(SOCK) errno=\(errno) \(String(cString: strerror(errno)))")
        close(fd)
        return
    }
    // Owner-only: this socket accepts keystroke-synthesis + clipboard commands
    // backed by the app's Accessibility grant. Any local process that could
    // reach it could drive synthetic keystrokes into the focused app, so lock
    // it to the current user.
    chmod(SOCK, 0o600)
    guard listen(fd, 8) == 0 else {
        appendLog("[socket] listen failed errno=\(errno) \(String(cString: strerror(errno)))")
        close(fd)
        return
    }
    appendLog("[socket] listening path=\(SOCK)")
    DispatchQueue.global().async {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            let n = read(c, &buf, buf.count)
            if n > 0 {
                let line = (String(bytes: buf[0..<n], encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resp = handle(line)
                _ = resp.withCString { write(c, $0, strlen($0)) }
            }
            close(c)
        }
    }
}

// ---- dock presence ---------------------------------------------------------
// Default: menu-bar only (no Dock icon). "Show in Dock" flips it. While a window
// is open we force .regular regardless, so it can take focus + appear in ⌘-Tab.
func showDockIcon() -> Bool { UserDefaults.standard.bool(forKey: "showDockIcon") }   // default false
func setShowDockIcon(_ on: Bool) { UserDefaults.standard.set(on, forKey: "showDockIcon") }
func applyDockPolicy() {
    NSApp.setActivationPolicy(showDockIcon() || settingsWindow.isVisible ? .regular : .accessory)
}

// Re-launching the app (Finder double-click, Alfred `open`, or a Dock-icon click)
// reopens the window — there's no other launch action.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openLastSettingsTab()
        return true
    }

    @objc func openAbout(_ sender: Any?) { settingsWindow.show(tab: .about) }
    @objc func openSettings(_ sender: Any?) { settingsWindow.show(tab: .shortcuts) }
    @objc func openSetUp(_ sender: Any?) { settingsWindow.show(tab: .setup) }
    @objc func openShortcuts(_ sender: Any?) { settingsWindow.show(tab: .shortcuts) }
    @objc func openContext(_ sender: Any?) { settingsWindow.show(tab: .templates) }
    @objc func openCommandHistory(_ sender: Any?) { settingsWindow.show(tab: .handoffs) }
    @objc func openClipboardHistorySettings(_ sender: Any?) { settingsWindow.show(tab: .history) }
    @objc func openBackground(_ sender: Any?) { settingsWindow.show(tab: .background) }
    @objc func openDictationHistory(_ sender: Any?) { settingsWindow.show(tab: .dictHistory) }
    @objc func openDictationSettings(_ sender: Any?) { settingsWindow.show(tab: .dictSettings) }
    @objc func openDictationVocabulary(_ sender: Any?) { settingsWindow.show(tab: .dictVocabulary) }
    @objc func openDictationCorrections(_ sender: Any?) { settingsWindow.show(tab: .dictCorrections) }
    @objc func openImportExport(_ sender: Any?) { settingsWindow.show(tab: .about) }
    @objc func restartCommand(_ sender: Any?) { restartApp() }
    @MainActor @objc func copyDiagnosticInfo(_ sender: Any?) {
        copyCommandDiagnosticInfo()
        notify("Diagnostic Info Copied", "Command status, bindings, recent run summaries, and log tails are on the clipboard.")
    }
    @objc func openDocumentation(_ sender: Any?) { openHelpDoc(named: "index") }
    @objc func openUserGuide(_ sender: Any?) { openHelpDoc(named: "guide") }
    @objc func openTroubleshooting(_ sender: Any?) { openHelpDoc(named: "troubleshooting") }
    @objc func openSupport(_ sender: Any?) { openHelpDoc(named: "support") }
    @objc func reportBug(_ sender: Any?) {
        if let url = reportBugURL() { NSWorkspace.shared.open(url) }
    }
    @objc func requestFeature(_ sender: Any?) {
        if let url = requestFeatureURL() { NSWorkspace.shared.open(url) }
    }
}
let appDelegate = AppDelegate()

private func openLastSettingsTab() {
    if let raw = UserDefaults.standard.string(forKey: "lastSettingsTab"),
       let tab = SettingsTab(storageValue: raw) {
        settingsWindow.show(tab: tab)
    } else {
        settingsWindow.show(tab: .setup)
    }
}

// ---- main ------------------------------------------------------------------

// Single-instance guard: if our socket is already accepting connections, another
// instance is running (e.g. launchd started one via RunAtLoad when we registered).
// Exit cleanly so the prior instance stays authoritative.
func anotherInstanceRunning() -> Bool {
    guard FileManager.default.fileExists(atPath: SOCK) else { return false }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
        SOCK.withCString { src in strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self), src, ptr.count - 1) }
    }
    return withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
            Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}
if anotherInstanceRunning() { exit(0) }

private func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func reopenAfterExit(appPath: String, pid: Int32) {
    let script = """
    #!/bin/zsh
    PID=\(pid)
    APP=\(shellSingleQuote(appPath))
    for i in {1..75}; do /bin/kill -0 $PID 2>/dev/null || break; sleep 0.2; done
    /usr/bin/open "$APP"
    """
    let path = NSTemporaryDirectory() + "command-reopen-\(pid).sh"
    guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
        appendLog("[restart] could not write reopen helper")
        return
    }
    chmod(path, 0o700)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [path]
    do { try p.run() } catch { appendLog("[restart] could not launch reopen helper: \(error)") }
}

private let restartStateLock = NSLock()
private var restartInProgress = false

private func handOffRestartAfterExit(appPath: String, pid: Int32) -> Bool {
    let helper = bundledResource("restart-app.sh")
    guard FileManager.default.isExecutableFile(atPath: helper) else {
        appendLog("[restart] bundled restart-app.sh missing")
        return false
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [helper, "\(pid)", appPath, AGENT_LABEL]
    do {
        try p.run()
        return true
    } catch {
        appendLog("[restart] could not launch restart helper: \(error)")
        return false
    }
}

// Exit successfully after handing restart to a detached helper. Successful exit
// suppresses launchd's restart-on-failure rule, preventing competing instances;
// helper then kickstarts loaded service once or reopens manually launched app.
func restartApp() {
    restartStateLock.lock()
    guard !restartInProgress else {
        restartStateLock.unlock()
        return
    }
    restartInProgress = true
    restartStateLock.unlock()

    DispatchQueue.global().async {
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        if !handOffRestartAfterExit(appPath: appPath, pid: pid) {
            reopenAfterExit(appPath: appPath, pid: pid)
        }
        try? FileManager.default.removeItem(atPath: SOCK)
        exit(0)
    }
}

func validateInstall() {
    let checks: [(String, String)] = [
        (WORKER, "send-to-claude.sh missing — reinstall"),
        (bundledResource("CommandClipboardWatcher"), "Clipboard History helper missing — reinstall"),
    ]
    for (path, msg) in checks where !path.isEmpty && !FileManager.default.fileExists(atPath: path) {
        appendLog("[startup] \(msg): \(path)")
        notify("Command install broken", msg)
    }
}

// Downloaded builds can launch from Downloads, Desktop, or an App Translocation
// path. Offer one-click relocation so updates and login launch use stable path.
// Source builds beside build-agent.sh stay in place for development.
@MainActor
func offerMoveToApplicationsIfNeeded() -> Bool {
    let fm = FileManager.default
    let current = URL(fileURLWithPath: Bundle.main.bundlePath).standardizedFileURL
    let userApplications = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Applications", isDirectory: true)
    let sourceRoot = current.deletingLastPathComponent()
    let sourceRootHasBuildScript = fm.fileExists(
        atPath: sourceRoot.appendingPathComponent("build-agent.sh").path
    )
    guard InstallLocationPolicy.shouldOfferMove(
        bundlePath: current.path,
        homeDirectory: NSHomeDirectory(),
        sourceRootHasBuildScript: sourceRootHasBuildScript
    ) else {
        return false
    }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Move Command to Applications?"
    alert.informativeText = "Command works best from your Applications folder. Moving it keeps updates, login launch, and macOS permissions tied to one stable copy."
    alert.addButton(withTitle: "Move to Applications")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }

    let destination = userApplications.appendingPathComponent("Command.app", isDirectory: true)
    let staging = userApplications.appendingPathComponent(".Command.installing-\(UUID().uuidString).app", isDirectory: true)
    let backup = userApplications.appendingPathComponent(".Command.previous-\(UUID().uuidString).app", isDirectory: true)
    do {
        try fm.createDirectory(at: userApplications, withIntermediateDirectories: true)
        try fm.copyItem(at: current, to: staging)

        let signature = runShell("/usr/bin/codesign", ["--verify", "--deep", "--strict", staging.path])
        guard signature.code == 0 else {
            throw NSError(
                domain: "CommandInstall",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded Command signature could not be verified."]
            )
        }

        if fm.fileExists(atPath: destination.path) {
            guard let existingRequirement = appDesignatedRequirement(at: destination.path),
                  let incomingRequirement = appDesignatedRequirement(at: staging.path),
                  existingRequirement == incomingRequirement else {
                throw NSError(
                    domain: "CommandInstall",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded Command signing identity does not match installed copy."]
                )
            }
            try fm.moveItem(at: destination, to: backup)
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            if fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }
        try? fm.removeItem(at: backup)
        NSWorkspace.shared.openApplication(
            at: destination,
            configuration: NSWorkspace.OpenConfiguration()
        )
        NSApp.terminate(nil)
        return true
    } catch {
        try? fm.removeItem(at: staging)
        if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: backup.path) {
            try? fm.moveItem(at: backup, to: destination)
        }
        let failure = NSAlert()
        failure.alertStyle = .warning
        failure.messageText = "Command couldn't move itself"
        failure.informativeText = "Move Command.app to ~/Applications, then open that copy.\n\n\(error.localizedDescription)"
        failure.addButton(withTitle: "OK")
        failure.runModal()
        return false
    }
}

func stopClipwatch() {
    _ = runShell("/usr/bin/pkill", ["-x", "CommandClipboardWatcher"])
    // Builds before native Clipboard History used a Python child. That orphan can
    // survive an incremental update after its script and LaunchAgent are removed.
    for legacyPattern in [
        "/Command\\.app/Contents/Resources/clipwatch\\.py$",
        "/ClaudeCommand\\.app/Contents/Resources/clipwatch\\.py$",
    ] {
        _ = runShell("/usr/bin/pkill", ["-f", legacyPattern])
    }
}

private var clipwatchRestartAttempts = 0

// Start the bundled clipboard watcher as a child process.
// Restarts automatically if it exits — runs as long as ClaudeCommand is running.
func startClipwatch() {
    let logDir = "\(HOME)/.claude/logs"
    func dbg(_ msg: String) {
        let path = "\(logDir)/clipwatch-start.log"
        let line = msg + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(data); fh.closeFile() }
            } else { try? data.write(to: URL(fileURLWithPath: path)) }
        }
    }
    let enabled = UserDefaults.standard.bool(forKey: "cliphistoryEnabled")
    dbg("startClipwatch: enabled=\(enabled)")
    guard enabled else { dbg("returning: disabled"); return }
    let helper = bundledResource("CommandClipboardWatcher")
    dbg("helper=\(helper)")
    guard FileManager.default.isExecutableFile(atPath: helper) else {
        dbg("returning: helper missing/not executable at \(helper)")
        appendLog("[clipboard] helper missing/not executable path=\(helper)")
        return
    }
    // Keep one native Clipboard History helper per user session.
    let pgrep = runShell("/usr/bin/pgrep", ["-x", "CommandClipboardWatcher"])
    dbg("pgrep code=\(pgrep.code)")
    if pgrep.code == 0 {
        let out = pgrep.out.trimmingCharacters(in: .whitespacesAndNewlines)
        dbg("already running pid=\(out) — skipping")
        return
    }
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    let errPath = "\(logDir)/clipwatch.err"
    if !FileManager.default.fileExists(atPath: errPath) {
        FileManager.default.createFile(atPath: errPath, contents: nil)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: helper)
    var env = ProcessInfo.processInfo.environment; env["HOME"] = HOME
    p.environment = env
    if let errorHandle = FileHandle(forWritingAtPath: errPath) {
        _ = try? errorHandle.seekToEnd()
        p.standardError = errorHandle
    }
    p.terminationHandler = { proc in
        let code = proc.terminationStatus
        DispatchQueue.main.async {
            guard code != 0 else {
                dbg("clipboard helper exited normally")
                return
            }
            clipwatchRestartAttempts += 1
            dbg("clipboard helper exited code=\(code) attempt=\(clipwatchRestartAttempts)")
            appendLog("[clipboard] helper exited code=\(code) attempt=\(clipwatchRestartAttempts)")
            guard clipwatchRestartAttempts <= 3 else {
                appendLog("[clipboard] restart limit reached; open Set Up and copy diagnostics")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { startClipwatch() }
        }
    }
    do {
        try p.run()
        dbg("started pid=\(p.processIdentifier)")
        appendLog("[clipboard] started native helper pid=\(p.processIdentifier) path=\(helper)")
    } catch {
        dbg("run failed: \(error)")
        appendLog("[clipboard] launch failed path=\(helper) error=\(error.localizedDescription)")
    }
}

// Standard Edit menu (Cut/Copy/Paste/Select All/Undo/Redo) with the usual key
// equivalents. LSUIElement agents have no menu bar by default, and without an
// Edit menu claiming ⌘C/⌘V, those key equivalents never reach the first
// responder — so Cmd+C/Cmd+V silently do nothing in every text field in the
// Settings window (NSTextField/NSTextView copy/paste is routed through the
// menu system, not raw key handling).
func installMainMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu(title: "Command")
    appMenuItem.submenu = appMenu
    appMenu.addItem(withTitle: "About Command", action: #selector(AppDelegate.openAbout(_:)), keyEquivalent: "").target = appDelegate
    appMenu.addItem(NSMenuItem.separator())
    let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
    settingsItem.target = appDelegate
    let updatesItem = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.openAbout(_:)), keyEquivalent: "")
    updatesItem.target = appDelegate
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Hide Command", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Quit Command", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenuItem.submenu = editMenu
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(viewMenuItem)
    let viewMenu = NSMenu(title: "View")
    viewMenuItem.submenu = viewMenu
    for (title, selector) in [
        ("Set Up", #selector(AppDelegate.openSetUp(_:))),
        ("About", #selector(AppDelegate.openAbout(_:))),
        ("Clipboard History", #selector(AppDelegate.openClipboardHistorySettings(_:))),
    ] {
        let item = viewMenu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        item.target = appDelegate
    }
    viewMenu.addItem(NSMenuItem.separator())
    for (title, selector) in [
        ("Shortcut Settings", #selector(AppDelegate.openShortcuts(_:))),
        ("Context", #selector(AppDelegate.openContext(_:))),
        ("Background", #selector(AppDelegate.openBackground(_:))),
        ("Shortcut History", #selector(AppDelegate.openCommandHistory(_:))),
    ] {
        let item = viewMenu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        item.target = appDelegate
    }
    viewMenu.addItem(NSMenuItem.separator())
    for (title, selector) in [
        ("Dictation Settings", #selector(AppDelegate.openDictationSettings(_:))),
        ("Vocabulary", #selector(AppDelegate.openDictationVocabulary(_:))),
        ("Corrections", #selector(AppDelegate.openDictationCorrections(_:))),
        ("Dictation History", #selector(AppDelegate.openDictationHistory(_:))),
    ] {
        let item = viewMenu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        item.target = appDelegate
    }

    let commandMenuItem = NSMenuItem()
    mainMenu.addItem(commandMenuItem)
    let commandMenu = NSMenu(title: "Tools")
    commandMenuItem.submenu = commandMenu
    let importExport = commandMenu.addItem(withTitle: "Import / Export…", action: #selector(AppDelegate.openImportExport(_:)), keyEquivalent: "")
    importExport.target = appDelegate
    let diagnostics = commandMenu.addItem(withTitle: "Copy Diagnostic Info", action: #selector(AppDelegate.copyDiagnosticInfo(_:)), keyEquivalent: "")
    diagnostics.target = appDelegate
    commandMenu.addItem(NSMenuItem.separator())
    let restart = commandMenu.addItem(withTitle: "Restart Command", action: #selector(AppDelegate.restartCommand(_:)), keyEquivalent: "")
    restart.target = appDelegate

    let helpMenuItem = NSMenuItem()
    mainMenu.addItem(helpMenuItem)
    let helpMenu = NSMenu(title: "Help")
    helpMenuItem.submenu = helpMenu
    NSApp.helpMenu = helpMenu
    for (title, selector) in [
        ("Command Help", #selector(AppDelegate.openDocumentation(_:))),
        ("User Guide", #selector(AppDelegate.openUserGuide(_:))),
        ("Troubleshooting", #selector(AppDelegate.openTroubleshooting(_:))),
        ("Support", #selector(AppDelegate.openSupport(_:))),
    ] {
        let item = helpMenu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        item.target = appDelegate
    }
    helpMenu.addItem(NSMenuItem.separator())
    let bug = helpMenu.addItem(withTitle: "Report a Bug", action: #selector(AppDelegate.reportBug(_:)), keyEquivalent: "")
    bug.target = appDelegate
    let feature = helpMenu.addItem(withTitle: "Request Feature", action: #selector(AppDelegate.requestFeature(_:)), keyEquivalent: "")
    feature.target = appDelegate

    NSApplication.shared.mainMenu = mainMenu
}

let app = NSApplication.shared
app.delegate = appDelegate
installMainMenu()
UserDefaults.standard.register(defaults: [
    "showDockIcon": false,
    "cliphistoryEnabled": false,
    "pickerTheme": "auto",
    VoiceSettingsKeys.dictationEnabled: VoiceSettingsDefaults.dictationEnabled,
    VoiceSettingsKeys.minDictationDuration: VoiceSettingsDefaults.minDictationDuration
])
applyDockPolicy()                 // menu-bar only unless the user enabled "Show in Dock"
preloadUISounds()
if MainActor.assumeIsolated({ offerMoveToApplicationsIfNeeded() }) { exit(0) }
guard ensureRuntimeDirectories() else {
    notify("Command setup failed", "Could not create local state directories. Copy Diagnostic Info and report this issue.")
    exit(1)
}
validateInstall()
installHotkeys()
startMediaKeyHook()
stopClipwatch()   // replace stale helper from a prior app process
startClipwatch()
startServer()
DispatchQueue.global(qos: .utility).async { pruneHandoffSubmissions() }
Task { @MainActor in scheduleAutoUpdateCheck() }

menuBar.install()                 // greyscale menu-bar icon + Set Up / Shortcuts / Help window
Task { @MainActor in await recorder.initModels() }  // warm Parakeet from cache if available
// First run: show onboarding wizard. Subsequent runs with permission problems: go straight to Setup.
func presentInitialWindowAfterLaunch() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        let route = initialWindowRoute(
            onboardingCompleted: UserDefaults.standard.bool(forKey: "onboardingCompleted"),
            postOnboardingOpenShortcuts: UserDefaults.standard.bool(forKey: "postOnboardingOpenShortcuts"),
            accessibilityGranted: axTrusted(),
            screenRecordingGranted: screenRecordingOK()
        )
        switch route {
        case .onboarding:
            onboardingWindow.showIfNeeded()
        case .shortcuts:
            if route.consumesPostOnboardingShortcutRequest {
                UserDefaults.standard.set(false, forKey: "postOnboardingOpenShortcuts")
            }
            settingsWindow.show(tab: .shortcuts)
        case .setup:
            settingsWindow.show(tab: .setup)
        case .none:
            break
        }
    }
}
presentInitialWindowAfterLaunch()
// Key handling while a window is up: the picker swallows keys while open; the
// Shortcuts editor swallows the next combo while recording a rebind.
NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { ev in
    if picker.handle(ev) { return nil }
    if settingsModel.handleRecording(ev) { return nil }
    return ev
}

// Cmd+C/X source capture is now handled inside the CGEventTap (startMediaKeyHook)
// at .cghidEventTap level — fires BEFORE the app writes to clipboard, so Clipboard History
// always sees the correct bundle. The old NSEvent.addGlobalMonitorForEvents fired
// AFTER the write (too late for deterministic source attribution).
let COPY_SOURCE_PATH = "\(HOME)/.claude/state/last_copy.json"

app.run()
