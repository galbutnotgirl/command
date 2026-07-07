// MenuBar.swift — the menu-bar icon and its menu.
// Menu: [actions with shortcut keys]  |  ─  |  Settings ⌘,  |  Quit ⌘Q
// Action items are rebuilt on each open (picks up binding changes live).
// Clicking an action item triggers it immediately, same as the hotkey.

import Cocoa

let menuBar = MenuBarController()

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var handoffItem: NSMenuItem?

    func install() { if !UserDefaults.standard.bool(forKey: "hideMenuBarIcon") { showIcon() } }

    func setRecording(_ on: Bool) {
        statusItem?.button?.image = on ? waveformIcon(level: 0) : brandIcon()
    }

    // Called ~15fps by DictationOverlay while recording; drives the reactive waveform icon.
    func updateAudioLevel(_ level: Float) {
        statusItem?.button?.image = waveformIcon(level: level)
    }

    // Reactive waveform icon:
    //   silent (< 0.03) → single thin purple line
    //   speaking → 4 purple bars scaled by audio level
    // Non-template so purple shows in the menu bar.
    private func waveformIcon(level: Float) -> NSImage {
        let h = NSStatusBar.system.thickness
        let img = NSImage(size: NSSize(width: h, height: h), flipped: false) { rect in
            let purple = NSColor(red: 0.44, green: 0.16, blue: 0.84, alpha: 1.0)
            purple.setFill()

            if level < 0.03 {
                // Silence: thin horizontal line
                let lh: CGFloat = 1.5
                let lw = rect.width * 0.62
                let x = (rect.width - lw) / 2
                let y = rect.midY - lh / 2
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: lw, height: lh),
                             xRadius: lh / 2, yRadius: lh / 2).fill()
            } else {
                // Voice: 4 bars, heights proportional to level
                let barW: CGFloat = 2.5
                let gap:  CGFloat = 2.0
                let count = 4
                let totalW = CGFloat(count) * barW + CGFloat(count - 1) * gap
                let startX = (rect.width - totalW) / 2
                let maxH   = rect.height * 0.80
                let midY   = rect.midY
                let scales: [Float] = [0.60, 1.00, 0.82, 0.68]
                for (i, sc) in scales.enumerated() {
                    let x  = startX + CGFloat(i) * (barW + gap)
                    let bh = max(2.0, maxH * CGFloat(level * sc))
                    let by = midY - bh / 2
                    NSBezierPath(roundedRect: NSRect(x: x, y: by, width: barW, height: bh),
                                 xRadius: barW / 2, yRadius: barW / 2).fill()
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    func showIcon() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button { btn.image = brandIcon() }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // Expose the status item button's screen frame so DictationOverlay can anchor below it.
    func statusItemButtonFrame() -> NSRect? {
        guard let btn = statusItem?.button, let window = btn.window else { return nil }
        let frameInWindow = btn.convert(btn.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    // Rebuild action items each time menu opens so binding changes are live.
    // Injects Stop/Cancel at top when dictation is active.
    func menuWillOpen(_ menu: NSMenu) {
        updateActionItems(in: menu)
        updateHandoffSubmenu()
        if DictationOverlay.shared.isVisible {
            let stopIt = NSMenuItem(title: "Stop Dictation", action: #selector(stopFromMenu), keyEquivalent: "")
            stopIt.target = self
            let cancelIt = NSMenuItem(title: "Cancel Dictation", action: #selector(cancelFromMenu), keyEquivalent: "")
            cancelIt.target = self
            menu.insertItem(stopIt, at: 0)
            menu.insertItem(cancelIt, at: 1)
            menu.insertItem(.separator(), at: 2)
        }
    }

    @objc private func stopFromMenu()   { Task { @MainActor in DictationOverlay.shared.stopRecording() } }
    @objc private func cancelFromMenu() { Task { @MainActor in DictationOverlay.shared.stopRecording() } }

    private func updateActionItems(in menu: NSMenu) {
        // Structure: [0..N-1]=actions | sep | Handoffs | Settings | Quit
        // Remove all action items (everything before the last 4 items).
        while menu.numberOfItems > 4 {
            menu.removeItem(at: 0)
        }
        let bindings = loadBindings()
        for (i, b) in bindings.enumerated() {
            let it = NSMenuItem()
            it.title = b.name
            it.representedObject = b.action
            let hasKey = b.keycode != 0
            it.isEnabled = hasKey && b.enabled
            it.target = it.isEnabled ? self : nil
            it.action = it.isEnabled ? #selector(runAction(_:)) : nil
            if hasKey, let kc = nsKeyChar(for: b.keycode) {
                it.keyEquivalent = kc
                it.keyEquivalentModifierMask = nsModifiers(from: b.mods)
            }
            if !b.enabled { it.state = .off }
            menu.insertItem(it, at: i)
        }
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if action == "cliphistory" {
            DispatchQueue.main.async { picker.show(prev: front) }
        } else if action == "handofftext" {
            DispatchQueue.main.async { HandoffTextEntryPanel.shared.show() }
        } else {
            DispatchQueue.global().async { runWorker(action, source: front) }
        }
    }

    // Map Carbon keycode → NSMenuItem keyEquivalent character.
    private func nsKeyChar(for carbonCode: UInt32) -> String? {
        let fkeys: [UInt32: UInt32] = [
            122: 0xF704, 120: 0xF705, 99: 0xF706, 118: 0xF707,
             96: 0xF708,  97: 0xF709, 98: 0xF70A, 100: 0xF70B,
            101: 0xF70C, 109: 0xF70D, 103: 0xF70E, 111: 0xF70F,
        ]
        if let scalar = fkeys[carbonCode], let u = Unicode.Scalar(scalar) { return String(u) }
        if let letter = KEYCODE_NAMES[carbonCode] { return letter.lowercased() }
        return nil
    }

    private func nsModifiers(from carbonMods: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonMods & 256  != 0 { f.insert(.command) }
        if carbonMods & 512  != 0 { f.insert(.shift) }
        if carbonMods & 2048 != 0 { f.insert(.option) }
        if carbonMods & 4096 != 0 { f.insert(.control) }
        return f
    }

    // The atom-orbital brand icon — two ellipses + nucleus dot, rendered as template.
    // Shared with the clip picker (brandGlyph in main.swift) so the "Sent" filter and
    // any ClaudeCommand-tagged history row show the exact same mark as the menu bar,
    // not a lookalike SF Symbol or the full-color app icon.
    private func brandIcon() -> NSImage {
        brandGlyph(size: NSStatusBar.system.thickness)
    }

    func hideIcon() {
        if let it = statusItem { NSStatusBar.system.removeStatusItem(it); statusItem = nil }
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.showsStateColumn = false
        // Action items inserted at top by menuWillOpen.
        m.addItem(.separator())
        // Background skill handoffs: recent runs + text entry + config.
        let ho = NSMenuItem(title: "Handoffs", action: nil, keyEquivalent: "")
        ho.submenu = NSMenu(title: "Handoffs")
        m.addItem(ho)
        handoffItem = ho
        // Empty title + attributedTitle breaks the string-based auto-gear check.
        // Blank 1×1 NSImage (not nil) prevents macOS from filling the image slot.
        let settingsItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.attributedTitle = NSAttributedString(
            string: "Settings",
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        settingsItem.target = self
        settingsItem.indentationLevel = 0
        m.addItem(settingsItem)
        let quitItem = add(m, "Quit ClaudeCommand", #selector(quit), key: "q")
        quitItem.indentationLevel = 0
        return m
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    // Rebuild the Handoffs submenu on each menu open: last runs (✓/✗/… like the
    // imported tray), quick text entry, and the config window.
    private func updateHandoffSubmenu() {
        guard let sub = handoffItem?.submenu else { return }
        sub.removeAllItems()
        let recent = loadHandoffSubmissions()
        if recent.isEmpty {
            let none = sub.addItem(withTitle: "No handoffs yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
        } else {
            for r in recent {
                let it = sub.addItem(withTitle: r.menuTitle, action: #selector(openHandoffLog(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = r.logFile
                it.isEnabled = r.logFile != nil
            }
        }
        sub.addItem(.separator())
        add(sub, "Text Entry…", #selector(showHandoffEntry))
        add(sub, "Handoff Settings…", #selector(showHandoffSettings))
    }

    @objc private func openHandoffLog(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              FileManager.default.fileExists(atPath: path) else { NSSound.beep(); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    @objc private func showHandoffEntry() { HandoffTextEntryPanel.shared.show() }
    @objc private func showHandoffSettings() { HandoffSettingsWindowController.shared.show() }

    @objc private func openSettings() { settingsWindow.show(tab: .shortcuts) }
    @objc private func quit() { NSApp.terminate(nil) }
}
