// HandoffModels.swift — pure model + rendering logic for background skill
// handoffs. File I/O (loadHandoffSubmissions, retention pruning, the actual
// submit-cli.js process launch) lives in Handoff.swift (executable target);
// this is the part that's unit-testable without touching disk or a clock.

import Foundation

public struct HandoffSubmission: Identifiable {
    public let id: String
    public let createdAt: Date
    public let finishedAt: Date?
    public let source: String
    public let kind: String
    public let skill: String?
    public let status: String   // running | succeeded | failed
    public let exitCode: Int?
    public let error: String?
    public let prompt: String?
    public let contentFile: String?
    public let logFile: String?
    // Last stdout line matching KEY=value, if the prompt's own contract asked
    // for one (see runner.js's extractResult) — nil until the run finishes, and
    // stays nil if the CLI never printed a matching line.
    public let result: String?
    public let provider: AIProvider
    public let workspace: String?
    public let attachments: [String]

    public init(id: String, createdAt: Date, finishedAt: Date?, source: String, kind: String,
                skill: String?, status: String, exitCode: Int?, error: String?, prompt: String?,
                contentFile: String?, logFile: String?, result: String? = nil,
                provider: AIProvider = .claude, workspace: String? = nil, attachments: [String] = []) {
        self.id = id; self.createdAt = createdAt; self.finishedAt = finishedAt
        self.source = source; self.kind = kind; self.skill = skill; self.status = status
        self.exitCode = exitCode; self.error = error; self.prompt = prompt
        self.contentFile = contentFile; self.logFile = logFile; self.result = result
        self.provider = provider; self.workspace = workspace; self.attachments = attachments
    }

    // A record can stay "running" forever if the CLI (or the machine) died
    // before the updater rewrote it — flag those instead of an eternal spinner.
    public var isStalled: Bool { isHandoffStalled(status: status, createdAt: createdAt) }
    public var statusGlyph: String { handoffStatusGlyph(status: status, isStalled: isStalled) }
    public var age: String { handoffAgeString(createdAt: createdAt) }
    public var menuTitle: String {
        handoffMenuTitle(statusGlyph: statusGlyph, source: source, skill: skill, age: age,
                         isStalled: isStalled, result: result, provider: provider)
    }
}

// `now` defaults to the real clock for production call sites; tests pass a
// fixed Date so staleness/age math doesn't depend on wall-clock time.
public func isHandoffStalled(status: String, createdAt: Date, now: Date = Date()) -> Bool {
    status == "running" && createdAt.timeIntervalSince(now) < -1800
}

public func handoffStatusGlyph(status: String, isStalled: Bool) -> String {
    if status == "succeeded" { return "✓" }
    if status == "failed" { return "✗" }
    return isStalled ? "⚠" : "…"
}

public func handoffAgeString(createdAt: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(createdAt))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

public func handoffMenuTitle(statusGlyph: String, source: String, skill: String?, age: String,
                              isStalled: Bool, result: String? = nil,
                              provider: AIProvider = .claude) -> String {
    let target = (skill?.isEmpty == false) ? provider.skillInvocation(skill!) :
        (provider == .claude ? "claude -p" : "codex exec")
    let base = "\(statusGlyph) \(source) → \(target) — \(age)\(isStalled ? " (stalled?)" : "")"
    guard let result, !result.isEmpty else { return base }
    return "\(base) — \(result)"
}

// Retention pruning eligibility — running submissions are never pruned,
// however old (a stalled run is handled by markHandoffSubmissionFailed
// instead of silently deleting it out from under the user).
public func isHandoffPruneEligible(status: String, createdAt: Date, cutoff: Date) -> Bool {
    status != "running" && createdAt < cutoff
}

// Foreground command history covers paste/new-chat runs that do not create
// background handoff submissions.
public struct ForegroundCommandRecord: Identifiable {
    public let id: String
    public let createdAt: Date
    public let action: String
    public let source: String
    public let destination: String
    public let status: String
    public let prompt: String?
    public let error: String?
    public let provider: AIProvider
    public let workspace: String?

    public init(id: String, createdAt: Date, action: String, source: String, destination: String,
                status: String, prompt: String?, error: String?, provider: AIProvider = .claude,
                workspace: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.action = action
        self.source = source
        self.destination = destination
        self.status = status
        self.prompt = prompt
        self.error = error
        self.provider = provider
        self.workspace = workspace
    }

    public var age: String { foregroundCommandAgeString(createdAt: createdAt) }
}

public func foregroundCommandAgeString(createdAt: Date, now: Date = Date()) -> String {
    handoffAgeString(createdAt: createdAt, now: now)
}

public func isForegroundCommandPruneEligible(createdAt: Date, cutoff: Date) -> Bool {
    createdAt < cutoff
}

// ---- custom actions run as background handoffs (isHandoff == true) ---------
// Same {selection} convention as a regular custom action's prompt (see
// CustomAction's doc comment): inline if present, otherwise appended below.
// Screenshot mode has no window to paste an image into, so the file path is
// inlined the same way — via {file}, or appended if the template omits it.
public func renderCustomActionHandoffPrompt(_ ca: CustomAction, content: String?, file: String?,
                                             provider: AIProvider = .claude) -> String {
    var body = ca.prompt
    if let content {
        if body.contains("{selection}") {
            body = body.replacingOccurrences(of: "{selection}", with: content)
        } else {
            body = body.isEmpty ? content : "\(body)\n\n\(content)"
        }
    }
    if let file {
        if body.contains("{file}") {
            body = body.replacingOccurrences(of: "{file}", with: file)
        } else {
            body += "\n\nA captured image was saved to: \(file)\nRead that file to view the capture."
        }
    }
    let skill = ca.skill.trimmingCharacters(in: .whitespaces)
    if !skill.isEmpty { body = "\(provider.skillInvocation(skill))\n\n\(body)" }
    return body
}
