// CommandAgent — the one persistent piece of Claude Command. A single
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
                   "Enable Claude Command, then menu-bar icon ▸ Restart Agent to apply it.")
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
struct Clip { let type: String; let file: String; let preview: String; let full: String; let ts: Double }

func loadClips() -> [Clip] {
    let idx = (CLIPS as NSString).appendingPathComponent("index.json")
    guard let data = FileManager.default.contents(atPath: idx),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    // Hide anything past the retention window even if the daemon hasn't pruned yet.
    let cutoff = Date().timeIntervalSince1970 - Double(readRetentionDays()) * 86400
    return arr.compactMap { d in
        guard let t = d["type"] as? String, let f = d["file"] as? String else { return nil }
        let ts = (d["ts"] as? Double) ?? Double((d["ts"] as? Int) ?? 0)
        if ts > 0 && ts < cutoff { return nil }
        return Clip(type: t, file: f,
                    preview: (d["preview"] as? String) ?? "",
                    full: (d["full"] as? String) ?? "",
                    ts: ts)
    }
}

final class PickerPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class PickRow: NSView {
    var onPick: ((Bool) -> Void)?     // Bool = sticky (⌘ held)
    override func layout() { super.layout(); layer?.cornerRadius = 9 }
    @objc func clicked() { onPick?(NSEvent.modifierFlags.contains(.command)) }
}

final class Picker {
    var win: PickerPanel!
    var fx: NSVisualEffectView!
    let listStack = NSStackView()
    var all: [Clip] = [], shown: [Clip] = [], rows: [PickRow] = []
    var selected = 0, imagesOnly = false, prevBundle = "", query = ""
    var previewBox: NSView!
    let W: CGFloat = 600, rowH: CGFloat = 46, pad: CGFloat = 14, headerH: CGFloat = 52, previewH: CGFloat = 150

    func show(prev: String) {
        prevBundle = prev
        all = loadClips(); imagesOnly = false; selected = 0; query = ""
        if win == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { win != nil && win.isVisible }

    func build() {
        win = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: 320),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = true
        win.level = .floating; win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .transient]

        fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16; fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1; fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        win.contentView = fx

        listStack.orientation = .vertical; listStack.alignment = .leading
        listStack.spacing = 4; listStack.translatesAutoresizingMaskIntoConstraints = false
    }

    // What to show: images-only mode → images; a query → matching text clips
    // (images hidden); otherwise the most recent clips.
    func filteredClips() -> [Clip] {
        if imagesOnly { return all.filter { $0.type == "image" } }
        if !query.isEmpty {
            let q = query.lowercased()
            return all.filter { $0.type != "image" &&
                ($0.full.lowercased().contains(q) || $0.preview.lowercased().contains(q)) }
        }
        return all
    }

    // Search box + hint line (the header rebuilt each refresh).
    func makeHeader() -> NSView {
        let box = NSView(); box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let glyph = NSTextField(labelWithString: imagesOnly ? "🖼" : "🔍")
        glyph.font = .systemFont(ofSize: 13); glyph.translatesAutoresizingMaskIntoConstraints = false
        let q = NSTextField(labelWithString:
            imagesOnly ? "Images — ↑↓ to browse" : (query.isEmpty ? "Search clipboard…" : query))
        q.font = .systemFont(ofSize: 13)
        q.textColor = (!imagesOnly && query.isEmpty) ? .tertiaryLabelColor : .labelColor
        q.lineBreakMode = .byTruncatingTail
        q.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        q.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSStackView(views: [glyph, q])
        inner.orientation = .horizontal; inner.alignment = .centerY; inner.spacing = 8
        inner.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])

        let hint = NSTextField(labelWithString: "⏎ paste · ⌘⏎ keep open · ⌘I images · esc")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let v = NSStackView(views: [box, hint])
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 5
        v.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        return v
    }

    func makeRow(_ i: Int, _ c: Clip) -> PickRow {
        let row = PickRow(); row.wantsLayer = true
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: rowH).isActive = true
        let h = NSStackView()
        h.orientation = .horizontal; h.alignment = .centerY; h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        h.translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSTextField(labelWithString: c.type == "image" ? "🖼" : "📄")
        glyph.font = .systemFont(ofSize: 15)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.widthAnchor.constraint(equalToConstant: 22).isActive = true
        h.addArrangedSubview(glyph)
        if c.type == "image",
           let img = NSImage(contentsOfFile: (CLIPS as NSString).appendingPathComponent(c.file)) {
            let iv = NSImageView(); iv.image = img; iv.imageScaling = .scaleProportionallyDown
            iv.wantsLayer = true; iv.layer?.cornerRadius = 4; iv.layer?.masksToBounds = true
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 60).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 32).isActive = true
            h.addArrangedSubview(iv)
            let tag = NSTextField(labelWithString: "image")
            tag.font = .systemFont(ofSize: 11, weight: .medium); tag.textColor = .tertiaryLabelColor
            h.addArrangedSubview(tag)
        } else {
            let one = c.preview.replacingOccurrences(of: "\n", with: " ")
            let lbl = NSTextField(labelWithString: one.isEmpty ? "(empty)" : one)
            lbl.lineBreakMode = .byTruncatingTail; lbl.font = .systemFont(ofSize: 13); lbl.textColor = .labelColor
            lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            h.addArrangedSubview(lbl)
        }
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            h.topAnchor.constraint(equalTo: row.topAnchor),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        row.addGestureRecognizer(NSClickGestureRecognizer(target: row, action: #selector(PickRow.clicked)))
        row.onPick = { [weak self] sticky in
            guard let s = self, i < s.shown.count else { return }
            s.choose(s.shown[i], sticky: sticky)
        }
        return row
    }

    func toggleImages() { imagesOnly.toggle(); query = ""; selected = 0; refresh() }

    func refresh() {
        shown = Array(filteredClips().prefix(12))
        selected = min(selected, max(0, shown.count - 1))
        fx.subviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        let header = makeHeader()

        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if shown.isEmpty {
            let msg = imagesOnly ? "No images in history." : (query.isEmpty ? "History empty." : "No matches.")
            let e = NSTextField(labelWithString: msg)
            e.font = .systemFont(ofSize: 13); e.textColor = .tertiaryLabelColor
            listStack.addArrangedSubview(e)
        } else {
            for (i, c) in shown.enumerated() {
                let r = makeRow(i, c); rows.append(r); listStack.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }

        previewBox = NSView(); previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 8
        previewBox.layer?.masksToBounds = true   // clip long text to the pane
        previewBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.heightAnchor.constraint(equalToConstant: previewH).isActive = true

        let outer = NSStackView(views: [header, listStack, previewBox])
        outer.orientation = .vertical; outer.alignment = .leading; outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: pad),
            outer.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -pad),
            outer.topAnchor.constraint(equalTo: fx.topAnchor, constant: pad),
            header.widthAnchor.constraint(equalTo: outer.widthAnchor),
            listStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            previewBox.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
        let n = max(1, shown.count)
        let listH = CGFloat(n) * rowH + CGFloat(max(0, n - 1)) * 4
        let height = pad + headerH + 10 + listH + 10 + previewH + pad
        win.setContentSize(NSSize(width: W, height: height)); win.center()
        highlight()
    }

    func highlight() {
        for (k, r) in rows.enumerated() {
            r.layer?.backgroundColor = (k == selected)
                ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        }
        updatePreview()
    }

    // Larger preview of the selected clip: big image, or fuller text.
    func updatePreview() {
        guard previewBox != nil else { return }
        previewBox.subviews.forEach { $0.removeFromSuperview() }
        guard selected < shown.count else { return }
        let c = shown[selected]
        let path = (CLIPS as NSString).appendingPathComponent(c.file)
        if c.type == "image", let img = NSImage(contentsOfFile: path) {
            let iv = NSImageView(); iv.image = img
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            previewBox.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
                iv.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),
                iv.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 8),
                iv.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -8),
            ])
        } else {
            let body = c.full.isEmpty ? c.preview : c.full
            let tv = NSTextField(wrappingLabelWithString: body.isEmpty ? "(empty)" : String(body.prefix(600)))
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textColor = .labelColor
            tv.preferredMaxLayoutWidth = W - 2 * pad - 16
            tv.translatesAutoresizingMaskIntoConstraints = false
            previewBox.addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
                tv.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),
                tv.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 8),
            ])
        }
    }

    // Returns true if it consumed the event (so the local monitor swallows it).
    func handle(_ ev: NSEvent) -> Bool {
        if !isVisible { return false }
        let cmd = ev.modifierFlags.contains(.command)
        switch ev.keyCode {
        case 53:   // esc: clear search → exit images → close
            if !query.isEmpty { query = ""; selected = 0; refresh() }
            else if imagesOnly { imagesOnly = false; selected = 0; refresh() }
            else { hide() }
            return true
        case 125: if !shown.isEmpty { selected = min(selected + 1, shown.count - 1); highlight() }; return true  // ↓
        case 126: if !shown.isEmpty { selected = max(selected - 1, 0); highlight() }; return true                // ↑
        case 36, 76: if selected < shown.count { choose(shown[selected], sticky: cmd) }; return true             // ⏎ / ⌘⏎
        case 51: if !query.isEmpty { query.removeLast(); selected = 0; refresh() }; return true                  // delete
        default: break
        }
        guard let ch = ev.charactersIgnoringModifiers, !ch.isEmpty else { return true }
        if cmd {
            if ch.lowercased() == "i" { toggleImages() }
            return true   // swallow other ⌘ combos while open
        }
        if ch == "i" && query.isEmpty { toggleImages(); return true }   // bare i on empty box → images mode
        if let u = ch.unicodeScalars.first, u.value >= 32, u.value != 127 {
            if imagesOnly { imagesOnly = false }   // typing exits images mode into a search
            query.append(ch); selected = 0; refresh()
        }
        return true   // window is modal-ish; swallow stray keys while open
    }

    func hide() { win?.orderOut(nil); NSApp.hide(nil) }

    func choose(_ c: Clip, sticky: Bool) {
        let path = (CLIPS as NSString).appendingPathComponent(c.file)
        let pb = NSPasteboard.general
        pb.clearContents()
        if c.type == "image", let data = FileManager.default.contents(atPath: path) {
            if let img = NSImage(data: data) { pb.writeObjects([img]) } else { pb.setData(data, forType: .png) }
        } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            pb.setString(text, forType: .string)
        }
        if sticky {
            // Paste into the prior app, then jump back to the picker for more.
            activate(prevBundle); usleep(170_000); postKey(kV, cmd: true); usleep(120_000)
            NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
        } else {
            win.orderOut(nil)
            activate(prevBundle); usleep(170_000); postKey(kV, cmd: true)
            NSApp.hide(nil)
        }
    }
}

let picker = Picker()

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
let app = NSApplication.shared
app.delegate = appDelegate
applyDockPolicy()                 // menu-bar only unless the user enabled "Show in Dock"
installHotkeys()
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
