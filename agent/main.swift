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
let WORKER: String = {
    let dir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent   // …/CommandAgent.app -> tool dir
    return (dir as NSString).appendingPathComponent("send-to-claude.sh")
}()

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
    app.activate(options: [.activateIgnoringOtherApps])
}

// Post a user-facing banner (LSUIElement agent has no UI of its own otherwise).
func notify(_ title: String, _ body: String) {
    runShell("/usr/bin/osascript",
             ["-e", "display notification \"\(body)\" with title \"\(title)\""])
}

// ---- spawn the worker on a hotkey ------------------------------------------
func runWorker(_ action: String, source: String) {
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
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [WORKER]
    var env = ProcessInfo.processInfo.environment
    env["ACTION"] = action
    env["SOURCE_BUNDLE"] = source
    env["AGENT_SOCK"] = SOCK
    p.environment = env
    try? p.run()
}

// ---- clipboard history picker (built in) -----------------------------------

enum FilterMode { case all, images, text }
enum PickerTheme: String { case auto, light, dark }
enum PasteTarget { case prev, claude, claudeNew }

var iconCache: [String: NSImage] = [:]

func pickerTheme() -> PickerTheme {
    PickerTheme(rawValue: UserDefaults.standard.string(forKey: "pickerTheme") ?? "auto") ?? .auto
}
func setPickerTheme(_ t: PickerTheme) { UserDefaults.standard.set(t.rawValue, forKey: "pickerTheme") }

func appIcon(bundle: String) -> NSImage? {
    guard !bundle.isEmpty else { return nil }
    if let cached = iconCache[bundle] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
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
let pickerW: CGFloat = 640
let pickerH: CGFloat = 440
let listColW: CGFloat = 230
let pickerRowH: CGFloat = 40

final class PickerPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class PickRow: NSView {
    var onPick: ((PasteTarget) -> Void)?
    override func layout() { super.layout(); layer?.cornerRadius = 6; layer?.cornerCurve = .continuous }
    @objc func clicked() {
        let mods = NSEvent.modifierFlags
        let target: PasteTarget = mods.contains(.command) && mods.contains(.shift) ? .claudeNew
                                 : mods.contains(.command) ? .claude : .prev
        onPick?(target)
    }
}

final class ClipPicker {
    var win: PickerPanel!
    var fx: NSVisualEffectView!
    let listStack = NSStackView()
    var previewPane: NSView!
    var listWidthConstraint: NSLayoutConstraint?
    var all: [Clip] = [], shown: [Clip] = [], rows: [PickRow] = []
    var selected = 0, filterMode: FilterMode = .all, prevBundle = "", query = ""

    func show(prev: String) {
        prevBundle = prev
        all = loadClips(); filterMode = .all; selected = 0; query = ""
        if win == nil { build() }
        applyTheme()
        refresh()
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
        listStack.spacing = 2; listStack.translatesAutoresizingMaskIntoConstraints = false
    }

    func refresh() {
        shown = Array(filteredClips().prefix(14))
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

        previewPane = NSView(); previewPane.wantsLayer = true
        previewPane.translatesAutoresizingMaskIntoConstraints = false

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

        win.setContentSize(NSSize(width: pickerW, height: pickerH)); win.center()
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
        let iconName: String
        switch filterMode {
        case .images: iconName = "photo"
        case .text:   iconName = "doc.text"
        case .all:    iconName = "magnifyingglass"
        }
        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        searchIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let placeholder: String
        switch filterMode {
        case .images: placeholder = "Images only — ↑↓ browse"
        case .text:   placeholder = query.isEmpty ? "Text only — type to search" : query
        case .all:    placeholder = query.isEmpty ? "Search clipboard…" : query
        }
        let lbl = NSTextField(labelWithString: placeholder)
        lbl.font = .systemFont(ofSize: 13)
        lbl.textColor = (query.isEmpty && filterMode == .all) ? .tertiaryLabelColor : .labelColor
        lbl.lineBreakMode = .byTruncatingTail
        lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lbl.translatesAutoresizingMaskIntoConstraints = false

        let badge = makeFilterBadge()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [searchIcon, lbl, badge])
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
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 4
        stack.addArrangedSubview(makePill("All", active: filterMode == .all))
        stack.addArrangedSubview(makeIconPill("photo",    active: filterMode == .images))
        stack.addArrangedSubview(makeIconPill("doc.text", active: filterMode == .text))
        return stack
    }

    private func makePill(_ text: String, active: Bool) -> NSView {
        let v = NSView(); v.wantsLayer = true
        v.layer?.cornerRadius = 4; v.layer?.cornerCurve = .continuous
        v.layer?.backgroundColor = active
            ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            : NSColor.labelColor.withAlphaComponent(0.06).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10, weight: active ? .semibold : .regular)
        l.textColor = active ? .controlAccentColor : .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.widthAnchor.constraint(equalToConstant: 28), v.heightAnchor.constraint(equalToConstant: 20),
        ])
        return v
    }

    private func makeIconPill(_ sym: String, active: Bool) -> NSView {
        let v = NSView(); v.wantsLayer = true
        v.layer?.cornerRadius = 4; v.layer?.cornerCurve = .continuous
        v.layer?.backgroundColor = active
            ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            : NSColor.labelColor.withAlphaComponent(0.06).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        iv.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 12).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 12).isActive = true
        v.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.widthAnchor.constraint(equalToConstant: 24), v.heightAnchor.constraint(equalToConstant: 20),
        ])
        return v
    }

    func makeHint() -> NSView {
        let v = NSView()
        let t = NSTextField(labelWithString: "↑↓ · ← img · → txt · ↩ paste · ⌘↩ Claude · ⌘⇧↩ Claude new · esc")
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

        // Source app icon (18×18)
        let appIV = NSImageView()
        if let icon = appIcon(bundle: c.bundle) {
            appIV.image = icon
        } else {
            appIV.image = NSImage(systemSymbolName: c.type == "image" ? "photo" : "doc.text", accessibilityDescription: nil)
            appIV.contentTintColor = .tertiaryLabelColor
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
            if let img = NSImage(contentsOfFile: imgPath) { iv.image = img }
            iv.imageScaling = .scaleProportionallyDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 3; iv.layer?.cornerCurve = .continuous; iv.layer?.masksToBounds = true
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 36).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 24).isActive = true
            h.addArrangedSubview(iv)
            let tag = NSTextField(labelWithString: "image")
            tag.font = .systemFont(ofSize: 12); tag.textColor = .secondaryLabelColor
            h.addArrangedSubview(tag)
        } else {
            let one = c.preview.replacingOccurrences(of: "\n", with: " ")
            let lbl = NSTextField(labelWithString: one.isEmpty ? "(empty)" : one)
            lbl.lineBreakMode = .byTruncatingTail
            lbl.font = .systemFont(ofSize: 12); lbl.textColor = .labelColor
            lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            h.addArrangedSubview(lbl)
        }

        let ts = NSTextField(labelWithString: ageString(c.ts))
        ts.font = .systemFont(ofSize: 10); ts.textColor = .tertiaryLabelColor
        ts.setContentHuggingPriority(.required, for: .horizontal)
        h.addArrangedSubview(ts)

        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor),
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
                ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        }
        updatePreview()
    }

    func updatePreview() {
        guard previewPane != nil else { return }
        previewPane.subviews.forEach { $0.removeFromSuperview() }
        guard selected < shown.count else { return }
        let c = shown[selected]
        let path = (CLIPS as NSString).appendingPathComponent(c.file)

        var meta: [String] = []
        if !c.bundle.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.bundle) {
            meta.append(url.deletingPathExtension().lastPathComponent)
        }
        if c.ts > 0 { meta.append(ageString(c.ts) + " ago") }
        let metaLbl = NSTextField(labelWithString: meta.joined(separator: "  ·  "))
        metaLbl.font = .systemFont(ofSize: 10); metaLbl.textColor = .tertiaryLabelColor
        metaLbl.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(metaLbl)
        NSLayoutConstraint.activate([
            metaLbl.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 12),
            metaLbl.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -12),
            metaLbl.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor, constant: -8),
        ])

        if c.type == "image", let img = NSImage(contentsOfFile: path) {
            let iv = NSImageView(); iv.image = img
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 6; iv.layer?.cornerCurve = .continuous; iv.layer?.masksToBounds = true
            iv.translatesAutoresizingMaskIntoConstraints = false
            previewPane.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 10),
                iv.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -10),
                iv.topAnchor.constraint(equalTo: previewPane.topAnchor, constant: 10),
                iv.bottomAnchor.constraint(equalTo: metaLbl.topAnchor, constant: -6),
            ])
        } else {
            let body = c.full.isEmpty ? c.preview : c.full
            let tv = NSTextField(wrappingLabelWithString: body.isEmpty ? "(empty)" : String(body.prefix(800)))
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textColor = .labelColor
            tv.translatesAutoresizingMaskIntoConstraints = false
            previewPane.addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 12),
                tv.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -12),
                tv.topAnchor.constraint(equalTo: previewPane.topAnchor, constant: 12),
                tv.bottomAnchor.constraint(lessThanOrEqualTo: metaLbl.topAnchor, constant: -6),
            ])
        }
    }

    func handle(_ ev: NSEvent) -> Bool {
        if !isVisible { return false }
        let cmd = ev.modifierFlags.contains(.command)
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
        case 123:  // ← → images only (toggle)
            filterMode = (filterMode == .images) ? .all : .images
            query = ""; selected = 0; refresh()
            return true
        case 124:  // → → text only (toggle)
            filterMode = (filterMode == .text) ? .all : .text
            query = ""; selected = 0; refresh()
            return true
        case 36, 76:   // ↩ / numpad ↩
            if selected < shown.count {
                let shift = ev.modifierFlags.contains(.shift)
                let target: PasteTarget = cmd && shift ? .claudeNew : cmd ? .claude : .prev
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
        let path = (CLIPS as NSString).appendingPathComponent(c.file)
        let pb = NSPasteboard.general
        pb.clearContents()
        if c.type == "image", let data = FileManager.default.contents(atPath: path) {
            if let img = NSImage(data: data) { pb.writeObjects([img]) } else { pb.setData(data, forType: .png) }
        } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            pb.setString(text, forType: .string)
        }
        win.orderOut(nil)
        switch target {
        case .prev:
            activate(prevBundle); usleep(200_000); postKey(kV, cmd: true)
        case .claude:
            activate(CLAUDE_BUNDLE); usleep(200_000); postKey(kV, cmd: true)
        case .claudeNew:
            activate(CLAUDE_BUNDLE); usleep(200_000)
            postKey(45, cmd: true)   // ⌘N = new conversation in Claude desktop
            usleep(300_000); postKey(kV, cmd: true)
        }
        NSApp.hide(nil)
    }
}

let picker = ClipPicker()

// ---- Carbon global hotkeys -------------------------------------------------
struct HK { let action: String; let keycode: UInt32; let mods: UInt32 }

func loadHotkeys() -> [HK] {
    guard let data = FileManager.default.contents(atPath: CFG),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
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
            DispatchQueue.main.async { picker.show(prev: front) }
        } else if action == "settings" {
            DispatchQueue.main.async { settingsWindow.show(tab: .setup) }
        } else {
            DispatchQueue.global().async { runWorker(action, source: front) }
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

// Start the bundled clipboard watcher as a child process.
// Checks if already running first (safe to call on KeepAlive restarts).
func startClipwatch() {
    guard let script = Bundle.main.path(forResource: "clipwatch", ofType: "py") else { return }
    guard runShell("/usr/bin/pgrep", ["-f", "clipwatch.py"]).code != 0 else { return }
    let logDir = "\(HOME)/.claude/logs"
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
    try? p.run()
}

let app = NSApplication.shared
app.delegate = appDelegate
UserDefaults.standard.register(defaults: ["showDockIcon": false])  // no dock icon by default
applyDockPolicy()                 // menu-bar only unless the user enabled "Show in Dock"
installHotkeys()
startClipwatch()
startServer()

menuBar.install()                 // greyscale menu-bar icon + Set Up / Shortcuts / Help window
onboardingWindow.showIfNeeded()   // step-by-step wizard if Accessibility or Screen Recording missing
// Key handling while a window is up: the picker swallows keys while open; the
// Shortcuts editor swallows the next combo while recording a rebind.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
    if picker.handle(ev) { return nil }
    if settingsModel.handleRecording(ev) { return nil }
    return ev
}
app.run()
