// CommandAgent — the one persistent piece of ClaudeCommand. A single
// always-running, LSUIElement background app with its OWN stable TCC identity
// (com.claudecommand.agent), granted Accessibility once. It does everything
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
import Darwin

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

func postKey(_ k: CGKeyCode, cmd: Bool) {
    let s = CGEventSource(stateID: .combinedSessionState)
    guard let d = CGEvent(keyboardEventSource: s, virtualKey: k, keyDown: true),
          let u = CGEvent(keyboardEventSource: s, virtualKey: k, keyDown: false) else { return }
    if cmd { d.flags = .maskCommand; u.flags = .maskCommand }
    d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
}

func activate(_ bundle: String) {
    guard !bundle.isEmpty,
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return }
    if #available(macOS 14.0, *) {
        app.activate()
    } else {
        app.activate(options: [.activateIgnoringOtherApps])
    }
}

// Poll until `bundle` is the frontmost app, then return. Caps at ~300ms.
func waitForActive(_ bundle: String) {
    guard !bundle.isEmpty else { return }
    for _ in 0..<30 {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .first?.isActive == true { return }
        usleep(10_000)
    }
}

// Post a user-facing banner (LSUIElement agent has no UI of its own otherwise).
func notify(_ title: String, _ body: String) {
    runShell("/usr/bin/osascript",
             ["-e", "display notification \"\(body)\" with title \"\(title)\""])
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
    for _ in 0..<20 {                          // poll up to 200ms in 10ms steps
        usleep(10_000)
        if NSPasteboard.general.changeCount != cc0 {
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
    }
    return ""
}

func runWorker(_ action: String, source: String, captured: String = "") {
    // Screenshot actions need Screen Recording. Without it, `screencapture` fails
    // ("could not create image from rect") and the user just re-prompts forever.
    // Gate it: fire the system prompt + open Set Up, and skip the doomed capture.
    // The grant only takes effect once this process relaunches (TCC reads it at
    // launch), so point the user at "Restart Agent".
    if action.hasPrefix("shot") && !screenRecordingOK() {
        DispatchQueue.main.async {
            requestScreenRecording()
            openPrivacyPane("Privacy_ScreenCapture")
            settingsWindow.show(tab: .setup)
            notify("Screen Recording needed",
                   "Enable ClaudeCommand, then menu-bar icon ▸ Restart Agent to apply it.")
        }
        return
    }
    guard FileManager.default.fileExists(atPath: WORKER) else {
        let msg = "[runWorker] WORKER not found at \(WORKER) — reinstall the app"
        appendLog(msg)
        notify("ClaudeCommand broken", "send-to-claude.sh missing. Run install-agent.sh.")
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [WORKER]
    var env = ProcessInfo.processInfo.environment
    env["ACTION"] = action
    env["SOURCE_BUNDLE"] = source
    env["AGENT_SOCK"] = SOCK
    if !captured.isEmpty { env["CAPTURED_TEXT"] = captured }
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
            }
        }
    } catch {
        appendLog("[runWorker] launch failed: \(error)")
    }
}

func appendLog(_ msg: String) {
    for path in ["\(HOME)/.claude/logs/command-agent.err",
                 "\(HOME)/.claude/logs/attribution.log"] {
        let line = msg + "\n"
        guard let data = line.data(using: .utf8) else { continue }
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(data); fh.closeFile() }
        else { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}

// ---- clipboard history picker (built in) -----------------------------------

enum FilterMode { case all, images, text }
enum PickerTheme: String { case auto, light, dark }
enum PasteTarget { case prev, claude, claudeNew }

var iconCache: [String: NSImage] = [:]

// True purple — not systemPurple which renders burgundy in some themes
let purpleAccent = NSColor(red: 112/255, green: 40/255, blue: 215/255, alpha: 1.0)

func pickerTheme() -> PickerTheme {
    PickerTheme(rawValue: UserDefaults.standard.string(forKey: "pickerTheme") ?? "light") ?? .light
}
func setPickerTheme(_ t: PickerTheme) { UserDefaults.standard.set(t.rawValue, forKey: "pickerTheme") }

func appIcon(bundle: String) -> NSImage? {
    guard !bundle.isEmpty else { return nil }
    if let cached = iconCache[bundle] { return cached }
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
    let full: String; let ts: Double; let bundle: String
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
                    bundle: (d["bundle"] as? String) ?? "")
    }
}

let CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"
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
    var onPick: ((PasteTarget) -> Void)?
    override func layout() { super.layout(); layer?.cornerRadius = 6; layer?.cornerCurve = .continuous }
    @objc func clicked() {
        let mods = NSEvent.modifierFlags
        let target: PasteTarget = mods.contains(.command) ? .claudeNew
                                 : mods.contains(.option) ? .claude : .prev
        onPick?(target)
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
            case .images: msg = "No images in history."
            case .text:   msg = query.isEmpty ? "No text clips." : "No matches."
            case .all:    msg = query.isEmpty ? "History empty." : "No matches."
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
        // Order: [🖼 Images] [● All] [Aa Text] — All in center per user request.
        let specs: [(sym: String?, label: String, mode: FilterMode)] = [
            ("photo",    "Images", .images),
            (nil,        "All",    .all),
            ("doc.text", "Text",   .text),
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

        // Icon-only for pills that have a symbol; text-only for "All".
        let content = NSStackView(); content.orientation = .horizontal; content.spacing = 3
        content.translatesAutoresizingMaskIntoConstraints = false
        if let sym = sym {
            let iv = NSImageView()
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: active ? .semibold : .medium)
            iv.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            iv.contentTintColor = active ? purpleAccent : .labelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 13).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 13).isActive = true
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
        let t = NSTextField(labelWithString: "↑↓ · 1-9 pick · ↩ prev · ⌘↩ new · ⌥↩ Claude · esc")
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
            appIV.image = NSImage(systemSymbolName: c.type == "image" ? "photo" : "doc.text", accessibilityDescription: nil)
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
        h.addArrangedSubview(appIV)

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
        row.onPick = { [weak self] target in
            guard let s = self, i < s.shown.count else { return }
            s.choose(s.shown[i], target: target)
        }
        return row
    }

    func filteredClips() -> [Clip] {
        switch filterMode {
        case .images: return all.filter { $0.type == "image" }
        case .text:
            let base = all.filter { $0.type != "image" }
            if query.isEmpty { return base }
            let q = query.lowercased()
            return base.filter { $0.full.lowercased().contains(q) || $0.preview.lowercased().contains(q) }
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
        case 123:  // ← rotate carousel left: Images←All←Text←Images
            let leftCycle: [FilterMode] = [.images, .all, .text]
            let li = leftCycle.firstIndex(of: filterMode) ?? 1
            filterMode = leftCycle[(li + leftCycle.count - 1) % leftCycle.count]
            query = ""; selected = 0; refresh()
            return true
        case 124:  // → rotate carousel right: Images→All→Text→Images
            let rightCycle: [FilterMode] = [.images, .all, .text]
            let ri = rightCycle.firstIndex(of: filterMode) ?? 1
            filterMode = rightCycle[(ri + 1) % rightCycle.count]
            query = ""; selected = 0; refresh()
            return true
        case 36, 76:   // ↩ / numpad ↩
            if selected < shown.count {
                let opt = ev.modifierFlags.contains(.option)
                let target: PasteTarget = cmd ? .claudeNew : opt ? .claude : .prev
                choose(shown[selected], target: target)
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
        let savedBundle = prevBundle
        let path = (CLIPS as NSString).appendingPathComponent(c.file)
        // Stamp last_copy.json as our own bundle before writing to clipboard so
        // clipwatch (which polls at 25ms) attributes this write to com.claudecommand
        // (in BLOCK_BUNDLES) and doesn't add it to history as a spurious entry.
        if let d = try? JSONSerialization.data(withJSONObject: ["bundle": "com.claudecommand", "ts": Date().timeIntervalSince1970]) {
            try? d.write(to: URL(fileURLWithPath: COPY_SOURCE_PATH))
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        if c.type == "image", let data = FileManager.default.contents(atPath: path) {
            if let img = NSImage(data: data) { pb.writeObjects([img]) } else { pb.setData(data, forType: .png) }
        } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            pb.setString(text, forType: .string)
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
            openBundle(CLAUDE_BUNDLE)
            whenActive(CLAUDE_BUNDLE) {
                postKey(kV, cmd: true)
                NSApp.hide(nil)
            }
        case .claudeNew:
            openBundle(CLAUDE_BUNDLE)
            whenActive(CLAUDE_BUNDLE) {
                postKey(45, cmd: true)   // ⌘N — open new Claude window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    postKey(kV, cmd: true)
                    NSApp.hide(nil)
                }
            }
        }
    }
}

let picker = ClipPicker()

// ---- Carbon global hotkeys -------------------------------------------------
struct HK { let action: String; let keycode: UInt32; let mods: UInt32 }

func loadHotkeys() -> [HK] {
    guard let data = FileManager.default.contents(atPath: CFG),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        // No user file — fall back to built-in defaults.
        return DEFAULT_BINDINGS.map { HK(action: $0.action, keycode: $0.keycode, mods: $0.mods) }
    }
    return arr.compactMap { d in
        guard let a = d["action"] as? String,
              let k = d["keycode"] as? Int, let m = d["mods"] as? Int else { return nil }
        let enabled = (d["enabled"] as? Bool) ?? true
        guard enabled else { return nil }
        return HK(action: a, keycode: UInt32(k), mods: UInt32(m))
    }
}

var hotkeyActions: [UInt32: String] = [:]
var hotkeyRefs: [EventHotKeyRef?] = []

let hotKeyHandler: EventHandlerUPP = { (_, event, _) -> OSStatus in
    var hkID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    if let action = hotkeyActions[hkID.id] {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if action == "cliphistory" {
            DispatchQueue.main.async { if picker.isVisible { picker.hide() } else { picker.show(prev: front) } }
        } else if action == "settings" {
            DispatchQueue.main.async { settingsWindow.show(tab: .setup) }
        } else if action == "dictate" {
            Task { @MainActor in
                if DictationOverlay.shared.isVisible { DictationOverlay.shared.stopRecording() }
                else {
                    if let s = NSSound(named: NSSound.Name("Tink")) { s.volume = 0.4; s.play() }
                    DictationOverlay.shared.show(mode: .insert)
                }
            }
        } else if action == "dictateadd" {
            Task { @MainActor in
                if DictationOverlay.shared.isVisible { DictationOverlay.shared.stopRecording() }
                else {
                    if let s = NSSound(named: NSSound.Name("Tink")) { s.volume = 0.4; s.play() }
                    DictationOverlay.shared.show(mode: .claude)
                }
            }
        } else {
            // Capture selection NOW (main thread, source app still focused)
            // before async dispatch; worker uses CAPTURED_TEXT, skips socket roundtrip.
            let sel = action.hasPrefix("shot") ? "" : captureSelectionSync()
            DispatchQueue.global().async { runWorker(action, source: front, captured: sel) }
        }
    }
    return noErr
}

func installHotkeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    registerFromConfig()
}

// (Re)register every hotkey from CFG. Safe to call repeatedly — the Shortcuts
// editor calls this in-process after a rebind, so no agent restart is needed.
func registerFromConfig() {
    for ref in hotkeyRefs { if let r = ref { UnregisterEventHotKey(r) } }
    hotkeyRefs.removeAll()
    hotkeyActions.removeAll()
    let sig = OSType(0x434D4447) // 'CMDG'
    for (i, hk) in loadHotkeys().enumerated() {
        guard hk.keycode != 0 else { continue }  // keycode 0 = 'A' key; 0 means unbound
        let id = EventHotKeyID(signature: sig, id: UInt32(i + 1))
        hotkeyActions[UInt32(i + 1)] = hk.action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(hk.keycode, hk.mods, id, GetApplicationEventTarget(), 0, &ref)
        hotkeyRefs.append(ref)
    }
}

func reregisterHotkeys() { registerFromConfig() }

// Temporarily drop all global hotkeys (so recording a rebind in the Shortcuts
// editor doesn't also trigger the action that combo is currently bound to).
func unregisterAllHotkeys() {
    for ref in hotkeyRefs { if let r = ref { UnregisterEventHotKey(r) } }
    hotkeyRefs.removeAll()
    hotkeyActions.removeAll()
}

// ---- Media-key intercept (F7/F8/F9 = prev/play/next) ----------------------
// Carbon RegisterEventHotKey never sees these keys when macOS is in media-key
// mode (the default). We tap at the HID level, check our own hotkey config,
// and fire the action while swallowing the event so Spotify etc. don't also see it.

// NX media key type → Carbon keycode for the same physical key.
let MEDIA_TO_CARBON: [Int: UInt32] = [
    16: 100,   // NX_KEYTYPE_PLAY      → F8
    17: 101,   // NX_KEYTYPE_NEXT      → F9
    18: 98,    // NX_KEYTYPE_PREVIOUS  → F7 (some Macs)
    19: 101,   // NX_KEYTYPE_FAST      → F9 (some Macs)
    20: 98,    // NX_KEYTYPE_REWIND    → F7 (some Macs)
]

private var _mediaEventTap: CFMachPort?
// NX_SYSDEFINED events fire repeating isDown=true while held (no autorepeat flag).
// Track held state per keyCode to swallow repeats without breaking double-tap detection.
private var _nxHeld: [Int: Bool] = [:]

// ---- Dictation trigger state machine (matches DictationLab v2) ----------------
// Single tap → PTT (hold to talk; CGEventSource poll releases on key-up)
// Tap while PTT → lock (hands-free; keep recording until next tap)
// Tap while locked → stop + paste
// Double-tap from idle (within 350ms) → jump straight to lock
private enum DictTrigMode { case idle, pushToTalk, lock }
private var _dictTrigMode: DictTrigMode = .idle
private var _dictPTTimer: Timer? = nil
private var _dictLastPress: Double = 0
private let _dictDoubleTapWindow: Double = 0.35

@MainActor
func resetDictTrigMode() {
    _dictPTTimer?.invalidate(); _dictPTTimer = nil
    _dictTrigMode = .idle
}

@MainActor
func triggerDictation(mode: DictMode, keycode: CGKeyCode) {
    switch _dictTrigMode {
    case .lock:
        resetDictTrigMode()
        if DictationOverlay.shared.isVisible { DictationOverlay.shared.stopRecording() }

    case .pushToTalk:
        _dictPTTimer?.invalidate(); _dictPTTimer = nil
        _dictTrigMode = .lock   // hands-free: keep recording until next tap

    case .idle:
        let now = Date().timeIntervalSinceReferenceDate
        let isDouble = (now - _dictLastPress) < _dictDoubleTapWindow
        _dictLastPress = now

        if !DictationOverlay.shared.isVisible {
            if let s = NSSound(named: NSSound.Name("Tink")) { s.volume = 0.4; s.play() }
            DictationOverlay.shared.show(mode: mode)
        }

        if isDouble {
            _dictTrigMode = .lock
        } else {
            _dictTrigMode = .pushToTalk
            _dictPTTimer?.invalidate()
            _dictPTTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { t in
                MainActor.assumeIsolated {
                    guard _dictTrigMode == .pushToTalk else { t.invalidate(); return }
                    if !CGEventSource.keyState(.hidSystemState, key: keycode) {
                        t.invalidate(); _dictPTTimer = nil
                        _dictTrigMode = .idle
                        if DictationOverlay.shared.isVisible { DictationOverlay.shared.stopRecording() }
                    }
                }
            }
        }
    }
}

func fireMediaAction(_ carbon: UInt32, mods: UInt32 = 0) {
    let hks = loadHotkeys()
    guard let hk = hks.first(where: { $0.keycode == carbon && $0.mods == mods }) else { return }
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

    // Shot actions: if screencapture is already running (user pressed again to cancel), kill it.
    if hk.action.hasPrefix("shot") {
        let pg = runShell("/usr/bin/pgrep", ["-x", "screencapture"])
        if pg.code == 0 {
            _ = runShell("/usr/bin/pkill", ["-x", "screencapture"])
            return
        }
    }

    if hk.action == "cliphistory" {
        if picker.isVisible { picker.hide() } else { picker.show(prev: front) }
    } else if hk.action == "settings" {
        settingsWindow.show(tab: .setup)
    } else if hk.action == "dictate" {
        Task { @MainActor in triggerDictation(mode: .insert, keycode: CGKeyCode(carbon)) }
    } else if hk.action == "dictateadd" {
        Task { @MainActor in triggerDictation(mode: .claude, keycode: CGKeyCode(carbon)) }
    } else {
        let sel = hk.action.hasPrefix("shot") ? "" : captureSelectionSync()
        DispatchQueue.global().async { runWorker(hk.action, source: front, captured: sel) }
    }
}

// Carbon keycodes that are also media keys — tap keyDown for these directly
// so we intercept before Chrome/Carbon/Spotify regardless of keyboard mode.
let MEDIA_KEYCODES: Set<UInt32> = [96, 97, 98, 99, 100, 101]  // F5–F10

func startMediaKeyHook() {
    guard AXIsProcessTrusted() else { return }
    // Intercept NX_SYSDEFINED (media-key mode) and keyDown only.
    // PTT polling uses CGEventSource.keyState on a 40ms timer — no keyUp needed.
    let eventMask = CGEventMask((1 << 14) | (1 << CGEventType.keyDown.rawValue))
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: eventMask,
        callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
            let passthrough = Unmanaged.passRetained(event)

            // --- media-key mode (NX_SYSDEFINED subtype 8) ---
            if type.rawValue == 14,
               let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
                let keyCode = Int((ns.data1 & 0xFFFF0000) >> 16)
                let isDown  = ((Int(ns.data1) & 0xFF00) >> 8) == 0xA
                appendLog("[eventTap] NX_SYSDEFINED keyCode=\(keyCode) isDown=\(isDown) carbon=\(MEDIA_TO_CARBON[keyCode] ?? 0)")
                if !isDown {
                    _nxHeld[keyCode] = false   // key released — next isDown is a genuine press
                    return passthrough
                }
                // Swallow NX key-repeat: isDown=true fires repeatedly while held.
                // wasHeld=true means the key never released — this is a repeat, not a new tap.
                if _nxHeld[keyCode] == true { return nil }
                _nxHeld[keyCode] = true
                guard let carbon = MEDIA_TO_CARBON[keyCode] else { return passthrough }
                let bound = loadHotkeys().contains { $0.keycode == carbon && $0.mods == 0 }
                appendLog("[eventTap] NX bound=\(bound) carbon=\(carbon)")
                guard bound else { return passthrough }
                DispatchQueue.main.async { fireMediaAction(carbon) }
                return nil
            }

            // --- standard function-key mode (regular keyDown) ---
            if type == .keyDown {
                let kc = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                let f  = event.flags

                // Capture copy/cut source at keypress time — fires BEFORE the app writes to
                // clipboard, so clipwatch's 25ms poll always sees the correct bundle.
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

                guard MEDIA_KEYCODES.contains(kc) else { return passthrough }
                // Skip key-repeat events — only fire on the initial key-down.
                // Without this, holding a bound key fires start→stop→start... rapidly.
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                guard !isRepeat else { return nil }  // swallow repeat but don't act
                var cm: UInt32 = 0
                if f.contains(.maskCommand)   { cm |= 256 }
                if f.contains(.maskShift)     { cm |= 512 }
                if f.contains(.maskAlternate) { cm |= 2048 }
                if f.contains(.maskControl)   { cm |= 4096 }
                let bound = loadHotkeys().contains { $0.keycode == kc && $0.mods == cm }
                appendLog("[eventTap] keyDown kc=\(kc) mods=\(cm) bound=\(bound)")
                guard bound else { return passthrough }
                DispatchQueue.main.async { fireMediaAction(kc, mods: cm) }
                return nil
            }

            return passthrough
        }, userInfo: nil)
    else { return }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    _mediaEventTap = tap
    // macOS auto-disables event taps that block. Re-enable every 5s so hotkeys survive.
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) { tapWatchdog() }
}

func tapWatchdog() {
    guard let tap = _mediaEventTap else { return }
    if !CGEvent.tapIsEnabled(tap: tap) {
        CGEvent.tapEnable(tap: tap, enable: true)
        appendLog("[tapWatchdog] re-enabled media event tap")
    }
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) { tapWatchdog() }
}

// ---- Unix-socket keystroke + picker service --------------------------------
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
    case "activate":
        if parts.count > 1 { let b = parts[1]; DispatchQueue.main.sync { activate(b) } }
        return "ok"
    case "showpicker":
        let b = parts.count > 1 ? parts[1] : ""
        DispatchQueue.main.async { picker.show(prev: b) }
        return "ok"
    case "hide":   // hide an app's windows (used to clear Claude before a screenshot)
        if parts.count > 1 { let b = parts[1]
            DispatchQueue.main.sync {   // sync: reply only once it's actually hidden
                NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.hide()
            } }
        return "ok"
    case "reloadhotkeys": DispatchQueue.main.async { reregisterHotkeys() }; return "ok"
    case "showsettings":  DispatchQueue.main.async { settingsWindow.show(tab: .setup) }; return "ok"
    case "restart":  // exit now; KeepAlive=true makes launchd relaunch us with fresh TCC grants
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }
        return "ok"
    case "ping": return "pong"
    default: return "err"
    }
}

func startServer() {
    unlink(SOCK)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return }
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
    if bound != 0 { return }
    // Owner-only: this socket accepts keystroke-synthesis + clipboard commands
    // backed by the app's Accessibility grant. Any local process that could
    // reach it could drive synthetic keystrokes into the focused app, so lock
    // it to the current user.
    chmod(SOCK, 0o600)
    listen(fd, 8)
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show(tab: .setup)
        return true
    }
}
let appDelegate = AppDelegate()

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

// Restart: remove socket so the fresh launchd instance passes anotherInstanceRunning,
// kickstart the LaunchAgent (launchd-owned, so KeepAlive works), then exit.
func restartApp() {
    DispatchQueue.global().async {
        try? FileManager.default.removeItem(atPath: SOCK)
        let uid = getuid()
        _ = runShell("/bin/launchctl", ["kickstart", "gui/\(uid)/com.claudecommand"])
        Thread.sleep(forTimeInterval: 0.15)
        exit(1)  // fallback: if kickstart failed, non-zero exit triggers KeepAlive
    }
}

func validateInstall() {
    let checks: [(String, String)] = [
        (WORKER, "send-to-claude.sh missing — reinstall"),
        (bundledResource("clipwatch.py"), "clipwatch.py missing — reinstall"),
    ]
    for (path, msg) in checks where !path.isEmpty && !FileManager.default.fileExists(atPath: path) {
        appendLog("[startup] \(msg): \(path)")
        notify("ClaudeCommand install broken", msg)
    }
}

func stopClipwatch() {
    _ = runShell("/usr/bin/pkill", ["-f", "clipwatch.py"])
}

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
    let script = bundledResource("clipwatch.py")
    dbg("script=\(script)")
    guard FileManager.default.fileExists(atPath: script) else { dbg("returning: no script at \(script)"); return }
    // Kill any stale clipwatch from a prior install before launching fresh.
    let pgrep = runShell("/usr/bin/pgrep", ["-f", "clipwatch.py"])
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
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [script]
    var env = ProcessInfo.processInfo.environment; env["HOME"] = HOME
    p.environment = env
    p.standardError = FileHandle(forWritingAtPath: errPath)
    p.terminationHandler = { proc in
        let code = proc.terminationStatus
        dbg("clipwatch exited code=\(code) — restarting in 2s")
        appendLog("[clipwatch] exited code=\(code) — restarting")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { startClipwatch() }
    }
    do { try p.run(); dbg("started pid=\(p.processIdentifier)") }
    catch { dbg("run failed: \(error)") }
}

let app = NSApplication.shared
app.delegate = appDelegate
UserDefaults.standard.register(defaults: ["showDockIcon": false, "cliphistoryEnabled": true])
applyDockPolicy()                 // menu-bar only unless the user enabled "Show in Dock"
validateInstall()
installHotkeys()
startMediaKeyHook()
stopClipwatch()   // kill any stale clipwatch from prior install before launching fresh
startClipwatch()
startServer()

menuBar.install()                 // greyscale menu-bar icon + Set Up / Shortcuts / Help window
Task { @MainActor in await recorder.initModels() }  // warm Parakeet from cache if available
// First run: show onboarding wizard. Subsequent runs with permission problems: go straight to Setup.
if UserDefaults.standard.bool(forKey: "onboardingCompleted") {
    if !axTrusted() || !screenRecordingOK() { settingsWindow.show(tab: .setup) }
} else {
    onboardingWindow.showIfNeeded()
}
// Key handling while a window is up: the picker swallows keys while open; the
// Shortcuts editor swallows the next combo while recording a rebind.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
    if picker.handle(ev) { return nil }
    if settingsModel.handleRecording(ev) { return nil }
    return ev
}

// Cmd+C/X source capture is now handled inside the CGEventTap (startMediaKeyHook)
// at .cghidEventTap level — fires BEFORE the app writes to clipboard, so clipwatch
// always sees the correct bundle. The old NSEvent.addGlobalMonitorForEvents fired
// AFTER the write (too late for clipwatch's 25ms poll).
let COPY_SOURCE_PATH = "\(HOME)/.claude/state/last_copy.json"

app.run()
