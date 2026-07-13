// Handoff.swift — native UI for the background skill handoff (the vendored
// Electron-free pipeline in vendor/claude-command-capture, contract in its
// docs/HANDOFF.md). Three pieces, all self-contained:
//   - HandoffConfig: read/patch settings.json (imported schema, unknown keys kept) —
//     the CLI command/cwd/extraArgs/notifications every background action shares
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
    var claudeCommand = "claude"
    var claudeCwd = ""
    var claudeExtraArgs: [String] = []
    var codexCommand = codexExecutablePath() ?? "codex"
    var codexCwd = UserDefaults.standard.string(forKey: "codexWorkspace") ?? NSHomeDirectory()
    var codexExtraArgs: [String] = CodexExecutionPreset.readOnly.arguments
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
        let providers = d["providers"] as? [String: Any]
        let claude = providers?["claude"] as? [String: Any] ?? d["cli"] as? [String: Any]
        if let claude {
            c.claudeCommand = claude["command"] as? String ?? c.claudeCommand
            c.claudeCwd = claude["cwd"] as? String ?? c.claudeCwd
            c.claudeExtraArgs = claude["extraArgs"] as? [String] ?? c.claudeExtraArgs
        }
        if let codex = providers?["codex"] as? [String: Any] {
            c.codexCommand = codex["command"] as? String ?? c.codexCommand
            c.codexCwd = codex["cwd"] as? String ?? c.codexCwd
            c.codexExtraArgs = codex["extraArgs"] as? [String] ?? c.codexExtraArgs
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
        d["schemaVersion"] = 2
        d["defaultProvider"] = UserDefaults.standard.string(forKey: "defaultProvider") ?? "claude"
        var legacyCLI = d["cli"] as? [String: Any] ?? [:]
        legacyCLI["command"] = claudeCommand
        legacyCLI["cwd"] = claudeCwd
        legacyCLI["extraArgs"] = claudeExtraArgs
        if legacyCLI["baseArgs"] == nil { legacyCLI["baseArgs"] = ["-p"] }
        d["cli"] = legacyCLI
        var providers = d["providers"] as? [String: Any] ?? [:]
        var claude = providers["claude"] as? [String: Any] ?? [:]
        claude["command"] = claudeCommand
        claude["baseArgs"] = claude["baseArgs"] ?? ["-p"]
        claude["extraArgs"] = claudeExtraArgs
        claude["cwd"] = claudeCwd
        providers["claude"] = claude
        var codex = providers["codex"] as? [String: Any] ?? [:]
        codex["command"] = codexCommand
        codex["baseArgs"] = codex["baseArgs"] ?? ["exec"]
        codex["extraArgs"] = codexExtraArgs
        codex["cwd"] = codexCwd
        providers["codex"] = codex
        d["providers"] = providers
        guard let out = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: HANDOFF_BASE, withIntermediateDirectories: true)
        try? out.write(to: URL(fileURLWithPath: Self.settingsFile), options: .atomic)
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

// limit: nil = every record (Settings > Command History); the menu bar passes a small
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
            result: d["result"] as? String,
            provider: (d["provider"] as? String).flatMap(AIProvider.init(rawValue:)) ?? .claude,
            workspace: d["workspace"] as? String,
            attachments: d["attachments"] as? [String] ?? []
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
    try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
}

// ---- retention (mirrors the clipboard-history retentionDays model) ----------
// Own key in command-config.json — same default as clipboard history's 7 days.
let DEFAULT_HANDOFF_RETENTION_DAYS = 7
let DEFAULT_COMMAND_RETENTION_DAYS = 7

func readHandoffRetentionDays() -> Int {
    if let v = readCommandConfig()["handoffRetentionDays"] as? Int, v >= 1 { return v }
    if let d = readCommandConfig()["handoffRetentionDays"] as? Double, d >= 1 { return Int(d) }
    return DEFAULT_HANDOFF_RETENTION_DAYS
}

func readCommandRetentionDays() -> Int {
    if let v = readCommandConfig()["commandRetentionDays"] as? Int, v >= 1 { return v }
    if let d = readCommandConfig()["commandRetentionDays"] as? Double, d >= 1 { return Int(d) }
    return DEFAULT_COMMAND_RETENTION_DAYS
}

func writeCommandRetentionDays(_ days: Int) {
    var cfg = readCommandConfig()
    cfg["commandRetentionDays"] = max(1, days)
    if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: COMMAND_CONFIG))
    }
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

private var foregroundISO: ISO8601DateFormatter { handoffISO }

func appendForegroundCommandHistory(action: String, source: String, destination: String,
                                    status: String, prompt: String?, error: String?,
                                    provider: AIProvider = .claude, workspace: String? = nil) {
    let dir = "\(HANDOFF_BASE)/command-history"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let id = UUID().uuidString.lowercased()
    var d: [String: Any] = [
        "id": id,
        "createdAt": foregroundISO.string(from: Date()),
        "action": action,
        "source": source,
        "destination": destination,
        "provider": provider.rawValue,
        "status": status
    ]
    if let prompt, !prompt.isEmpty { d["prompt"] = prompt }
    if let error, !error.isEmpty { d["error"] = error }
    if let workspace, !workspace.isEmpty { d["workspace"] = workspace }
    guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(dir)/\(id).json"), options: .atomic)
}

func loadForegroundCommandHistory(limit: Int? = nil) -> [ForegroundCommandRecord] {
    let dir = "\(HANDOFF_BASE)/command-history"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var records: [ForegroundCommandRecord] = []
    for f in files where f.hasSuffix(".json") {
        guard let data = FileManager.default.contents(atPath: "\(dir)/\(f)"),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = d["id"] as? String else { continue }
        records.append(ForegroundCommandRecord(
            id: id,
            createdAt: foregroundISO.date(from: d["createdAt"] as? String ?? "") ?? .distantPast,
            action: d["action"] as? String ?? "?",
            source: d["source"] as? String ?? "?",
            destination: d["destination"] as? String ?? "code",
            status: d["status"] as? String ?? "?",
            prompt: d["prompt"] as? String,
            error: d["error"] as? String,
            provider: (d["provider"] as? String).flatMap(AIProvider.init(rawValue:)) ?? .claude,
            workspace: d["workspace"] as? String
        ))
    }
    let sorted = records.sorted { $0.createdAt > $1.createdAt }
    guard let limit = limit else { return sorted }
    return Array(sorted.prefix(limit))
}

@discardableResult
func pruneForegroundCommandHistory() -> Int {
    let cutoff = Date().addingTimeInterval(-Double(readCommandRetentionDays()) * 86400)
    let dir = "\(HANDOFF_BASE)/command-history"
    var removed = 0
    for r in loadForegroundCommandHistory(limit: nil) where isForegroundCommandPruneEligible(createdAt: r.createdAt, cutoff: cutoff) {
        try? FileManager.default.removeItem(atPath: "\(dir)/\(r.id).json")
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
    submitHandoffPrompt(prompt, source: s.source, kind: s.kind, skill: s.skill,
                        provider: s.provider, attachment: s.attachments.first ?? s.contentFile,
                        failureTitle: "Retry failed")
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
private func submitHandoffPrompt(_ prompt: String, source: String, kind: String, skill: String?,
                                 provider: AIProvider, attachment: String? = nil,
                                 failureTitle: String) {
    if provider == .codex {
        var config = HandoffConfig.load()
        if config.codexCwd.isEmpty { config.codexCwd = settingsModel.codexWorkspace }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.codexCwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            notify(failureTitle, "Codex workspace not found: \(config.codexCwd). Update it in Shortcuts or Background Settings.")
            return
        }
        let hasGit = runShell("/usr/bin/git", ["-C", config.codexCwd, "rev-parse", "--is-inside-work-tree"]).code == 0
        guard hasGit || config.codexExtraArgs.contains("--skip-git-repo-check") else {
            notify(failureTitle, "Codex workspace is not a Git repository. Choose a repository or add --skip-git-repo-check explicitly.")
            return
        }
        config.save()
    }
    let scriptDir = (bundledResource("capture-handoff.sh") as NSString).deletingLastPathComponent
    var core = (scriptDir as NSString).appendingPathComponent("claude-command-capture")
    if !FileManager.default.fileExists(atPath: core) {
        core = (scriptDir as NSString).appendingPathComponent("vendor/claude-command-capture")
    }
    let shim = (core as NSString).appendingPathComponent("bin/submit-cli.js")
    guard FileManager.default.fileExists(atPath: shim) else {
        notify(failureTitle, "Background runner missing — reinstall from the Install Guide.")
        return
    }
    guard let node = which("node") else {
        notify(failureTitle, "Node.js 20+ not found on PATH.")
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: node)
    p.arguments = [shim, "--base-dir", HANDOFF_BASE, "--retry-prompt", "--source", source,
                   "--kind", kind, "--provider", provider.rawValue]
        + (skill.map { ["--skill", $0] } ?? [])
        + (attachment.map { ["--file", $0] } ?? [])
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

func runCustomHandoff(_ ca: CustomAction, trigger: ActionTrigger, capturedText: String = "") {
    guard ca.enabled, trigger.enabled else { return }
    let skill = ca.skill.isEmpty ? nil : ca.skill
    let provider = ca.effectiveProvider(for: trigger, default: selectedProvider())
    if trigger.kind == .screenshot {
        guard screenRecordingOK() else {
            DispatchQueue.main.async {
                requestScreenRecording()
                settingsWindow.show(tab: .setup)
                notify("Screen Recording needed", "Enable Command, then restart Command to apply it.")
            }
            return
        }
        let before = NSPasteboard.general.changeCount
        let capture = runShell("/usr/sbin/screencapture", ["-i", "-c"])
        guard capture.code == 0, NSPasteboard.general.changeCount != before else {
            appendLog("[handoff] screenshot cancelled or failed")
            return
        }
        guard let file = writeClipboardImageFile() else {
            notify("Background action failed", "No image on the clipboard.")
            return
        }
        let prompt = renderCustomActionHandoffPrompt(ca, content: nil, file: file, provider: provider)
        submitHandoffPrompt(prompt, source: "screenshot", kind: "image", skill: skill,
                            provider: provider, attachment: file, failureTitle: "Background action failed")
    } else {
        // popup/voice always arrive with definitive content (typed or spoken);
        // plain text falls back to the clipboard if nothing was captured.
        let text = !capturedText.isEmpty ? capturedText
            : (trigger.kind == .text ? (NSPasteboard.general.string(forType: .string) ?? "") : "")
        guard !text.isEmpty else {
            notify("Background action failed", "Nothing selected or on the clipboard.")
            return
        }
        let source = trigger.kind == .popup ? "popup" : (trigger.kind == .voice ? "voice" : "selection")
        let prompt = renderCustomActionHandoffPrompt(ca, content: text, file: nil, provider: provider)
        submitHandoffPrompt(prompt, source: source, kind: "text", skill: skill,
                            provider: provider, failureTitle: "Background action failed")
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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Background Settings"
        w.contentViewController = NSHostingController(rootView: HandoffSettingsView())
        w.center(); w.isReleasedWhenClosed = false; w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct HandoffSettingsView: View {
    @State private var config = HandoffConfig.load()
    @State private var claudeArgsText = ""
    @State private var codexArgsText = ""
    @State private var codexPreset: CodexExecutionPreset = .readOnly
    @State private var saved = false
    @State private var testStatus = ""

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Background").font(.title2).bold()
                Spacer()
                Button("Setup Guide") { openHelpDoc(named: "background") }
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: HANDOFF_BASE))
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
            Text("Shared CLI settings for Background delivery. Custom Actions use their own prompt text; legacy settings below support older background capture flows.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                Text("Legacy default skill").font(.headline)
                TextField("e.g. triage-capture (empty = no skill line)", text: $config.skill)
                Text("Fallback for older background capture flows. Custom Actions use their own Background skill field.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            GroupBox("Claude CLI") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("command (claude, or absolute path)", text: $config.claudeCommand)
                    TextField("working directory", text: $config.claudeCwd)
                    TextField("extra args, one argument per line", text: $claudeArgsText, axis: .vertical)
                    Button("Test Claude CLI") { testCLI(command: config.claudeCommand, cwd: config.claudeCwd, label: "Claude") }
                }.padding(4)
            }

            GroupBox("Codex CLI") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("command (codex, or absolute path)", text: $config.codexCommand)
                    TextField("working directory / default workspace", text: $config.codexCwd)
                    Picker("Execution", selection: $codexPreset) {
                        ForEach(CodexExecutionPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.onChange(of: codexPreset) { _, preset in codexArgsText = preset.arguments.joined(separator: "\n") }
                    TextField("extra args, one argument per line", text: $codexArgsText, axis: .vertical)
                    Button("Test Codex CLI") { testCLI(command: config.codexCommand, cwd: config.codexCwd, label: "Codex") }
                }.padding(4)
            }

            Group {
                Text("Legacy text prompt").font(.headline)
                TextEditor(text: $config.promptTemplate)
                    .font(.system(size: 11, design: .monospaced)).frame(height: 90)
                Text("Legacy image prompt").font(.headline)
                TextEditor(text: $config.imagePromptTemplate)
                    .font(.system(size: 11, design: .monospaced)).frame(height: 90)
                Text("Placeholders: {skillInvocation} {skill} {source} {timestamp} {content} {file}")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Toggle("Desktop notifications on submit/finish", isOn: $config.notifications)
            if !testStatus.isEmpty { Text(testStatus).font(.caption).foregroundColor(.secondary) }

            HStack {
                Spacer()
                if saved { Text("Saved").foregroundColor(.secondary) }
                Button("Save") {
                    config.claudeExtraArgs = claudeArgsText.split(separator: "\n").map(String.init)
                    config.codexExtraArgs = codexArgsText.split(separator: "\n").map(String.init)
                    config.save()
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(24)
        .onAppear {
            claudeArgsText = config.claudeExtraArgs.joined(separator: "\n")
            codexArgsText = config.codexExtraArgs.joined(separator: "\n")
            codexPreset = config.codexExtraArgs.contains("workspace-write") ? .workspaceWrite : .readOnly
        }
        }
    }

    private func testCLI(command: String, cwd: String, label: String) {
        testStatus = "Testing \(label)…"
        DispatchQueue.global().async {
            let p = Process(); let pipe = Pipe()
            if command.hasPrefix("/") {
                p.executableURL = URL(fileURLWithPath: command); p.arguments = ["--version"]
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = [command, "--version"]
            }
            p.standardOutput = pipe; p.standardError = pipe
            if !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) {
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            do {
                try p.run(); p.waitUntilExit()
                let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async { testStatus = p.terminationStatus == 0 ? "\(label) ready: \(text)" : "\(label) failed: \(text)" }
            } catch {
                DispatchQueue.main.async { testStatus = "\(label) failed: \(error.localizedDescription)" }
            }
        }
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
// input — the paste-into-Claude path, or runCustomHandoff for background
// delivery. One panel, re-shown for whichever action's
// hotkey fired; each call updates the title/target instead of stacking panels.
final class CustomActionTextEntryPanel: NSObject, NSWindowDelegate {
    static let shared = CustomActionTextEntryPanel()
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var target: CustomAction?
    private var targetTrigger: ActionTrigger?

    func show(for action: CustomAction, trigger: ActionTrigger) {
        target = action
        targetTrigger = trigger
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
        guard let tv = textView, let ca = target, let trig = targetTrigger else { return }
        let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let delivery = ca.effectiveDelivery(for: trig)
        if delivery == .background {
            DispatchQueue.global().async { runCustomHandoff(ca, trigger: trig, capturedText: text) }
        } else {
            let dest = ca.effectiveDestination(for: trig).envValue
            let provider = ca.effectiveProvider(for: trig, default: selectedProvider())
            DispatchQueue.global().async {
                runWorker("custom", source: front, captured: text,
                          customPrompt: ca.prompt, customSubmit: ca.autoSubmit(for: trig),
                          customSession: delivery.sessionMode, customIncludeSource: ca.shouldIncludeSource(for: trig),
                          destination: dest, provider: provider)
            }
        }
        tv.string = ""
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        textView = nil
        target = nil
        targetTrigger = nil
    }
}
