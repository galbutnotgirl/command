// CommandTemplates.swift — user-editable wrapping text for the built-in go/comment/add
// commands, and the per-app auto-context rules (Slack, Drive, Gmail, etc.) that feed
// {context} in any of the three. Both are optional overlays: send-to-claude.sh falls
// back to its hardcoded defaults when these files are absent, so a fresh install
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
    var pre: String       // text inserted before the selection — {context} works here too
    var post: String      // text inserted after the selection — {context} expands to the auto-context line
    var id: String { action }
}

// Matches the strings currently hardcoded in send-to-claude.sh, so shipping this
// feature changes nothing until a user actually edits a template. {context} is only
// in Go's default post because Go is the one action framed as "go research and act" —
// Comment/Add can use {context} too (send-to-claude.sh expands it in pre/post for all
// three), it's just not part of their *default* text.
// Order matches Settings ▸ Shortcuts (Add, New, Go) — same three actions, same order,
// wherever they show up.
let DEFAULT_COMMAND_TEMPLATES: [CommandTemplate] = [
    CommandTemplate(action: "add", pre: "", post: ""),
    CommandTemplate(action: "comment", pre: "", post: ""),
    CommandTemplate(action: "go", pre: "",
                     post: "(Right-click \"Go\": {context} Then do what's most useful and report.)"),
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
    // Friendly name for the "[from: …]" line every action includes, e.g. "Gmail" or
    // "Slack" — replaces the raw "AppName — URL" (which for a browser match is just
    // "Google Chrome — https://mail.google.com/..." — the app is noise once the URL
    // has already told you it's Gmail). Empty means fall back to "AppName — URL".
    var displayName: String = ""
}

// Mirrors the hardcoded case statements in send-to-claude.sh at time of writing.
// App-name matching (not bundle ID) throughout — Slack and Granola should be found
// and edited the same way, and app names are what you'd actually recognize/type.
let DEFAULT_ENRICH_RULES: [EnrichRule] = [
    EnrichRule(match: .app, pattern: "Slack", text: "From Slack. Use the Slack MCP to find this exact message (search by the text), then pull the channel, thread permalink, author and surrounding thread.",
               displayName: "Slack"),
    EnrichRule(match: .host, pattern: "mail.google.com", text: "From Gmail — use the Gmail MCP to find the source thread for full context.",
               displayName: "Gmail"),
    EnrichRule(match: .host, pattern: "*.atlassian.net", text: "From Jira/Confluence — use the Atlassian MCP to pull the referenced issue/page.",
               displayName: "Jira/Confluence"),
    // Docs, Sheets, and Slides all live under docs.google.com, split only by URL
    // *path* (/document/, /spreadsheets/, /presentation/) — the rule matcher only
    // does host/bundle/app, so they can't be told apart here. One Drive-branded
    // rule covers all of them, same as drive.google.com itself.
    EnrichRule(match: .host, pattern: "docs.google.com", text: "From a Google Drive file ({url}) — Docs, Sheets, or Slides; read it via gws if useful, obey the editable-doc rule before any write.",
               displayName: "Google Drive"),
    EnrichRule(match: .host, pattern: "drive.google.com", text: "From Google Drive ({url}) — use gws drive to inspect or download the file before acting.",
               displayName: "Google Drive"),
    EnrichRule(match: .host, pattern: "app.gong.io", text: "From Gong — use the Gong MCP to pull the related call/transcript.",
               displayName: "Gong"),
    EnrichRule(match: .host, pattern: "*.lightning.force.com", text: "From Salesforce — use the Salesforce MCP to pull the related record.",
               displayName: "Salesforce"),
    EnrichRule(match: .host, pattern: "*.salesforce.com", text: "From Salesforce — use the Salesforce MCP to pull the related record.",
               displayName: "Salesforce"),
    EnrichRule(match: .app, pattern: "Granola", text: "From Granola — treat the meeting transcript as context via the Granola MCP.",
               displayName: "Granola"),
    EnrichRule(match: .bundle, pattern: "com.mimestream.Mimestream", text: "From Mimestream (a Gmail client) — use the Gmail MCP to find the source thread for full context.",
               displayName: "Mimestream"),
]

func loadEnrichRules() -> [EnrichRule] {
    guard let data = FileManager.default.contents(atPath: ENRICHMENT_RULES_PATH),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
          !arr.isEmpty else { return DEFAULT_ENRICH_RULES }
    return arr.compactMap { d in
        guard let matchRaw = d["match"], let match = EnrichMatchType(rawValue: matchRaw),
              let pattern = d["pattern"], let text = d["text"] else { return nil }
        return EnrichRule(match: match, pattern: pattern, text: text, displayName: d["displayName"] ?? "")
    }
}

func saveEnrichRules(_ rules: [EnrichRule]) {
    let arr = rules.map { ["match": $0.match.rawValue, "pattern": $0.pattern, "text": $0.text, "displayName": $0.displayName] }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: ENRICHMENT_RULES_PATH))
    }
}

// ---- live preview -------------------------------------------------------------
// Mirrors send-to-claude.sh's CONTEXT/{context} composition exactly (see the
// "context + always-on enrichment" and dispatch sections there) so what you see
// in Settings ▸ Templates is what actually gets sent — not an approximation.

struct PreviewSource: Identifiable, Hashable {
    let id = UUID()
    let label: String        // shown in the picker, e.g. "Slack" or "Generic (no match)"
    let appName: String
    let url: String           // "" if the sample source has no URL (Slack, Granola, generic)
    let enrich: String        // "" for the no-match generic case
    let displayName: String   // "" falls back to "appName — url" in the [from: …] line
}

func previewSources(from rules: [EnrichRule]) -> [PreviewSource] {
    var seen = Set<String>()
    var out: [PreviewSource] = [PreviewSource(label: "Generic (no match)", appName: "Chrome", url: "", enrich: "", displayName: "")]
    for r in rules where !r.pattern.isEmpty {
        let label: String
        switch r.match {
        case .app:    label = r.pattern
        case .bundle: label = r.pattern
        case .host:   label = r.pattern.replacingOccurrences(of: "*.", with: "")
        }
        guard seen.insert(label).inserted else { continue }
        let sampleURL = r.match == .host ? "https://\(r.pattern.replacingOccurrences(of: "*.", with: "example."))/doc/123" : ""
        let app = r.match == .app ? r.pattern : (r.match == .host ? "Chrome" : label)
        out.append(PreviewSource(label: label, appName: app, url: sampleURL,
                                  enrich: r.text.replacingOccurrences(of: "{url}", with: sampleURL),
                                  displayName: r.displayName))
    }
    return out
}

// action: "go" | "comment" | "add". Set includeContext: false to preview with
// "Include source app" off (mirrors send-to-claude.sh's INCLUDE_CONTEXT=0 / a
// custom action's toggle) — the [from: …] + enrich block simply disappears.
func composePreview(action: String, pre: String, post: String,
                     source: PreviewSource, selection: String,
                     includeContext: Bool = true) -> String {
    var context = ""
    if includeContext {
        let src = !source.displayName.isEmpty ? source.displayName
            : (source.url.isEmpty ? source.appName : "\(source.appName) — \(source.url)")
        context = "[from: \(src)]\n"
        if !source.enrich.isEmpty { context += "\(source.enrich)\n" }
        context += "\n"
    }
    let contextLine = "Before acting, research for context to be maximally useful: "
        + (source.enrich.isEmpty ? "identify the source and pull any related thread, doc, message or record via the matching MCP connector." : source.enrich)
    let expandedPost = post.replacingOccurrences(of: "{context}", with: contextLine)
    let expandedPre = pre.replacingOccurrences(of: "{context}", with: contextLine)

    switch action {
    case "go":
        return context + expandedPre + selection + "\n\n" + expandedPost
    case "comment":
        return context + expandedPre + selection + expandedPost + "\n\n"
    default: // "add"
        return context + expandedPre + selection + expandedPost
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
