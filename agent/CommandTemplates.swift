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

// ---- command wrap templates: one string, placeholders mark where things go ---
// Was a separate "before"/"after" pair per action — collapsed to a single string
// with {selection} marking where the captured text goes, same model custom actions
// already use ({selection}/{text} in CustomAction.prompt, see Actions.swift). One
// text box instead of two, and the same mental model everywhere in the app.

let COMMAND_TEMPLATES_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent(".claude/state/command-templates.json")

// Placeholders available in any CommandTemplate.template or EnrichRule.text:
//   {selection} / {prompt} / {text}  — the captured selection (aliases, pick whichever reads better)
//   {context}                        — the matching Context rule's hint, wrapped in a "go research this" instruction
//   {source}                         — "[from: AppName]" (or the rule's Display name, or "AppName — URL")
//   {url}                            — the raw source URL, or "" if there wasn't one
// {selection} is auto-appended at the end if you leave it out (never silently dropped).
// {source} is auto-prepended at the top if you leave it out, so it still guides Claude
// even in a template you haven't touched — same "use it if present, sensible fallback if
// not" rule for both, rather than two different behaviors to remember.
struct TemplateVariable: Identifiable {
    let token: String; let label: String; let detail: String
    var id: String { token }
}
let TEMPLATE_VARIABLES: [TemplateVariable] = [
    TemplateVariable(token: "{selection}", label: "Selection",
                      detail: "The captured text (aliases: {prompt}, {text}). Auto-appended at the end if omitted."),
    TemplateVariable(token: "{context}", label: "Context",
                      detail: "The matching Context rule's hint, wrapped in a \"research this before acting\" instruction."),
    TemplateVariable(token: "{source}", label: "Source",
                      detail: "\"[from: AppName]\" — or a rule's Display name, or \"AppName — URL\". Auto-prepended at the top if omitted."),
    TemplateVariable(token: "{url}", label: "URL",
                      detail: "The raw source URL, if the source app had one — empty string otherwise."),
]

struct CommandTemplate: Identifiable {
    let action: String   // "go" | "comment" | "add"
    var template: String
    var id: String { action }
}

// Matches the strings currently hardcoded in send-to-claude.sh, so shipping this
// feature changes nothing until a user actually edits a template.
// Order matches Settings ▸ Shortcuts (Add, New, Go) — same three actions, same order,
// wherever they show up.
let DEFAULT_COMMAND_TEMPLATES: [CommandTemplate] = [
    CommandTemplate(action: "add", template: "{selection}"),
    CommandTemplate(action: "comment", template: "{selection}"),
    CommandTemplate(action: "go",
                     template: "{selection}\n\n(Right-click \"Go\": {context} Then do what's most useful and report.)"),
]

func loadCommandTemplates() -> [CommandTemplate] {
    var byAction: [String: CommandTemplate] = [:]
    for d in DEFAULT_COMMAND_TEMPLATES { byAction[d.action] = d }
    if let data = FileManager.default.contents(atPath: COMMAND_TEMPLATES_PATH),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        for (action, template) in obj {
            guard byAction[action] != nil else { continue }   // only known built-in actions
            byAction[action] = CommandTemplate(action: action, template: template)
        }
    }
    return DEFAULT_COMMAND_TEMPLATES.map { byAction[$0.action] ?? $0 }
}

func saveCommandTemplates(_ templates: [CommandTemplate]) {
    var obj: [String: String] = [:]
    for t in templates { obj[t.action] = t.template }
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

// Expands {selection}/{prompt}/{text}, {context}, {source}, {url} in one template
// string. {selection} is appended at the end if missing; {source} is prepended at
// the top if missing — so an untouched template (no placeholders at all) produces
// exactly what the old hardcoded pre/post model did, and a template that uses every
// placeholder explicitly has full control over the ordering. send-to-claude.sh
// mirrors this exact logic — see its expand_template() function.
func expandTemplate(_ template: String, selection: String, source: String, url: String, contextLine: String) -> String {
    var t = template
    for token in ["{selection}", "{prompt}", "{text}"] { t = t.replacingOccurrences(of: token, with: selection) }
    t = t.replacingOccurrences(of: "{context}", with: contextLine)
    t = t.replacingOccurrences(of: "{url}", with: url)

    let hadSelection = template.contains("{selection}") || template.contains("{prompt}") || template.contains("{text}")
    if !hadSelection {
        t = t.isEmpty ? selection : t + "\n\n" + selection
    }
    if template.contains("{source}") {
        t = t.replacingOccurrences(of: "{source}", with: source)
    } else if !source.isEmpty {
        t = "\(source)\n\n\(t)"
    }
    return t
}

// action: "go" | "comment" | "add". Set includeContext: false to preview with
// "Include source app" off (mirrors send-to-claude.sh's INCLUDE_CONTEXT=0 / a
// custom action's toggle) — the {source} substitution/auto-prepend simply doesn't happen.
func composePreview(action: String, template: String,
                     source: PreviewSource, selection: String,
                     includeContext: Bool = true) -> String {
    let srcText: String
    if includeContext {
        let name = !source.displayName.isEmpty ? source.displayName
            : (source.url.isEmpty ? source.appName : "\(source.appName) — \(source.url)")
        srcText = "[from: \(name)]" + (source.enrich.isEmpty ? "" : "\n\(source.enrich)")
    } else {
        srcText = ""
    }
    let contextLine = "Before acting, research for context to be maximally useful: "
        + (source.enrich.isEmpty ? "identify the source and pull any related thread, doc, message or record via the matching MCP connector." : source.enrich)
    return expandTemplate(template, selection: selection, source: srcText, url: source.url, contextLine: contextLine)
}

// ---- settings-tab model ------------------------------------------------------

@MainActor
final class TemplatesModel: ObservableObject {
    @Published var templates: [CommandTemplate] = loadCommandTemplates()
    @Published var rules: [EnrichRule] = loadEnrichRules()

    func setTemplate(action: String, template: String) {
        guard let i = templates.firstIndex(where: { $0.action == action }) else { return }
        templates[i].template = template
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
