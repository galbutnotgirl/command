// Permissions.swift — live checks for the Set Up tab. Because these run *inside*
// CommandAgent (the app that actually holds the grants), the results are real:
// AXIsProcessTrusted / CGPreflightScreenCaptureAccess report this process's own
// TCC status, which a plain shell script can't do accurately.

import Cocoa
import ApplicationServices
import CoreGraphics
import AVFoundation

enum CheckState: Equatable { case ok, missing, unknown }

struct StatusCheck {
    let title: String
    let detail: String
    let state: CheckState
}

// ---- permission probes ------------------------------------------------------
func axTrusted() -> Bool { AXIsProcessTrusted() }

func requestAccessibility() {
    let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(o)
}

func screenRecordingOK() -> Bool {
    if #available(macOS 10.15, *) { return CGPreflightScreenCaptureAccess() }
    return true
}
func requestScreenRecording() {
    if #available(macOS 10.15, *) { _ = CGRequestScreenCaptureAccess() }
}

func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}

// ---- small shell helper -----------------------------------------------------
@discardableResult
func runShell(_ launchPath: String, _ args: [String]) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return ("", -1) }
    // Read to EOF before waiting, so a large output (e.g. launchctl print-disabled)
    // can't fill the 64K pipe buffer and deadlock against waitUntilExit().
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
}

let AGENT_LABEL    = "com.claudecommand.agent"
let CLIPWATCH_LABEL = "com.claudecommand.clipwatch"

func fileExists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
func home(_ rel: String) -> String { (NSHomeDirectory() as NSString).appendingPathComponent(rel) }

// ---- shared config (command-config.json) ------------------------------------
// Written by the menu-bar UI, read by clipwatch.py and the clipboard picker.
let COMMAND_CONFIG = home(".claude/state/command-config.json")
let DEFAULT_RETENTION_DAYS = 7

func readCommandConfig() -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: COMMAND_CONFIG),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}

func readRetentionDays() -> Int {
    if let v = readCommandConfig()["retentionDays"] as? Int, v >= 1 { return v }
    if let d = readCommandConfig()["retentionDays"] as? Double, d >= 1 { return Int(d) }
    return DEFAULT_RETENTION_DAYS
}

func writeRetentionDays(_ days: Int) {
    var cfg = readCommandConfig()
    cfg["retentionDays"] = max(1, days)
    if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: COMMAND_CONFIG))
    }
}

// ---- clipboard history clearing ---------------------------------------------
// History lives in ~/.claude/state/cliphistory/ (index.json + per-item files),
// written by clipwatch.py. "Clear last N minutes" removes the most-recent clips
// (the ones likeliest to hold something sensitive you just copied); withinSeconds
// <= 0 clears everything.
let CLIP_HIST_DIR = home(".claude/state/cliphistory")
let CLIP_INDEX    = home(".claude/state/cliphistory/index.json")

@discardableResult
func clearClipHistory(withinSeconds seconds: Int) -> Int {
    let now = Int(Date().timeIntervalSince1970)
    let dir = CLIP_HIST_DIR as NSString
    var removed = 0

    func itemTimestamp(_ it: [String: Any]) -> Int {
        if let t = it["ts"] as? Int { return t }
        if let d = it["ts"] as? Double { return Int(d) }
        return 0
    }

    guard let data = FileManager.default.contents(atPath: CLIP_INDEX),
          let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        // No index. For a full clear, still wipe any stray item files.
        if seconds <= 0, let files = try? FileManager.default.contentsOfDirectory(atPath: CLIP_HIST_DIR) {
            for f in files where f != "index.json" {
                try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(f)); removed += 1
            }
        }
        return removed
    }

    var kept: [[String: Any]] = []
    for it in items {
        let drop = seconds <= 0 ? true : itemTimestamp(it) >= (now - seconds)
        if drop {
            if let f = it["file"] as? String {
                try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(f))
            }
            removed += 1
        } else {
            kept.append(it)
        }
    }
    if let out = try? JSONSerialization.data(withJSONObject: kept) {
        try? out.write(to: URL(fileURLWithPath: CLIP_INDEX), options: [.atomic])
    }
    return removed
}

func serviceLoaded(_ label: String) -> Bool {
    runShell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).code == 0
}

// ---- launch at login (manage the existing LaunchAgent via enable/disable) ---
// enable/disable (vs bootout) so toggling never kills the currently-running agent.
func launchAtLoginEnabled() -> Bool {
    let r = runShell("/bin/launchctl", ["print-disabled", "gui/\(getuid())"])
    for line in r.out.split(separator: "\n") where line.contains(AGENT_LABEL) {
        let l = line.lowercased()
        return !(l.contains("=> true") || l.contains("disabled"))
    }
    return true   // not listed as disabled → will start at login
}
func setLaunchAtLogin(_ on: Bool) {
    runShell("/bin/launchctl", [on ? "enable" : "disable", "gui/\(getuid())/\(AGENT_LABEL)"])
}

// ---- check groups for the Set Up tab ----------------------------------------
func permissionChecks() -> [StatusCheck] {
    [
        StatusCheck(title: "Accessibility",
                    detail: "Lets ClaudeCommand fire hotkeys and type ⌘C / ⌘V / Return. The one essential grant.",
                    state: axTrusted() ? .ok : .missing),
        StatusCheck(title: "Screen Recording",
                    detail: "Required for the screenshot actions (macOS screencapture).",
                    state: screenRecordingOK() ? .ok : .missing),
        StatusCheck(title: "Microphone (optional)",
                    detail: "For dictation only. Parakeet TDT transcribes entirely on-device — no cloud.",
                    state: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .ok : .unknown),
    ]
}

func micPermissionGranted() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
}

func requestMic() {
    AVCaptureDevice.requestAccess(for: .audio) { _ in }
}

func componentChecks() -> [StatusCheck] {
    [
        StatusCheck(title: "Agent running",
                    detail: "Background socket is up at ~/.claude/state/command-agent.sock.",
                    state: fileExists(home(".claude/state/command-agent.sock")) ? .ok : .missing),
        StatusCheck(title: "Hotkeys configured",
                    detail: "command-hotkeys.json present. Edit bindings in the Shortcuts tab.",
                    state: fileExists(home(".claude/state/command-hotkeys.json")) ? .ok : .missing),
        StatusCheck(title: "Right-click actions",
                    detail: "Quick Actions installed in ~/Library/Services (run ./install-quick-action.sh).",
                    state: fileExists(home("Library/Services/Claude - Add.workflow")) ? .ok : .missing),
        StatusCheck(title: "Clipboard daemon",
                    detail: UserDefaults.standard.bool(forKey: "cliphistoryEnabled")
                        ? "Clipboard watcher running (bundled, starts with ClaudeCommand)."
                        : "Clipboard history is off — enable it in the Clipboard History tab.",
                    state: !UserDefaults.standard.bool(forKey: "cliphistoryEnabled") ? .unknown
                         : runShell("/usr/bin/pgrep", ["-f", "clipwatch.py"]).code == 0 ? .ok : .missing),
    ]
}
