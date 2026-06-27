// MenuBar.swift — the menu-bar icon and its menu.
// Menu: [actions with shortcut keys]  |  ─  |  Settings ⌘,  |  Quit ⌘Q
// Action items are rebuilt on each open (picks up binding changes live).
// Clicking an action item triggers it immediately, same as the hotkey.

import Cocoa

let menuBar = MenuBarController()

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func install() { if !UserDefaults.standard.bool(forKey: "hideMenuBarIcon") { showIcon() } }

    func showIcon() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button { btn.image = brandIcon() }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // Rebuild action items each time menu opens so binding changes are live.
    func menuWillOpen(_ menu: NSMenu) {
        updateActionItems(in: menu)
    }

    private func updateActionItems(in menu: NSMenu) {
        // Structure: [0..N-1]=actions  [N]=separator  [N+1]=Settings  [N+2]=Quit
        // Remove all action items (everything before the last 3 items).
        while menu.numberOfItems > 3 {
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
    private func brandIcon() -> NSImage {
        let h = NSStatusBar.system.thickness
        let img = NSImage(size: NSSize(width: h, height: h), flipped: false) { full in
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

    func hideIcon() {
        if let it = statusItem { NSStatusBar.system.removeStatusItem(it); statusItem = nil }
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        // Action items inserted at top by menuWillOpen.
        m.addItem(.separator())
        // Title is "Open Settings" (not bare "Settings") so macOS doesn't
        // auto-decorate the row with a gearshape icon. No image + no key
        // equivalent → the label sits flush-left like the other rows.
        add(m, "Open Settings", #selector(openSettings))
        add(m, "Quit Claude Command", #selector(quit), key: "q")
        return m
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func openSettings() { settingsWindow.show(tab: .shortcuts) }
    @objc private func quit() { NSApp.terminate(nil) }
}
