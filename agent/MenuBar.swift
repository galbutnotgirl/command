// MenuBar.swift — the menu-bar icon and its menu.
// Menu: [actions with shortcut keys]  |  ─  |  Settings ⌘,  |  Quit ⌘Q
// Action items are rebuilt on each open (picks up binding changes live).
// Clicking an action item triggers it immediately, same as the hotkey.

import Cocoa
import ClaudeCommandCore

let menuBar = MenuBarController()

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func install() { if !UserDefaults.standard.bool(forKey: "hideMenuBarIcon") { showIcon() } }

    func setFinishing() {
        statusItem?.button?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Finishing dictation")
        statusItem?.button?.toolTip = "Finishing dictation"
    }

    func setStarting() {
        statusItem?.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Starting microphone")
        statusItem?.button?.toolTip = "Starting microphone — wait for the start sound"
    }

    func setRecording(_ on: Bool) {
        statusItem?.length = statusIconWidth
        statusItem?.button?.toolTip = on ? "Recording audio" : "Command"
        statusItem?.button?.image = on ? waveformIcon(level: 0) : brandIcon()
    }

    // Called ~15fps by DictationOverlay while recording; drives the reactive waveform icon.
    func updateAudioLevel(_ level: Float) {
        statusItem?.length = statusIconWidth
        statusItem?.button?.image = waveformIcon(level: level)
    }

    private var statusIconWidth: CGFloat { max(24, NSStatusBar.system.thickness) }

    // Active recording state: compact solid-purple voice indicator.
    // White animated bars carry the motion; the shape stays close to macOS mic/camera
    // status icons without becoming a wide banner in the menu bar.
    private func waveformIcon(level: Float) -> NSImage {
        let h = NSStatusBar.system.thickness
        let w = statusIconWidth
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let purple = NSColor(red: 0.44, green: 0.00, blue: 0.96, alpha: 1.0)
            let phase = CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.96) / 0.96)
            let normalized = min(1, max(0, CGFloat(level)))
            let visibleLevel = max(0.44, pow(normalized, 0.28))
            let side = min(rect.height - 2.8, rect.width - 2.0)
            let plate = NSRect(x: rect.midX - side / 2,
                               y: rect.midY - side / 2,
                               width: side,
                               height: side)
            let radius = side * 0.34

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = purple.withAlphaComponent(0.42)
            shadow.shadowOffset = NSSize(width: 0, height: -0.8)
            shadow.shadowBlurRadius = 5.5
            shadow.set()
            let platePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
            purple.setFill()
            platePath.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.withAlphaComponent(0.18).setStroke()
            platePath.lineWidth = 1.0
            platePath.stroke()

            let barW = max(2.2, side * 0.105)
            let gap = side * 0.105
            let scales: [CGFloat] = [0.62, 0.92, 1.0, 0.72]
            let totalW = CGFloat(scales.count) * barW + CGFloat(scales.count - 1) * gap
            let startX = plate.midX - totalW / 2
            let maxH = side * 0.66
            for (i, scale) in scales.enumerated() {
                let x = startX + CGFloat(i) * (barW + gap)
                let wave = (sin((phase * .pi * 2) + CGFloat(i) * 1.18) + 1) / 2
                let bh = max(side * 0.20, maxH * min(1.0, visibleLevel * scale * (0.76 + wave * 0.34)))
                let by = plate.midY - bh / 2
                NSColor.white.withAlphaComponent(1.0).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: by, width: barW, height: bh),
                             xRadius: barW / 2,
                             yRadius: barW / 2).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    func showIcon() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: statusIconWidth)
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
        // Structure: [0..N-1]=enabled bound actions | sep | Settings | Quit
        // Remove all action items (everything before the last 3 static items).
        while menu.numberOfItems > 3 {
            menu.removeItem(at: 0)
        }
        let bindings = loadBindings().filter(\.isVisibleInMenu)
        for (i, b) in bindings.enumerated() {
            let it = NSMenuItem()
            it.view = NSMenuItemPlainView(title: b.name, shortcut: b.human) { [weak self] in
                self?.runAction(b.action)
            }
            menu.insertItem(it, at: i)
        }
    }

    private func runAction(_ action: String) {
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
        let settingsItem = plainSettingsItem()
        m.addItem(settingsItem)
        m.addItem(plainQuitItem())
        return m
    }

    private func plainSettingsItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.target = self
        item.action = #selector(openSettings)
        item.keyEquivalent = ","
        item.keyEquivalentModifierMask = [.command]
        let row = NSMenuItemPlainView(title: "Settings", shortcut: "⌘,") { [weak self] in
            self?.openSettings()
        }
        item.view = row
        return item
    }

    private func plainQuitItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.target = self
        item.action = #selector(quit)
        item.keyEquivalent = "q"
        item.keyEquivalentModifierMask = [.command]
        let row = NSMenuItemPlainView(title: "Quit Command", shortcut: "⌘Q") { [weak self] in
            self?.quit()
        }
        item.view = row
        return item
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

private final class NSMenuItemPlainView: NSView {
    private let action: () -> Void
    private let label: NSTextField
    private let shortcutLabel: NSTextField?
    private var tracking: NSTrackingArea?
    private var highlighted = false {
        didSet {
            label.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
            shortcutLabel?.textColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    private enum Layout {
        static let width: CGFloat = 238
        static let height: CGFloat = 24
        static let horizontalInset: CGFloat = 14
        static let shortcutGap: CGFloat = 18
        static let highlightInsetX: CGFloat = 4
        static let highlightInsetY: CGFloat = 2
    }

    init(title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.action = action
        self.label = NSTextField(labelWithString: title)
        if let shortcut {
            self.shortcutLabel = NSTextField(labelWithString: shortcut)
        } else {
            self.shortcutLabel = nil
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        if let shortcut { setAccessibilityValue(shortcut) }

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        addSubview(label)

        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.horizontalInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        if let shortcutLabel {
            shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
            shortcutLabel.font = NSFont.menuFont(ofSize: 0)
            shortcutLabel.textColor = .secondaryLabelColor
            addSubview(shortcutLabel)
            constraints.append(contentsOf: [
                shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.horizontalInset),
                shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -Layout.shortcutGap),
            ])
        } else {
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.horizontalInset))
        }

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.width, height: Layout.height)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlighted else { return }
        let rect = bounds.insetBy(dx: Layout.highlightInsetX, dy: Layout.highlightInsetY)
        NSColor.controlAccentColor.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    override func mouseUp(with event: NSEvent) {
        action()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        enclosingMenuItem?.menu?.cancelTracking()
        return true
    }
}
