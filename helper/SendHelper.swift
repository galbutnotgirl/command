// SendHelper — tiny stable-identity helper so keystroke synthesis needs
// Accessibility ONCE (granted to this app), with NO Automation/Apple-Events
// prompts. Quick Actions call this instead of short-lived automation processes.
//
// Commands:
//   sendhelper copy [out] → synth ⌘C, then write clipboard text to `out` file
//                           (or stdout if no path). `out` lets the worker read the
//                           result when the helper is launched via `open` (which
//                           can't capture stdout) — needed so keystroke synthesis
//                           runs as SendHelper's OWN process / TCC grant.
//   sendhelper paste      → synth ⌘V (paste into the focused app)
//   sendhelper return     → synth Return (submit)
//   sendhelper frontapp   → print the frontmost app's bundle id (no permission)
//   sendhelper activate <bundleid>  → bring an app to front
//
// Key posting needs Accessibility for THIS bundle (com.claudecommand.helper). On first
// use it prompts to add SendHelper to Accessibility; approve once.

import Cocoa
import CoreGraphics
import ApplicationServices

let kC: CGKeyCode = 0x08
let kV: CGKeyCode = 0x09
let kReturn: CGKeyCode = 0x24

func ensureTrusted() {
    if AXIsProcessTrusted() { return }
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    FileHandle.standardError.write(
        "Accessibility not granted — approve SendHelper in System Settings ▸ Privacy & Security ▸ Accessibility, then retry.\n"
        .data(using: .utf8)!)
    exit(3)
}

func postKey(_ key: CGKeyCode, cmd: Bool) {
    let src = CGEventSource(stateID: .combinedSessionState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
          let up   = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
    if cmd { down.flags = .maskCommand; up.flags = .maskCommand }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: sendhelper copy|paste|return|frontapp|activate <bundleid>\n".data(using: .utf8)!)
    exit(2)
}

switch args[1] {
case "copy":
    ensureTrusted()
    postKey(kC, cmd: true)
    usleep(350_000)
    let sel = NSPasteboard.general.string(forType: .string) ?? ""
    if args.count >= 3 {
        try? sel.write(toFile: args[2], atomically: true, encoding: .utf8)
    } else {
        FileHandle.standardOutput.write(sel.data(using: .utf8) ?? Data())
    }
case "paste":
    ensureTrusted()
    postKey(kV, cmd: true)
case "return":
    ensureTrusted()
    postKey(kReturn, cmd: false)
case "frontapp":
    if let a = NSWorkspace.shared.frontmostApplication { print(a.bundleIdentifier ?? "") }
case "activate":
    guard args.count >= 3 else { exit(2) }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: args[2]) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        usleep(250_000)
    }
default:
    FileHandle.standardError.write("unknown command\n".data(using: .utf8)!)
    exit(2)
}
