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
    CommandAction(id: "add",         name: "Add",                detail: "Paste the selection into the already-open Claude chat."),
    CommandAction(id: "comment",     name: "New",                detail: "New session pre-filled; stays foreground so you add a note and send."),
    CommandAction(id: "go",          name: "Go",                 detail: "New Claude session, auto-submit, then return focus to where you were."),
    CommandAction(id: "shotadd",     name: "Screenshot Add",     detail: "Capture → paste image into the already-open Claude chat."),
    CommandAction(id: "shotcomment", name: "Screenshot New",     detail: "Capture → new session; you add a note."),
    CommandAction(id: "shotgo",      name: "Screenshot Go",      detail: "Capture → new session, auto-submit."),
    CommandAction(id: "cliphistory", name: "Clipboard History",  detail: "Floating picker of recent clips."),
    CommandAction(id: "dictate",     name: "Dictate → Insert",   detail: "Speak → on-device Parakeet transcription → paste at cursor."),
    CommandAction(id: "dictateadd",  name: "Dictate → Claude",   detail: "Speak → on-device Parakeet transcription → send to Claude."),
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
// keycodes: F6=97, F7=98, F8=100; mods: none=0, option=2048
// User saves any binding → file is written → user values take over permanently.
public let DEFAULT_BINDINGS: [(action: String, keycode: UInt32, mods: UInt32)] = [
    ("add",         100,  0),      // F8  — paste selection into open Claude
    ("comment",     100,  2048),   // ⌥F8 — new session, you add note
    ("go",          0,    0),      // unbound
    ("shotadd",     98,   0),      // F7  — screenshot → open Claude
    ("shotcomment", 98,   2048),   // ⌥F7 — screenshot → new session
    ("shotgo",      0,    0),      // unbound
    ("cliphistory", 97,   0),      // F6  — clipboard history picker
    ("dictate",     96,   0),      // F5  — dictate → insert at cursor
    ("dictateadd",  96,   2048),   // ⌥F5 — dictate → send to Claude
]

// ---- custom actions ---------------------------------------------------------
// User-defined prompt templates, each with its own capture trigger (kind) and
// delivery mode (paste into Claude, or isHandoff for a background claude -p
// run with no window). Stored in ~/.claude/state/custom-actions.json (I/O
// lives in Actions.swift).

// How the action's content gets captured before the prompt is rendered:
//   text       — current selection, falling back to the clipboard
//   screenshot — a screencapture region, attached to the prompt (paste mode)
//                or saved to a file the prompt can reference via {file} (handoff mode)
//   popup      — a small floating text box; you type, ⌘⏎ runs it
//   voice      — press-and-hold (or double-tap to lock) to dictate, same
//                trigger model as the built-in Dictate actions
public enum ActionKind: String, CaseIterable, Codable, Sendable {
    case text, screenshot, popup, voice
    public var label: String {
        switch self {
        case .text:       return "Text (selection/clipboard)"
        case .screenshot: return "Screenshot"
        case .popup:      return "Popup (type it)"
        case .voice:      return "Voice (dictate)"
        }
    }
}

public struct CustomAction: Identifiable, Sendable {
    public var id: String          // UUID string — stable key for hotkey registration
    public var name: String
    public var prompt: String      // template; {selection} = captured content; auto-appended if omitted
    public var kind: ActionKind
    public var isAutoSubmit: Bool  // true = auto-press Return after pasting prompt (ignored if isHandoff)
    public var sessionMode: String // "new" = open new Claude session, "add" = paste into existing chat (ignored if isHandoff)
    public var includeSource: Bool // prepend "from: AppName — URL" context prefix (ignored if isHandoff)
    public var keycode: UInt32
    public var mods: UInt32
    public var enabled: Bool
    public var isHandoff: Bool = false  // true = background `claude -p` run (no Claude window) instead of pasting in
    public var skill: String = ""      // only used when isHandoff; target skill for the background run

    // Voice needs the press/hold/double-tap trigger state machine (like the
    // built-in Dictate actions) instead of a single fire-on-press — a
    // different Carbon dispatch path, hence its own prefix. Everything else
    // fires immediately on keydown; only isHandoff changes where it's sent.
    public var actionID: String {
        if kind == .voice { return isHandoff ? "customvoicehandoff:\(id)" : "customvoice:\(id)" }
        return isHandoff ? "customhandoff:\(id)" : "custom:\(id)"
    }
    public var human: String { keycode == 0 ? "—" : humanShortcut(keycode: keycode, mods: mods) }

    public init(id: String, name: String, prompt: String, kind: ActionKind, isAutoSubmit: Bool,
                sessionMode: String, includeSource: Bool, keycode: UInt32, mods: UInt32, enabled: Bool,
                isHandoff: Bool = false, skill: String = "") {
        self.id = id; self.name = name; self.prompt = prompt; self.kind = kind
        self.isAutoSubmit = isAutoSubmit; self.sessionMode = sessionMode; self.includeSource = includeSource
        self.keycode = keycode; self.mods = mods; self.enabled = enabled
        self.isHandoff = isHandoff; self.skill = skill
    }

    public static func makeNew(name: String, prompt: String, kind: ActionKind, isHandoff: Bool = false, skill: String = "") -> CustomAction {
        CustomAction(id: UUID().uuidString, name: name, prompt: prompt,
                     kind: kind, isAutoSubmit: false, sessionMode: "new",
                     includeSource: true, keycode: 0, mods: 0, enabled: true,
                     isHandoff: isHandoff, skill: skill)
    }
}
