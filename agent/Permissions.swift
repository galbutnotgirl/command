// Permissions.swift — live checks for the Set Up tab. Because these run *inside*
// ClaudeCommand (the app that actually holds the grants), the results are real:
// AXIsProcessTrusted / CGPreflightScreenCaptureAccess report this process's own
// TCC status, which a plain shell script can't do accurately.

import Cocoa
import ApplicationServices
import CoreGraphics
import AVFoundation
import ClaudeCommandCore

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

let AGENT_LABEL = "com.claudecommand"

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

// ---- launch at login ---------------------------------------------------------
// Binary installs are just the .app bundle. Create the LaunchAgent from inside
// the app when the user turns on Launch at login, so downloaded installs do not
// need Terminal scripts for normal startup behavior.
private func launchAgentPlistPath() -> String {
    home("Library/LaunchAgents/\(AGENT_LABEL).plist")
}

private func launchAgentProgramPath() -> String {
    Bundle.main.executablePath ?? home("Applications/Command.app/Contents/MacOS/Command")
}

@discardableResult
func ensureLaunchAgentInstalled() -> Bool {
    let plist = launchAgentPlistPath()
    let program = launchAgentProgramPath()
    guard FileManager.default.fileExists(atPath: program) else { return false }
    let plistDir = (plist as NSString).deletingLastPathComponent
    let logDir = home(".claude/logs")
    let stateDir = home(".claude/state")
    try? FileManager.default.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let escapedProgram = program
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    let escapedErr = home(".claude/logs/command-agent.err")
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    let escapedOut = home(".claude/logs/command-agent.out")
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(AGENT_LABEL)</string>
        <key>Program</key><string>\(escapedProgram)</string>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key>
        <dict><key>SuccessfulExit</key><false/></dict>
        <key>ProcessType</key><string>Interactive</string>
        <key>StandardErrorPath</key><string>\(escapedErr)</string>
        <key>StandardOutPath</key><string>\(escapedOut)</string>
    </dict>
    </plist>
    """
    do {
        try xml.write(toFile: plist, atomically: true, encoding: .utf8)
        _ = runShell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist])
        return true
    } catch {
        return false
    }
}

func launchAtLoginEnabled() -> Bool {
    guard FileManager.default.fileExists(atPath: launchAgentPlistPath()) else { return false }
    let r = runShell("/bin/launchctl", ["print-disabled", "gui/\(getuid())"])
    for line in r.out.split(separator: "\n") where line.contains(AGENT_LABEL) {
        let l = line.lowercased()
        return !(l.contains("=> true") || l.contains("disabled"))
    }
    return true   // not listed as disabled → will start at login
}
func setLaunchAtLogin(_ on: Bool) {
    if on, !FileManager.default.fileExists(atPath: launchAgentPlistPath()) {
        guard ensureLaunchAgentInstalled() else { return }
    }
    _ = runShell("/bin/launchctl", [on ? "enable" : "disable", "gui/\(getuid())/\(AGENT_LABEL)"])
}

// ---- check groups for the Set Up tab ----------------------------------------
func permissionChecks() -> [StatusCheck] {
    [
        StatusCheck(title: "Accessibility",
                    detail: "Lets Command fire hotkeys and type ⌘C / ⌘V / Return. The one essential grant.",
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

func micPermissionDenied() -> Bool {
    let s = AVCaptureDevice.authorizationStatus(for: .audio)
    return s == .denied || s == .restricted
}

private func providerExecutable(_ provider: AIProvider) -> String? {
    let candidates: [String]
    switch provider {
    case .claude:
        candidates = ["/opt/homebrew/bin/claude", "\(NSHomeDirectory())/.claude/local/claude", "/usr/local/bin/claude"]
    case .codex:
        candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"]
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func providerAppInstalled(_ provider: AIProvider) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.appBundleIdentifier) != nil
}

private func providerCLIState(_ provider: AIProvider) -> CheckState {
    guard let executable = providerExecutable(provider) else { return .missing }
    let args = provider == .codex ? ["login", "status"] : ["auth", "status"]
    return runShell(executable, args).code == 0 ? .ok : .unknown
}

func componentChecks() -> [StatusCheck] {
    [
        StatusCheck(title: "Background service",
                    detail: "Local app dispatch socket is up at ~/.claude/state/command-agent.sock.",
                    state: fileExists(home(".claude/state/command-agent.sock")) ? .ok : .missing),
        StatusCheck(title: "Hotkeys configured",
                    detail: "command-hotkeys.json present. Edit bindings in the Shortcuts tab.",
                    state: fileExists(home(".claude/state/command-hotkeys.json")) ? .ok : .missing),
        StatusCheck(title: "Claude app",
                    detail: "Foreground Claude delivery via installed desktop app.",
                    state: providerAppInstalled(.claude) ? .ok : .unknown),
        StatusCheck(title: "Claude CLI",
                    detail: "Background Claude delivery. Unknown usually means sign-in is needed.",
                    state: providerCLIState(.claude)),
        StatusCheck(title: "ChatGPT app",
                    detail: "Foreground ChatGPT and Codex delivery via com.openai.codex.",
                    state: providerAppInstalled(.codex) ? .ok : .unknown),
        StatusCheck(title: "Codex CLI",
                    detail: "Background Codex delivery. Unknown usually means `codex login` is needed.",
                    state: providerCLIState(.codex)),
        StatusCheck(title: "Codex workspace",
                    detail: UserDefaults.standard.string(forKey: "codexWorkspace") ?? NSHomeDirectory(),
                    state: FileManager.default.fileExists(atPath: UserDefaults.standard.string(forKey: "codexWorkspace") ?? NSHomeDirectory()) ? .ok : .missing),
        StatusCheck(title: "Right-click actions",
                    detail: fileExists(home("Library/Services/Claude - Add.workflow"))
                        ? "Optional Quick Actions installed in ~/Library/Services."
                        : "Optional source-install Services are not installed. Global shortcuts do not need them.",
                    state: fileExists(home("Library/Services/Claude - Add.workflow")) ? .ok : .unknown),
        StatusCheck(title: "Clipboard History",
                    detail: UserDefaults.standard.bool(forKey: "cliphistoryEnabled")
                        ? "Clipboard History running (bundled, starts with Command)."
                        : "Clipboard history is off — enable it in the Clipboard History tab.",
                    state: !UserDefaults.standard.bool(forKey: "cliphistoryEnabled") ? .unknown
                         : runShell("/usr/bin/pgrep", ["-f", "clipwatch.py"]).code == 0 ? .ok : .missing),
    ]
}
