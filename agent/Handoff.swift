// Handoff.swift — native UI for the background skill handoff (the vendored
// Electron-free pipeline in vendor/claude-command-capture, contract in its
// docs/HANDOFF.md). Three pieces, all self-contained:
//   - HandoffConfig: read/patch settings.json (imported schema, unknown keys kept)
//   - HandoffSubmission + loadHandoffSubmissions(): read submissions/ records
//   - HandoffSettingsWindow / HandoffTextEntryPanel: config UI + quick text entry

import Cocoa
import SwiftUI

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

struct HandoffSubmission: Identifiable {
    let id: String
    let createdAt: Date
    let source: String
    let kind: String
    let skill: String?
    let status: String   // running | succeeded | failed
    let logFile: String?

    // A record can stay "running" forever if the CLI (or the machine) died
    // before the updater rewrote it — flag those instead of an eternal spinner.
    var isStalled: Bool { status == "running" && createdAt.timeIntervalSinceNow < -1800 }
    var statusGlyph: String {
        if status == "succeeded" { return "✓" }
        if status == "failed" { return "✗" }
        return isStalled ? "⚠" : "…"
    }
    var age: String {
        let s = Int(-createdAt.timeIntervalSinceNow)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
    var menuTitle: String {
        let target = (skill?.isEmpty == false) ? "/\(skill!)" : "claude -p"
        return "\(statusGlyph) \(source) → \(target) — \(age)\(isStalled ? " (stalled?)" : "")"
    }
}

func loadHandoffSubmissions(limit: Int = 8) -> [HandoffSubmission] {
    let dir = "\(HANDOFF_BASE)/submissions"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var records: [HandoffSubmission] = []
    for f in files where f.hasSuffix(".json") {
        guard let data = FileManager.default.contents(atPath: "\(dir)/\(f)"),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = d["id"] as? String else { continue }
        records.append(HandoffSubmission(
            id: id,
            createdAt: iso.date(from: d["createdAt"] as? String ?? "") ?? .distantPast,
            source: d["source"] as? String ?? "?",
            kind: d["kind"] as? String ?? "text",
            skill: d["skill"] as? String,
            status: d["status"] as? String ?? "?",
            logFile: d["logFile"] as? String
        ))
    }
    return Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
}

// ---- run a text handoff through capture-handoff.sh ---------------------------

func runTextHandoff(_ text: String, source: String = "text") {
    let script = bundledResource("capture-handoff.sh")
    guard FileManager.default.fileExists(atPath: script) else {
        notify("Handoff broken", "capture-handoff.sh missing — rebuild the agent.")
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [script]
    var env = ProcessInfo.processInfo.environment
    env["HANDOFF_SOURCE"] = source
    env["HANDOFF_IMG"] = "0"
    p.environment = env
    let stdin = Pipe()
    p.standardInput = stdin
    do {
        try p.run()
        stdin.fileHandleForWriting.write(text.data(using: .utf8) ?? Data())
        stdin.fileHandleForWriting.closeFile()
    } catch {
        appendLog("[handoff] text handoff launch failed: \(error)")
        notify("Handoff failed", "Could not start capture-handoff.sh")
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

final class HandoffTextEntryPanel: NSObject, NSWindowDelegate {
    static let shared = HandoffTextEntryPanel()
    private var panel: NSPanel?
    private var textView: NSTextView?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let p = panel { p.makeKeyAndOrderFront(nil); return }

        let p = EscClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Handoff to Claude"
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

        let hint = NSTextField(labelWithString: "⌘⏎ submits to your skill · Esc closes")
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
        guard let tv = textView else { return }
        let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        DispatchQueue.global().async { runTextHandoff(text, source: "text") }
        tv.string = ""
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        textView = nil
    }
}
