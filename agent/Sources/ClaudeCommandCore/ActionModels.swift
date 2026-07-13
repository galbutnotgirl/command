// ActionModels.swift — the catalog of built-in actions, hotkey bindings, and
// user-defined custom actions. Pure data + pure computed properties; the
// executable target owns all the file I/O (loadBindings/saveBindings/
// loadCustomActions/saveCustomActions in Actions.swift) and hotkey
// registration side effects.

import Foundation

public struct CommandAction {
    public let id: String      // worker ACTION value (also the hotkey-config "action")
    public let name: String    // display name
    public let detail: String  // one-line description

    public init(id: String, name: String, detail: String) {
        self.id = id; self.name = name; self.detail = detail
    }
}

public let COMMAND_ACTIONS: [CommandAction] = [
    CommandAction(id: "add",         name: "Add",                detail: "Paste selection into already-open assistant session."),
    CommandAction(id: "comment",     name: "New",                detail: "New session pre-filled; stays foreground so you add a note and send."),
    CommandAction(id: "go",          name: "Go",                 detail: "New assistant session, auto-submit, then restore focus."),
    CommandAction(id: "shotadd",     name: "Screenshot Add",     detail: "Capture → paste image into the already-open Claude chat."),
    CommandAction(id: "shotcomment", name: "Screenshot New",     detail: "Capture → new session; you add a note."),
    CommandAction(id: "shotgo",      name: "Screenshot Go",      detail: "Capture → new session, auto-submit."),
    CommandAction(id: "cliphistory", name: "Clipboard History",  detail: "Floating picker of recent clips."),
    CommandAction(id: "dictate",     name: "Dictate → Insert",   detail: "Speak → on-device Parakeet transcription → paste at cursor."),
    CommandAction(id: "dictateadd",  name: "Dictate → Assistant", detail: "Speak → on-device Parakeet transcription → send to selected assistant."),
]

public func actionName(_ id: String) -> String { COMMAND_ACTIONS.first { $0.id == id }?.name ?? id }
public func actionDetail(_ id: String) -> String { COMMAND_ACTIONS.first { $0.id == id }?.detail ?? "" }

// ---- hotkey bindings ---------------------------------------------------------
// Same schema set-hotkeys.sh writes: [{action, keycode, mods}]. keycode 0 = unbound.

public struct HotkeyBinding: Identifiable {
    public let action: String
    public var keycode: UInt32
    public var mods: UInt32
    public var enabled: Bool
    public var id: String { action }
    public var human: String { keycode == 0 ? "—" : humanShortcut(keycode: keycode, mods: mods) }
    public var name: String { actionName(action) }
    public var detail: String { actionDetail(action) }

    public init(action: String, keycode: UInt32, mods: UInt32, enabled: Bool) {
        self.action = action; self.keycode = keycode; self.mods = mods; self.enabled = enabled
    }
}

// Built-in defaults — active when command-hotkeys.json is absent.
// keycodes: F6=97, F7=98, F8=100, Home=115; mods: option=2048, command=256
// User saves any binding → file is written → user values take over permanently.
public let DEFAULT_BINDINGS: [(action: String, keycode: UInt32, mods: UInt32)] = [
    ("add",         100,  2048),   // ⌥F8 — paste selection into current assistant session
    ("comment",     100,  0),      // F8  — new session, you add note
    ("go",          0,    0),      // unbound
    ("shotadd",     98,   2048),   // ⌥F7 — screenshot → current assistant session
    ("shotcomment", 98,   0),      // F7 — screenshot → new session
    ("shotgo",      0,    0),      // unbound
    ("cliphistory", 97,   0),      // F6   — clipboard history picker (only registered when enabled)
    ("dictate",     115,  0),      // Home  — dictate → insert at cursor
    ("dictateadd",  115,  2048),   // ⌥Home — dictate → send to assistant
]

// ---- custom actions ---------------------------------------------------------
// User-defined prompt templates, each with its own capture trigger (kind) and
// delivery mode (paste into Claude, or isHandoff for a background claude -p
// run with no window). Stored in ~/.claude/state/custom-actions.json (I/O
// lives in Actions.swift).

// How the action's content gets captured before the prompt is rendered:
//   text       — current selection, falling back to the clipboard
//   screenshot — a screencapture region, attached to the prompt (paste mode)
//                or saved to a file the prompt can reference via {file} (background mode)
//   popup      — a small floating text box; you type, ⌘⏎ runs it
//   voice      — press-and-hold (or double-tap to lock) to dictate, same
//                trigger model as the built-in Dictate actions
public enum ActionKind: String, CaseIterable, Codable, Sendable {
    case text, screenshot, popup, voice
    public var label: String {
        switch self {
        case .text:       return "Selected text"
        case .screenshot: return "Screenshot"
        case .popup:      return "Popup (type it)"
        case .voice:      return "Voice (dictate)"
        }
    }
}

public enum ClaudeDestination: String, CaseIterable, Codable, Sendable {
    case `default`, recent, chat, cowork, code

    public var label: String {
        switch self {
        case .default: return "Default"
        case .recent: return "Recent"
        case .chat: return "Chat"
        case .cowork: return "Cowork"
        case .code: return "Code"
        }
    }

    public var envValue: String? { self == .default ? nil : rawValue }

    public func label(for provider: AIProvider) -> String {
        guard provider == .codex else { return label }
        switch self {
        case .default: return "Default"
        case .recent: return "Recent"
        case .chat: return "Chat"
        case .code: return "Codex"
        case .cowork: return "Unsupported"
        }
    }

    public static func displayLabel(rawValue: String, provider: AIProvider) -> String {
        ClaudeDestination(rawValue: rawValue)?.label(for: provider) ?? rawValue
    }

    public static func available(for provider: AIProvider, includeDefault: Bool = true) -> [ClaudeDestination] {
        let destinations: [ClaudeDestination] = provider == .claude ? [.recent, .chat, .cowork, .code] : [.chat, .code]
        return includeDefault ? [.default] + destinations : destinations
    }
}

public enum ActionDelivery: String, CaseIterable, Codable, Sendable {
    case existingChat, newChat, background

    public var label: String {
        switch self {
        case .existingChat: return "Existing session"
        case .newChat: return "New session"
        case .background: return "Background"
        }
    }

    public var isHandoff: Bool { self == .background }
    public var sessionMode: String { self == .existingChat ? "add" : "new" }

    public static func fromLegacy(isHandoff: Bool, sessionMode: String) -> ActionDelivery {
        if isHandoff { return .background }
        return sessionMode == "add" ? .existingChat : .newChat
    }
}

// One way to fire a CustomAction: a capture kind + a hotkey, plus optional
// per-trigger overrides for the three settings that plausibly differ by
// trigger (e.g. auto-submit on for voice, off for popup). nil = inherit the
// owning CustomAction's own default — "filled or not filled", not required.
public struct ActionTrigger: Identifiable, Sendable {
    public var id: String
    public var kind: ActionKind
    public var keycode: UInt32
    public var mods: UInt32
    public var enabled: Bool
    public var isAutoSubmitOverride: Bool?
    public var sessionModeOverride: String?
    public var includeSourceOverride: Bool?
    public var deliveryOverride: ActionDelivery?
    public var destinationOverride: ClaudeDestination?
    public var providerOverride: AIProviderChoice?

    public var human: String { keycode == 0 ? "—" : humanShortcut(keycode: keycode, mods: mods) }

    public init(id: String = UUID().uuidString, kind: ActionKind, keycode: UInt32 = 0, mods: UInt32 = 0,
                enabled: Bool = true, isAutoSubmitOverride: Bool? = nil, sessionModeOverride: String? = nil,
                includeSourceOverride: Bool? = nil, deliveryOverride: ActionDelivery? = nil,
                destinationOverride: ClaudeDestination? = nil, providerOverride: AIProviderChoice? = nil) {
        self.id = id; self.kind = kind; self.keycode = keycode; self.mods = mods; self.enabled = enabled
        self.isAutoSubmitOverride = isAutoSubmitOverride
        self.sessionModeOverride = sessionModeOverride
        self.includeSourceOverride = includeSourceOverride
        self.deliveryOverride = deliveryOverride
        self.destinationOverride = destinationOverride
        self.providerOverride = providerOverride
    }
}

// A dispatched hotkey's action string encodes BOTH the owning action and the
// specific trigger that fired — one lookup finds the action, then the exact
// trigger within it (no need to scan every action's trigger list).
public func triggerActionID(actionID: String, triggerID: String) -> String {
    "customtrigger:\(actionID):\(triggerID)"
}
public func parseTriggerActionID(_ raw: String) -> (actionID: String, triggerID: String)? {
    guard raw.hasPrefix("customtrigger:") else { return nil }
    let rest = raw.dropFirst("customtrigger:".count)
    guard let sep = rest.lastIndex(of: ":") else { return nil }
    return (String(rest[rest.startIndex..<sep]), String(rest[rest.index(after: sep)...]))
}

public struct CustomAction: Identifiable, Sendable {
    public var id: String          // UUID string — stable, independent of any trigger
    public var name: String
    public var prompt: String      // template; {selection} = captured content; auto-appended if omitted
    public var isAutoSubmit: Bool  // default for triggers that don't override it (ignored if isHandoff)
    public var sessionMode: String // default for triggers that don't override it (ignored if isHandoff)
    public var includeSource: Bool // default for triggers that don't override it (ignored if isHandoff)
    public var enabled: Bool
    public var isHandoff: Bool = false  // true = background `claude -p` run (no Claude window) instead of pasting in
    public var skill: String = ""      // only used when isHandoff; target skill for the background run
    public var delivery: ActionDelivery
    public var destination: ClaudeDestination
    public var provider: AIProviderChoice
    // One shared body (name/prompt/skill/delivery), any number of ways to
    // fire it — a popup binding and a voice binding of the same action reuse
    // one prompt instead of duplicating it across separate custom actions.
    public var triggers: [ActionTrigger]

    public init(id: String, name: String, prompt: String, isAutoSubmit: Bool,
                sessionMode: String, includeSource: Bool, enabled: Bool,
                isHandoff: Bool = false, skill: String = "", delivery: ActionDelivery? = nil,
                destination: ClaudeDestination = .default, provider: AIProviderChoice = .default,
                triggers: [ActionTrigger]) {
        self.id = id; self.name = name; self.prompt = prompt
        self.isAutoSubmit = isAutoSubmit; self.sessionMode = sessionMode; self.includeSource = includeSource
        self.enabled = enabled; self.isHandoff = isHandoff; self.skill = skill
        self.delivery = delivery ?? ActionDelivery.fromLegacy(isHandoff: isHandoff, sessionMode: sessionMode)
        self.destination = destination; self.provider = provider; self.triggers = triggers
    }

    public static func makeNew(name: String, prompt: String, kind: ActionKind, isHandoff: Bool = false, skill: String = "") -> CustomAction {
        CustomAction(id: UUID().uuidString, name: name, prompt: prompt, isAutoSubmit: false,
                     sessionMode: "new", includeSource: true, enabled: true,
                     isHandoff: isHandoff, skill: skill,
                     delivery: isHandoff ? .background : .newChat,
                     destination: .default, provider: .default, triggers: [ActionTrigger(kind: kind)])
    }

    public func actionID(for trigger: ActionTrigger) -> String { triggerActionID(actionID: id, triggerID: trigger.id) }

    // Effective per-trigger settings — the override if the trigger set one, else this action's default.
    public func autoSubmit(for t: ActionTrigger) -> Bool { t.isAutoSubmitOverride ?? isAutoSubmit }
    public func effectiveDelivery(for t: ActionTrigger) -> ActionDelivery {
        t.deliveryOverride ?? t.sessionModeOverride.map { ActionDelivery.fromLegacy(isHandoff: false, sessionMode: $0) } ?? delivery
    }
    public func effectiveSessionMode(for t: ActionTrigger) -> String { effectiveDelivery(for: t).sessionMode }
    public func shouldIncludeSource(for t: ActionTrigger) -> Bool { t.includeSourceOverride ?? includeSource }
    public func effectiveDestination(for t: ActionTrigger) -> ClaudeDestination {
        t.destinationOverride ?? destination
    }
    public func effectiveProvider(for t: ActionTrigger, default defaultProvider: AIProvider) -> AIProvider {
        (t.providerOverride ?? provider).resolve(default: defaultProvider)
    }
}
