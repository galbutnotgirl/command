// Handoff.swift — native UI for the background skill handoff (the vendored
// Electron-free pipeline in vendor/claude-command-capture, contract in its
// docs/HANDOFF.md). Three pieces, all self-contained:
//   - HandoffConfig: read/patch settings.json (imported schema, unknown keys kept) —
//     the CLI command/cwd/extraArgs/notifications every Custom Handoff shares
//   - HandoffSubmission + loadHandoffSubmissions(): read submissions/ records
//   - CustomActionTextEntryPanel: popup-kind Custom Actions' typed-entry trigger

import Cocoa
import SwiftUI
import ClaudeCommandCore

// Base data dir — same path Electron's app.getPath('userData') would use, so
// the downstream-app contract is identical (see integration doc).
let HANDOFF_BASE: String = ProcessInfo.processInfo.environment["CLAUDE_CAPTURE_HOME"]
    ?? "\(HOME)/Library/Application Support/claude-command"

// ---- settings.json (imported schema; only known keys are edited) -----------

struct HandoffConfig {
    var skill = ""
    var promptTemplate = ""
    var imagePromptTemplate = ""
    var cliCommand = "claude"
    var cliCwd = ""
    var cliExtraArgs: [String] = []
    var notifications = true

    static var settingsFile: String { "\(HANDOFF_BASE)/settings.json" }

    // Defaults mirror DEFAULT_SETTINGS in vendor src/settings.js; its
    // mergeSettings() backfills anything we leave out on the JS side.
    static let defaultTextTemplate = "{skillInvocation}\n\nSource: {source}\nCaptured at: {timestamp}\n\n{content}"
    static let defaultImageTemplate = "{skillInvocation}\n\nSource: {source}\nCaptured at: {timestamp}\n\nA captured image was saved to: {file}\nRead that file to view the capture."

    static func load() -> HandoffConfig {
        var c = HandoffConfig(promptTemplate: defaultTextTemplate, imagePromptTemplate: defaultImageTemplate)
        guard let data = FileManager.default.contents(atPath: settingsFile),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        c.skill = d["skill"] as? String ?? c.skill
        c.promptTemplate = d["promptTemplate"] as? String ?? c.promptTemplate
        c.imagePromptTemplate = d["imagePromptTemplate"] as? String ?? c.imagePromptTemplate
        c.notifications = d["notifications"] as? Bool ?? c.notifications
        if let cli = d["cli"] as? [String: Any] {
            c.cliCommand = cli["command"] as? String ?? c.cliCommand
            c.cliCwd = cli["cwd"] as? String ?? c.cliCwd
            c.cliExtraArgs = cli["extraArgs"] as? [String] ?? c.cliExtraArgs
        }
        return c
    }

    // Patch only the keys this UI owns; everything else in the file (baseArgs,
    // the ignored Electron hotkeys block, future fields) is preserved.
    func save() {
        var d: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: Self.settingsFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            d = existing
        }
        d["skill"] = skill
        d["promptTemplate"] = promptTemplate
        d["imagePromptTemplate"] = imagePromptTemplate
        d["notifications"] = notifications
        var cli = d["cli"] as? [String: Any] ?? [:]
        cli["command"] = cliCommand
        cli["cwd"] = cliCwd
        cli["extraArgs"] = cliExtraArgs
        if cli["baseArgs"] == nil { cli["baseArgs"] = ["-p"] }
        d["cli"] = cli
        guard let out = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: HANDOFF_BASE, withIntermediateDirectories: true)
        try? out.write(to: URL(fileURLWithPath: Self.settingsFile))
    }
}

// ---- submission records ------------------------------------------------------
// HandoffSubmission's model + staleness/age computed properties live in
// ClaudeCommandCore/HandoffModels.swift (unit-tested there); this file only
// does the disk I/O.

private let handoffISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// limit: nil = every record (Settings ▸ Handoffs); the menu bar passes a small
// limit since it only ever shows the last few.
func loadHandoffSubmissions(limit: Int? = 8) -> [HandoffSubmission] {
    let dir = "\(HANDOFF_BASE)/submissions"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var records: [HandoffSubmission] = []
    for f in files where f.hasSuffix(".json") {
        guard let data = FileManager.default.contents(atPath: "\(dir)/\(f)"),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = d["id"] as? String else { continue }
        records.append(HandoffSubmission(
            id: id,
            createdAt: handoffISO.date(from: d["createdAt"] as? String ?? "") ?? .distantPast,
            finishedAt: (d["finishedAt"] as? String).flatMap { handoffISO.date(from: $0) },
            source: d["source"] as? String ?? "?",
            kind: d["kind"] as? String ?? "text",
            skill: d["skill"] as? String,
            status: d["status"] as? String ?? "?",
            exitCode: d["exitCode"] as? Int,
            error: d["error"] as? String,
            prompt: d["prompt"] as? String,
            contentFile: d["contentFile"] as? String,
            logFile: d["logFile"] as? String,
            result: d["result"] as? String
        ))
    }
    let sorted = records.sorted { $0.createdAt > $1.createdAt }
    guard let limit = limit else { return sorted }
    return Array(sorted.prefix(limit))
}

// Removes the submission record plus its capture + log files — the three
// artifacts a run produces (see docs/HANDOFF.md). Best-effort: a missing file
// on any of the three is not an error, just skipped.
func deleteHandoffSubmission(_ s: HandoffSubmission) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: "\(HANDOFF_BASE)/submissions/\(s.id).json")
    if let c = s.contentFile { try? fm.removeItem(atPath: c) }
    if let l = s.logFile { try? fm.removeItem(atPath: l) }
}

// Stalled-run recovery: a "running" record whose CLI process died (or the Mac
// slept/crashed) before the updater could rewrite it stays "running" forever —
// isStalled flags it, this lets the user actually clear it. Rewrites the
// record in place (same schema updateSubmission() in the vendor core writes),
// then the record is an ordinary "failed" one — the existing Retry button
// picks it up from there.
func markHandoffSubmissionFailed(_ s: HandoffSubmission, reason: String = "Marked failed (stalled run)") {
    let path = "\(HANDOFF_BASE)/submissions/\(s.id).json"
    guard let data = FileManager.default.contents(atPath: path),
          var d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    d["status"] = "failed"
    d["error"] = reason
    d["finishedAt"] = handoffISO.string(from: Date())
    guard let out = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) else { return }
    try? out.write(to: URL(fileURLWithPath: path))
}

// ---- retention (mirrors the clipboard-history retentionDays model) ----------
// Own key in command-config.json — same default as clipboard history's 7 days.
let DEFAULT_HANDOFF_RETENTION_DAYS = 7

func readHandoffRetentionDays() -> Int {
    if let v = readCommandConfig()["handoffRetentionDays"] as? Int, v >= 1 { return v }
    if let d = readCommandConfig()["handoffRetentionDays"] as? Double, d >= 1 { return Int(d) }
    return DEFAULT_HANDOFF_RETENTION_DAYS
}

func writeHandoffRetentionDays(_ days: Int) {
    var cfg = readCommandConfig()
    cfg["handoffRetentionDays"] = max(1, days)
    if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: COMMAND_CONFIG))
    }
}

// Deletes finished (succeeded/failed) submissions older than the retention
// window, plus their capture/log files. Running submissions are never pruned,
// however old — a stalled run is handled by the separate stalled-run recovery
// path, not silently deleted out from under it. Returns the count removed.
@discardableResult
func pruneHandoffSubmissions() -> Int {
    let cutoff = Date().addingTimeInterval(-Double(readHandoffRetentionDays()) * 86400)
    var removed = 0
    for s in loadHandoffSubmissions(limit: nil) where isHandoffPruneEligible(status: s.status, createdAt: s.createdAt, cutoff: cutoff) {
        deleteHandoffSubmission(s)
        removed += 1
    }
    return removed
}

// Re-run a failed (or any past) submission's exact stored prompt — bypasses
// capture-handoff.sh (whose job is rendering raw captures into a prompt) and
// calls submit-cli.js's --retry-prompt path directly, mirroring capture-handoff.sh's
// own CORE/SHIM/NODE resolution so both dev and bundled-app layouts work.
func retryHandoffSubmission(_ s: HandoffSubmission) {
    guard let prompt = s.prompt, !prompt.isEmpty else {
        notify("Retry failed", "No stored prompt for this submission.")
        return
    }
    submitHandoffPrompt(prompt, source: s.source, kind: s.kind, skill: s.skill, failureTitle: "Retry failed")
}

private func which(_ name: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
        let path = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

// Shared submit path for retryHandoffSubmission and runCustomHandoff — both hand
// an already-rendered prompt to submit-cli.js's --retry-prompt mode, skipping
// buildPrompt() (which would need a matching global settings.json skill/template).
private func submitHandoffPrompt(_ prompt: String, source: String, kind: String, skill: String?, failureTitle: String) {
    let scriptDir = (bundledResource("capture-handoff.sh") as NSString).deletingLastPathComponent
    var core = (scriptDir as NSString).appendingPathComponent("claude-command-capture")
    if !FileManager.default.fileExists(atPath: core) {
        core = (scriptDir as NSString).appendingPathComponent("vendor/claude-command-capture")
    }
    let shim = (core as NSString).appendingPathComponent("bin/submit-cli.js")
    guard FileManager.default.fileExists(atPath: shim) else {
        notify(failureTitle, "Handoff core missing — rebuild the agent.")
        return
    }
    guard let node = which("node") else {
        notify(failureTitle, "Node.js 20+ not found on PATH.")
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: node)
    p.arguments = [shim, "--base-dir", HANDOFF_BASE, "--retry-prompt", "--source", source, "--kind", kind]
        + (skill.map { ["--skill", $0] } ?? [])
    let stdin = Pipe()
    p.standardInput = stdin
    do {
        try p.run()
        stdin.fileHandleForWriting.write(prompt.data(using: .utf8) ?? Data())
        stdin.fileHandleForWriting.closeFile()
    } catch {
        appendLog("[handoff] submit launch failed: \(error)")
        notify(failureTitle, "Could not start submit-cli.js")
    }
}

// ---- custom actions run as background handoffs (isHandoff == true) ---------
// renderCustomActionHandoffPrompt() lives in ClaudeCommandCore/HandoffModels.swift.

// Writes the clipboard's image to a fresh file under captures/ and returns its
// path — the native (AppKit-direct) equivalent of capture-handoff.sh's Python
// NSPasteboard dump, since this process already links AppKit.
private func writeClipboardImageFile() -> String? {
    let pb = NSPasteboard.general
    var data = pb.data(forType: .png)
    if data == nil, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
        data = rep.representation(using: .png, properties: [:])
    }
    guard let pngData = data else { return nil }
    let dir = "\(HANDOFF_BASE)/captures"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/\(UUID().uuidString.lowercased()).png"
    do { try pngData.write(to: URL(fileURLWithPath: path)); return path } catch { return nil }
}

func runCustomHandoff(_ ca: CustomAction, capturedText: String = "") {
    guard ca.enabled else { return }
    let skill = ca.skill.isEmpty ? nil : ca.skill
    if ca.kind == .screenshot {
        guard let file = writeClipboardImageFile() else {
            notify("Handoff failed", "No image on the clipboard.")
            return
        }
        let prompt = renderCustomActionHandoffPrompt(ca, content: nil, file: file)
        submitHandoffPrompt(prompt, source: "screenshot", kind: "image", skill: skill, failureTitle: "Handoff failed")
    } else {
        // popup/voice always arrive with definitive content (typed or spoken);
        // plain text falls back to the clipboard if nothing was captured.
        let text = !capturedText.isEmpty ? capturedText
            : (ca.kind == .text ? (NSPasteboard.general.string(forType: .string) ?? "") : "")
        guard !text.isEmpty else {
            notify("Handoff failed", "Nothing selected or on the clipboard.")
            return
        }
        let source = ca.kind == .popup ? "popup" : (ca.kind == .voice ? "voice" : "selection")
        let prompt = renderCustomActionHandoffPrompt(ca, content: text, file: nil)
        submitHandoffPrompt(prompt, source: source, kind: "text", skill: skill, failureTitle: "Handoff failed")
    }
}

// ---- settings window ----------------------------------------------------------

final class HandoffSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = HandoffSettingsWindowController()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Skill Handoff Settings"
        w.contentViewController = NSHostingController(rootView: HandoffSettingsView())
        w.center(); w.isReleasedWhenClosed = false; w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct HandoffSettingsView: View {
    @State private var config = HandoffConfig.load()
    @State private var extraArgsText = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background handoff: captures are rendered into a prompt and piped to `claude -p` addressed to this skill. Records land in \(HANDOFF_BASE).")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                Text("Skill name").font(.headline)
                TextField("e.g. triage-capture (empty = no skill line)", text: $config.skill)
                Text("Resolved from the CLI working directory's .claude/skills/ (or ~/.claude/skills/).")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Group {
                Text("Claude CLI").font(.headline)
                TextField("command (claude, or absolute path)", text: $config.cliCommand)
                TextField("working directory (decides whose skills are available)", text: $config.cliCwd)
                TextField("extra args, one per line ok (e.g. --permission-mode acceptEdits)", text: $extraArgsText)
            }

            Group {
                Text("Text prompt template").font(.headline)
                TextEditor(text: $config.promptTemplate)
                    .font(.system(size: 11, design: .monospaced)).frame(height: 90)
                Text("Image prompt template").font(.headline)
                TextEditor(text: $config.imagePromptTemplate)
                    .font(.system(size: 11, design: .monospaced)).frame(height: 90)
                Text("Placeholders: {skillInvocation} {skill} {source} {timestamp} {content} {file}")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Toggle("Desktop notifications on submit/finish", isOn: $config.notifications)

            HStack {
                Spacer()
                if saved { Text("Saved").foregroundColor(.secondary) }
                Button("Save") {
                    config.cliExtraArgs = extraArgsText
                        .split(whereSeparator: { $0 == "\n" || $0 == " " }).map(String.init)
                    config.save()
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { extraArgsText = config.cliExtraArgs.joined(separator: " ") }
    }
}

// ---- quick text-entry panel ----------------------------------------------------

// NSPanel that actually closes on Esc (cancelOperation) — utility panels don't
// by default.
private final class EscClosingPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

// Trigger for any Custom Action with kind == .popup: a floating text box
// (⌘⏎ submits, Esc closes) whose content becomes that action's captured
// input — the paste-into-Claude path if it's a plain action, or
// runCustomHandoff if isHandoff. One panel, re-shown for whichever action's
// hotkey fired; each call updates the title/target instead of stacking panels.
final class CustomActionTextEntryPanel: NSObject, NSWindowDelegate {
    static let shared = CustomActionTextEntryPanel()
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var target: CustomAction?

    func show(for action: CustomAction) {
        target = action
        NSApp.activate(ignoringOtherApps: true)
        if let p = panel {
            p.title = action.name
            p.makeKeyAndOrderFront(nil)
            p.makeFirstResponder(textView)
            return
        }

        let p = EscClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        p.title = action.name
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.delegate = self

        let content = NSView(frame: p.contentRect(forFrameRect: p.frame))
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 44, width: 456, height: 118))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        content.addSubview(scroll)

        let hint = NSTextField(labelWithString: "⌘⏎ submits · Esc closes")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 12, y: 14, width: 260, height: 16)
        content.addSubview(hint)

        let btn = NSButton(title: "Submit", target: self, action: #selector(submit))
        btn.bezelStyle = .rounded
        btn.keyEquivalent = "\r"
        btn.keyEquivalentModifierMask = .command
        btn.frame = NSRect(x: 388, y: 8, width: 80, height: 28)
        btn.autoresizingMask = [.minXMargin]
        content.addSubview(btn)

        p.contentView = content
        p.center()
        panel = p
        textView = tv
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(tv)
    }

    @objc private func submit() {
        guard let tv = textView, let ca = target else { return }
        let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if ca.isHandoff {
            DispatchQueue.global().async { runCustomHandoff(ca, capturedText: text) }
        } else {
            DispatchQueue.global().async {
                runWorker("custom", source: front, captured: text,
                          customPrompt: ca.prompt, customSubmit: ca.isAutoSubmit,
                          customSession: ca.sessionMode, customIncludeSource: ca.includeSource)
            }
        }
        tv.string = ""
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        textView = nil
        target = nil
    }
}
