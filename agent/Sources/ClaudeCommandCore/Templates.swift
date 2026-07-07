// Templates.swift — pure model + rendering logic for command wrap templates
// (go/comment/add) and Context auto-enrichment rules. File I/O and the
// SwiftUI ObservableObject model live in CommandTemplates.swift (executable
// target); this is the part that's unit-testable without touching disk.
//
// send-to-claude.sh's send-to-claude-lib.sh (expand_template) and
// match-enrich-rule.py mirror this logic on the shell side — keep both in
// sync by hand; test/test-shell.sh covers that half.

import Foundation

// Placeholders available in any CommandTemplate.template or EnrichRule.text:
//   {selection} / {prompt} / {text}  — the captured selection (aliases, pick whichever reads better)
//   {context}                        — the matching Context rule's hint, wrapped in a "go research this" instruction
//   {source}                         — "[from: AppName]" (or the rule's Display name, or "AppName — URL")
//   {url}                            — the raw source URL, or "" if there wasn't one
// {selection} is auto-appended at the end if you leave it out (never silently dropped).
// {source} is auto-prepended at the top if you leave it out, so it still guides Claude
// even in a template you haven't touched — same "use it if present, sensible fallback if
// not" rule for both, rather than two different behaviors to remember.
public struct TemplateVariable: Identifiable {
    public let token: String; public let label: String; public let detail: String
    public var id: String { token }
    public init(token: String, label: String, detail: String) {
        self.token = token; self.label = label; self.detail = detail
    }
}
public let TEMPLATE_VARIABLES: [TemplateVariable] = [
    TemplateVariable(token: "{selection}", label: "Selection",
                      detail: "The captured text (aliases: {prompt}, {text}). Auto-appended at the end if omitted."),
    TemplateVariable(token: "{context}", label: "Context",
                      detail: "The matching Context rule's hint, wrapped in a \"research this before acting\" instruction."),
    TemplateVariable(token: "{source}", label: "Source",
                      detail: "\"[from: AppName]\" — or a rule's Display name, or \"AppName — URL\". Auto-prepended at the top if omitted."),
    TemplateVariable(token: "{url}", label: "URL",
                      detail: "The raw source URL, if the source app had one — empty string otherwise."),
]

public struct CommandTemplate: Identifiable {
    public let action: String   // "go" | "comment" | "add"
    public var template: String
    public var id: String { action }
    public init(action: String, template: String) { self.action = action; self.template = template }
}

// Matches the strings currently hardcoded in send-to-claude.sh, so shipping this
// feature changes nothing until a user actually edits a template.
// Order matches Settings ▸ Shortcuts (Add, New, Go) — same three actions, same order,
// wherever they show up.
public let DEFAULT_COMMAND_TEMPLATES: [CommandTemplate] = [
    CommandTemplate(action: "add", template: "{selection}"),
    CommandTemplate(action: "comment", template: "{selection}"),
    CommandTemplate(action: "go",
                     template: "{selection}\n\n(Right-click \"Go\": {context} Then do what's most useful and report.)"),
]

// ---- auto-context (enrichment) rules ----------------------------------------
// "This came from Slack / a Google Doc / Gong" — the hint send-to-claude.sh feeds
// Claude so it knows to pull the source thread/doc via the matching MCP.

public enum EnrichMatchType: String, CaseIterable, Identifiable {
    case bundle   // exact app bundle ID, e.g. com.tinyspeck.slackmacgap
    case host     // URL host, glob-style ("*.atlassian.net")
    case app      // frontmost app display name, e.g. "Granola"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .bundle: return "App bundle ID"
        case .host:   return "URL host"
        case .app:    return "App name"
        }
    }
}

public struct EnrichRule: Identifiable {
    public let id = UUID()
    public var match: EnrichMatchType
    public var pattern: String     // supports * glob for host; exact match otherwise
    public var text: String        // {url} expands to the source URL when present
    // Friendly name for the "[from: …]" line every action includes, e.g. "Gmail" or
    // "Slack" — replaces the raw "AppName — URL" (which for a browser match is just
    // "Google Chrome — https://mail.google.com/..." — the app is noise once the URL
    // has already told you it's Gmail). Empty means fall back to "AppName — URL".
    public var displayName: String = ""
    // Host-only refinement: require the URL's path to start with this too, e.g.
    // "/document/" to mean Google Docs specifically rather than any docs.google.com
    // URL. Empty (the common case) matches on host alone. Ignored for bundle/app rules.
    public var pathPrefix: String = ""

    public init(match: EnrichMatchType, pattern: String, text: String, displayName: String = "", pathPrefix: String = "") {
        self.match = match; self.pattern = pattern; self.text = text
        self.displayName = displayName; self.pathPrefix = pathPrefix
    }
}

// Mirrors the hardcoded case statements in send-to-claude.sh at time of writing.
// App-name matching (not bundle ID) throughout — Slack and Granola should be found
// and edited the same way, and app names are what you'd actually recognize/type.
public let DEFAULT_ENRICH_RULES: [EnrichRule] = [
    EnrichRule(match: .app, pattern: "Slack", text: "From Slack. Use the Slack MCP to find this exact message (search by the text), then pull the channel, thread permalink, author and surrounding thread.",
               displayName: "Slack"),
    EnrichRule(match: .host, pattern: "mail.google.com", text: "From Gmail — use the Gmail MCP to find the source thread for full context.",
               displayName: "Gmail"),
    EnrichRule(match: .host, pattern: "*.atlassian.net", text: "From Jira/Confluence — use the Atlassian MCP to pull the referenced issue/page.",
               displayName: "Jira/Confluence"),
    // Docs, Sheets, and Slides all live under docs.google.com, split only by URL
    // *path* (/document/, /spreadsheets/, /presentation/) — pathPrefix tells them
    // apart now that the matcher supports it (host alone can't).
    EnrichRule(match: .host, pattern: "docs.google.com", text: "From a Google Doc ({url}) — read it via gws if useful, obey the editable-doc rule before any write.",
               displayName: "Google Docs", pathPrefix: "/document/"),
    EnrichRule(match: .host, pattern: "docs.google.com", text: "From a Google Sheet ({url}) — read it via gws if useful, obey the editable-doc rule before any write.",
               displayName: "Google Sheets", pathPrefix: "/spreadsheets/"),
    EnrichRule(match: .host, pattern: "docs.google.com", text: "From a Google Slides deck ({url}) — read it via gws if useful, obey the editable-doc rule before any write.",
               displayName: "Google Slides", pathPrefix: "/presentation/"),
    // Fallback for anything else under docs.google.com (rare — most traffic hits
    // one of the three paths above) or drive.google.com itself, where a file's
    // Docs/Sheets/Slides-ness isn't in the URL at all.
    EnrichRule(match: .host, pattern: "docs.google.com",
               text: "From a Google Drive file ({url}) — Docs, Sheets, or Slides; read it via gws if useful, obey the editable-doc rule before any write.",
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

// ---- live preview -------------------------------------------------------------
// Mirrors send-to-claude.sh's CONTEXT/{context} composition exactly (see the
// "context + always-on enrichment" and dispatch sections there) so what you see
// in Settings ▸ Templates is what actually gets sent — not an approximation.

public struct PreviewSource: Identifiable, Hashable {
    public let id = UUID()
    public let label: String        // shown in the picker, e.g. "Slack" or "Generic (no match)"
    public let appName: String
    public let url: String           // "" if the sample source has no URL (Slack, Granola, generic)
    public let enrich: String        // "" for the no-match generic case
    public let displayName: String   // "" falls back to "appName — url" in the [from: …] line

    public init(label: String, appName: String, url: String, enrich: String, displayName: String) {
        self.label = label; self.appName = appName; self.url = url
        self.enrich = enrich; self.displayName = displayName
    }
}

public func previewSources(from rules: [EnrichRule]) -> [PreviewSource] {
    var seen = Set<String>()
    var out: [PreviewSource] = [PreviewSource(label: "Generic (no match)", appName: "Chrome", url: "", enrich: "", displayName: "")]
    for r in rules where !r.pattern.isEmpty {
        var baseLabel: String
        switch r.match {
        case .app:    baseLabel = r.pattern
        case .bundle: baseLabel = r.pattern
        case .host:   baseLabel = r.pattern.replacingOccurrences(of: "*.", with: "")
        }
        if !r.pathPrefix.isEmpty { baseLabel = "\(baseLabel)\(r.pathPrefix)" }

        // Prefer the friendly displayName whenever one's set — not just for
        // pathPrefix rules — so the picker shows "Gmail" instead of
        // "mail.google.com" the same way it shows "Google Docs" instead of
        // "docs.google.com/document/". Multiple rules can still share a
        // displayName (e.g. the docs.google.com fallback and drive.google.com
        // both say "Google Drive") — disambiguate with the raw pattern rather
        // than silently dropping the second one from the picker.
        var label = !r.displayName.isEmpty ? r.displayName : baseLabel
        if seen.contains(label) { label = "\(label) (\(baseLabel))" }
        guard seen.insert(label).inserted else { continue }

        let samplePath = r.pathPrefix.isEmpty ? "/doc/123" : "\(r.pathPrefix)abc123"
        let sampleURL = r.match == .host ? "https://\(r.pattern.replacingOccurrences(of: "*.", with: "example."))\(samplePath)" : ""
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
public func expandTemplate(_ template: String, selection: String, source: String, url: String, contextLine: String) -> String {
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
public func composePreview(action: String, template: String,
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
