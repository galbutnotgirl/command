// CommandTemplates.swift — user-editable wrapping text for the built-in go/comment/add
// commands, and the per-app auto-context rules (Slack, Drive, Gmail, etc.) that feed
// {context} in any of the three. Both are optional overlays: send-to-claude.sh falls
// back to its hardcoded defaults when these files are absent, so a fresh install
// behaves exactly as before until the user opens Settings and changes something.
//
// Pure model/rendering logic (CommandTemplate, EnrichRule, expandTemplate,
// composePreview, previewSources, ...) lives in
// ClaudeCommandCore/Templates.swift and is unit-tested there. This file is
// just the read/write + SwiftUI ObservableObject layer on top of it.

import Foundation
import ClaudeCommandCore

let COMMAND_TEMPLATES_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent(".claude/state/command-templates.json")

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

let ENRICHMENT_RULES_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent(".claude/state/enrichment-rules.json")

func loadEnrichRules() -> [EnrichRule] {
    guard let data = FileManager.default.contents(atPath: ENRICHMENT_RULES_PATH),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
          !arr.isEmpty else { return DEFAULT_ENRICH_RULES }
    return arr.compactMap { d in
        guard let matchRaw = d["match"], let match = EnrichMatchType(rawValue: matchRaw),
              let pattern = d["pattern"], let text = d["text"] else { return nil }
        return EnrichRule(match: match, pattern: pattern, text: text,
                           displayName: d["displayName"] ?? "", pathPrefix: d["pathPrefix"] ?? "")
    }
}

func saveEnrichRules(_ rules: [EnrichRule]) {
    let arr = rules.map { ["match": $0.match.rawValue, "pattern": $0.pattern, "text": $0.text,
                            "displayName": $0.displayName, "pathPrefix": $0.pathPrefix] }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: ENRICHMENT_RULES_PATH))
    }
}

// ---- settings-tab model ------------------------------------------------------

@MainActor
final class TemplatesModel: ObservableObject {
    @Published var templates: [CommandTemplate] = loadCommandTemplates()
    @Published var rules: [EnrichRule] = loadEnrichRules()
    private let builtInComposeActions = BUILT_IN_COMPOSE_TEMPLATE_ACTIONS

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

    var builtInComposeTemplate: String {
        let values = builtInComposeActions.compactMap { action in
            templates.first(where: { $0.action == action })?.template
        }
        guard let first = values.first else { return "" }
        return values.allSatisfy { $0 == first } ? first : first
    }

    var builtInComposeTemplatesAreUnified: Bool {
        let values = builtInComposeActions.compactMap { action in
            templates.first(where: { $0.action == action })?.template
        }
        guard let first = values.first else { return true }
        return values.allSatisfy { $0 == first }
    }

    func setBuiltInComposeTemplate(_ template: String) {
        var changed = false
        for i in templates.indices where builtInComposeActions.contains(templates[i].action) {
            if templates[i].template != template {
                templates[i].template = template
                changed = true
            }
        }
        if changed { saveCommandTemplates(templates) }
    }

    func resetBuiltInComposeTemplates() {
        for i in templates.indices {
            guard builtInComposeActions.contains(templates[i].action),
                  let def = DEFAULT_COMMAND_TEMPLATES.first(where: { $0.action == templates[i].action }) else { continue }
            templates[i] = def
        }
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
