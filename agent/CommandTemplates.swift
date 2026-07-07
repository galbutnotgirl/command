// CommandTemplates.swift — user-editable wrapping text for the built-in go/comment/add
// commands, and the per-app auto-context rules (Slack, Drive, Gmail, etc.) that get
// woven into "Go"'s research instruction. Both are optional overlays: send-to-claude.sh
// falls back to its hardcoded defaults when these files are absent, so a fresh install
// behaves exactly as before until the user opens Settings and changes something.
//
// Backlog (not built yet — moved here from the old top-level BACKLOG.md):
//   - Update functionality: agent/Updater.swift already checks GitHub releases; the
//     actual download/install/relaunch flow still needs wiring up.
//   - Release functionality: release.sh exists but needs review/hardening — version
//     bump, build, sign, notarize?, tag, GitHub release upload.
//   - Bug submissions: a way for users to report bugs from inside the app (e.g. a menu
//     item that opens a pre-filled GitHub issue, or a "Send Feedback" flow with logs
//     attached).

import Foundation

// ---- command wrap templates (pre/post text around the selection) -----------

let COMMAND_TEMPLATES_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent(".claude/state/command-templates.json")

struct CommandTemplate: Identifiable {
    let action: String   // "go" | "comment" | "add"
    var pre: String       // text inserted before the selection
    var post: String      // text inserted after the selection — {research} expands to the auto-context line
    var id: String { action }
}

// Matches the strings currently hardcoded in send-to-claude.sh, so shipping this
// feature changes nothing until a user actually edits a template.
let DEFAULT_COMMAND_TEMPLATES: [CommandTemplate] = [
    CommandTemplate(action: "go", pre: "",
                     post: "(Right-click \"Go\": {research} Then do what's most useful and report.)"),
    CommandTemplate(action: "comment", pre: "", post: ""),
    CommandTemplate(action: "add", pre: "", post: ""),
]

func loadCommandTemplates() -> [CommandTemplate] {
    var byAction: [String: CommandTemplate] = [:]
    for d in DEFAULT_COMMAND_TEMPLATES { byAction[d.action] = d }
    if let data = FileManager.default.contents(atPath: COMMAND_TEMPLATES_PATH),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
        for (action, fields) in obj {
            guard byAction[action] != nil else { continue }   // only known built-in actions
            byAction[action] = CommandTemplate(action: action,
                                                pre: fields["pre"] ?? "",
                                                post: fields["post"] ?? "")
        }
    }
    return DEFAULT_COMMAND_TEMPLATES.map { byAction[$0.action] ?? $0 }
}

func saveCommandTemplates(_ templates: [CommandTemplate]) {
    var obj: [String: [String: String]] = [:]
    for t in templates { obj[t.action] = ["pre": t.pre, "post": t.post] }
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: COMMAND_TEMPLATES_PATH))
    }
}

// ---- auto-context (enrichment) rules ----------------------------------------
// "This came from Slack / a Google Doc / Gong" — the hint send-to-claude.sh feeds
// Claude so it knows to pull the source thread/doc via the matching MCP.

let ENRICHMENT_RULES_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent(".claude/state/enrichment-rules.json")

enum EnrichMatchType: String, CaseIterable, Identifiable {
    case bundle   // exact app bundle ID, e.g. com.tinyspeck.slackmacgap
    case host     // URL host, glob-style ("*.atlassian.net")
    case app      // frontmost app display name, e.g. "Granola"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bundle: return "App bundle ID"
        case .host:   return "URL host"
        case .app:    return "App name"
        }
    }
}

struct EnrichRule: Identifiable {
    let id = UUID()
    var match: EnrichMatchType
    var pattern: String     // supports * glob for host; exact match otherwise
    var text: String        // {url} expands to the source URL when present
}

// Mirrors the hardcoded case statements in send-to-claude.sh at time of writing.
let DEFAULT_ENRICH_RULES: [EnrichRule] = [
    EnrichRule(match: .bundle, pattern: "com.tinyspeck.slackmacgap",
               text: "This is from Slack. Use the Slack MCP to find this exact message (search by the text), then pull the channel, thread permalink, author and surrounding thread."),
    EnrichRule(match: .host, pattern: "mail.google.com",
               text: "From Gmail — use the Gmail MCP to find the source thread for full context."),
    EnrichRule(match: .host, pattern: "*.atlassian.net",
               text: "From Jira/Confluence — use the Atlassian MCP to pull the referenced issue/page."),
    EnrichRule(match: .host, pattern: "docs.google.com",
               text: "From a Google Doc ({url}) — read it via gws if useful; obey the editable-doc rule before any write."),
    EnrichRule(match: .host, pattern: "drive.google.com",
               text: "From Google Drive ({url}) — use gws drive to inspect or download the file before acting."),
    EnrichRule(match: .host, pattern: "app.gong.io",
               text: "From Gong — use the Gong MCP to pull the related call/transcript."),
    EnrichRule(match: .host, pattern: "*.lightning.force.com",
               text: "From Salesforce — use the Salesforce MCP to pull the related record."),
    EnrichRule(match: .host, pattern: "*.salesforce.com",
               text: "From Salesforce — use the Salesforce MCP to pull the related record."),
    EnrichRule(match: .app, pattern: "Granola",
               text: "From Granola — treat the meeting transcript as context via the Granola MCP."),
]

func loadEnrichRules() -> [EnrichRule] {
    guard let data = FileManager.default.contents(atPath: ENRICHMENT_RULES_PATH),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
          !arr.isEmpty else { return DEFAULT_ENRICH_RULES }
    return arr.compactMap { d in
        guard let matchRaw = d["match"], let match = EnrichMatchType(rawValue: matchRaw),
              let pattern = d["pattern"], let text = d["text"] else { return nil }
        return EnrichRule(match: match, pattern: pattern, text: text)
    }
}

func saveEnrichRules(_ rules: [EnrichRule]) {
    let arr = rules.map { ["match": $0.match.rawValue, "pattern": $0.pattern, "text": $0.text] }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: ENRICHMENT_RULES_PATH))
    }
}

// ---- settings-tab model ------------------------------------------------------

@MainActor
final class TemplatesModel: ObservableObject {
    @Published var templates: [CommandTemplate] = loadCommandTemplates()
    @Published var rules: [EnrichRule] = loadEnrichRules()

    func setTemplate(action: String, pre: String? = nil, post: String? = nil) {
        guard let i = templates.firstIndex(where: { $0.action == action }) else { return }
        if let pre = pre { templates[i].pre = pre }
        if let post = post { templates[i].post = post }
        saveCommandTemplates(templates)
    }

    func resetTemplate(action: String) {
        guard let i = templates.firstIndex(where: { $0.action == action }),
              let def = DEFAULT_COMMAND_TEMPLATES.first(where: { $0.action == action }) else { return }
        templates[i] = def
        saveCommandTemplates(templates)
    }

    func addRule() {
        rules.append(EnrichRule(match: .host, pattern: "", text: ""))
        saveEnrichRules(rules)
    }
    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        saveEnrichRules(rules)
    }
    func updateRule(_ rule: EnrichRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
        saveEnrichRules(rules)
    }
    func resetRulesToDefault() {
        rules = DEFAULT_ENRICH_RULES
        saveEnrichRules(rules)
    }
}
