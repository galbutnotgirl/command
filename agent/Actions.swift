// Actions.swift — the single source of truth for Claude Command's actions and
// the Carbon key maps shared by the menu, the Shortcuts editor, and (mirrored
// in) set-hotkeys.sh. Adding an action here surfaces it everywhere.

import Foundation

struct CommandAction {
    let id: String      // worker ACTION value (also the hotkey-config "action")
    let name: String    // display name
    let detail: String  // one-line description
}

let COMMAND_ACTIONS: [CommandAction] = [
    CommandAction(id: "add",         name: "Add",                detail: "Paste the selection into the already-open Claude chat."),
    CommandAction(id: "comment",     name: "New",                detail: "New session pre-filled; stays foreground so you add a note and send."),
    CommandAction(id: "go",          name: "Go",                 detail: "New Claude session, auto-submit, then return focus to where you were."),
    CommandAction(id: "shotadd",     name: "Screenshot Add",     detail: "Capture → paste image into the already-open Claude chat."),
    CommandAction(id: "shotcomment", name: "Screenshot New",     detail: "Capture → new session; you add a note."),
    CommandAction(id: "shotgo",      name: "Screenshot Go",      detail: "Capture → new session, auto-submit."),
    CommandAction(id: "cliphistory", name: "Clipboard History",  detail: "Floating picker of recent clips."),
    CommandAction(id: "handoff",     name: "Skill Handoff",      detail: "Selection → background claude -p run of your configured skill."),
    CommandAction(id: "shothandoff", name: "Screenshot Handoff", detail: "Capture → background claude -p run of your configured skill."),
    CommandAction(id: "handofftext", name: "Text Handoff",       detail: "Quick entry window → background claude -p run of your configured skill."),
    CommandAction(id: "dictate",     name: "Dictate → Insert",   detail: "Speak → on-device Parakeet transcription → paste at cursor."),
    CommandAction(id: "dictateadd",  name: "Dictate → Claude",   detail: "Speak → on-device Parakeet transcription → send to Claude."),
]

func actionName(_ id: String) -> String { COMMAND_ACTIONS.first { $0.id == id }?.name ?? id }
func actionDetail(_ id: String) -> String { COMMAND_ACTIONS.first { $0.id == id }?.detail ?? "" }

// ---- Carbon keycode/modifier maps (mirror set-hotkeys.sh) ------------------
// Carbon modifier masks: command 256, shift 512, option 2048, control 4096.
let CARBON_MODS: [(symbol: String, mask: UInt32)] = [
    ("⌃", 4096),   // control
    ("⌥", 2048),   // option
    ("⇧", 512),    // shift
    ("⌘", 256),    // command
]

// Carbon virtual keycode → display label.
let KEYCODE_NAMES: [UInt32: String] = [
    0:"A",11:"B",8:"C",2:"D",14:"E",3:"F",5:"G",4:"H",34:"I",38:"J",40:"K",
    37:"L",46:"M",45:"N",31:"O",35:"P",12:"Q",15:"R",1:"S",17:"T",32:"U",
    9:"V",13:"W",7:"X",16:"Y",6:"Z",18:"1",19:"2",20:"3",21:"4",23:"5",
    22:"6",26:"7",28:"8",25:"9",29:"0",49:"Space",
    122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",
    101:"F9",109:"F10",103:"F11",111:"F12",
    115:"Home",119:"End",116:"PgUp",121:"PgDn",117:"⌦",
]

func humanShortcut(keycode: UInt32, mods: UInt32) -> String {
    var s = ""
    for mod in CARBON_MODS where (mods & mod.mask) != 0 { s += mod.symbol }
    s += KEYCODE_NAMES[keycode] ?? "?"
    return s
}

#if canImport(AppKit)
import AppKit
// Convert Cocoa modifier flags (from a recorded NSEvent) into Carbon masks.
func carbonMods(from f: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if f.contains(.command) { m |= 256 }
    if f.contains(.shift)   { m |= 512 }
    if f.contains(.option)  { m |= 2048 }
    if f.contains(.control) { m |= 4096 }
    return m
}
#endif

// ---- hotkey bindings: read/write ~/.claude/state/command-hotkeys.json -------
// Same schema set-hotkeys.sh writes: [{action, keycode, mods}]. keycode 0 = unbound.

struct HotkeyBinding: Identifiable {
    let action: String
    var keycode: UInt32
    var mods: UInt32
    var enabled: Bool
    var id: String { action }
    var human: String { keycode == 0 ? "—" : humanShortcut(keycode: keycode, mods: mods) }
    var name: String { actionName(action) }
    var detail: String { actionDetail(action) }
}

// Built-in defaults — active when command-hotkeys.json is absent.
// keycodes: F6=97, F7=98, F8=100; mods: none=0, option=2048
// User saves any binding → file is written → user values take over permanently.
let DEFAULT_BINDINGS: [(action: String, keycode: UInt32, mods: UInt32)] = [
    ("add",         100,  0),      // F8  — paste selection into open Claude
    ("comment",     100,  2048),   // ⌥F8 — new session, you add note
    ("go",          0,    0),      // unbound
    ("shotadd",     98,   0),      // F7  — screenshot → open Claude
    ("shotcomment", 98,   2048),   // ⌥F7 — screenshot → new session
    ("shotgo",      0,    0),      // unbound
    ("cliphistory", 97,   0),      // F6  — clipboard history picker
    ("handoff",     0,    0),      // unbound — background skill handoff
    ("shothandoff", 0,    0),      // unbound — screenshot skill handoff
    ("handofftext", 0,    0),      // unbound — text-entry skill handoff
    ("dictate",     96,   0),      // F5  — dictate → insert at cursor
    ("dictateadd",  96,   2048),   // ⌥F5 — dictate → send to Claude
]

// One binding per catalog action, in catalog order; unbound actions get keycode 0.
func loadBindings() -> [HotkeyBinding] {
    var byAction: [String: HotkeyBinding] = [:]
    let hasFile = FileManager.default.fileExists(atPath: CFG)
    if hasFile, let data = FileManager.default.contents(atPath: CFG),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        for d in arr {
            if let a = d["action"] as? String, let k = d["keycode"] as? Int, let m = d["mods"] as? Int {
                let en = d["enabled"] as? Bool ?? true
                byAction[a] = HotkeyBinding(action: a, keycode: UInt32(k), mods: UInt32(m), enabled: en)
            }
        }
    } else {
        // No user file — seed from built-in defaults so Settings shows real bindings.
        for def in DEFAULT_BINDINGS {
            byAction[def.action] = HotkeyBinding(action: def.action, keycode: def.keycode, mods: def.mods, enabled: true)
        }
    }
    return COMMAND_ACTIONS.map { byAction[$0.id] ?? HotkeyBinding(action: $0.id, keycode: 0, mods: 0, enabled: true) }
}

func saveBindings(_ bindings: [HotkeyBinding]) {
    let arr = bindings.filter { $0.keycode != 0 }
        .map { ["action": $0.action, "keycode": Int($0.keycode), "mods": Int($0.mods), "enabled": $0.enabled] as [String: Any] }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: CFG))
    }
    DispatchQueue.main.async { reregisterHotkeys() }   // live — no agent restart
}

// ---- custom actions ---------------------------------------------------------
// User-defined prompt templates. Text mode wraps selected text; shot mode captures
// a screenshot. Stored in ~/.claude/state/custom-actions.json.

let CUSTOM_ACTIONS_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent(".claude/state/custom-actions.json")

struct CustomAction: Identifiable {
    var id: String          // UUID string — stable key for hotkey registration
    var name: String
    var prompt: String      // template; {selection} = selected text; auto-appended if omitted
    var isShot: Bool        // true = screenshot mode
    var isAutoSubmit: Bool  // true = auto-press Return after pasting prompt
    var sessionMode: String // "new" = open new Claude session, "add" = paste into existing chat
    var includeSource: Bool // prepend "from: AppName — URL" context prefix
    var keycode: UInt32
    var mods: UInt32
    var enabled: Bool

    var actionID: String { isShot ? "customshot:\(id)" : "custom:\(id)" }
    var human: String { keycode == 0 ? "—" : humanShortcut(keycode: keycode, mods: mods) }

    static func makeNew(name: String, prompt: String, isShot: Bool) -> CustomAction {
        CustomAction(id: UUID().uuidString, name: name, prompt: prompt,
                     isShot: isShot, isAutoSubmit: false, sessionMode: "new",
                     includeSource: true, keycode: 0, mods: 0, enabled: true)
    }
}

func loadCustomActions() -> [CustomAction] {
    guard let data = FileManager.default.contents(atPath: CUSTOM_ACTIONS_PATH),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return arr.compactMap { d in
        guard let id = d["id"] as? String,
              let name = d["name"] as? String,
              let prompt = d["prompt"] as? String else { return nil }
        return CustomAction(
            id: id, name: name, prompt: prompt,
            isShot: d["isShot"] as? Bool ?? false,
            isAutoSubmit: d["isAutoSubmit"] as? Bool ?? false,
            sessionMode: d["sessionMode"] as? String ?? "new",
            includeSource: d["includeSource"] as? Bool ?? true,
            keycode: UInt32(d["keycode"] as? Int ?? 0),
            mods: UInt32(d["mods"] as? Int ?? 0),
            enabled: d["enabled"] as? Bool ?? true
        )
    }
}

func saveCustomActions(_ actions: [CustomAction]) {
    let arr = actions.map { ca -> [String: Any] in
        ["id": ca.id, "name": ca.name, "prompt": ca.prompt, "isShot": ca.isShot,
         "isAutoSubmit": ca.isAutoSubmit, "sessionMode": ca.sessionMode,
         "includeSource": ca.includeSource, "keycode": Int(ca.keycode),
         "mods": Int(ca.mods), "enabled": ca.enabled]
    }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: CUSTOM_ACTIONS_PATH))
    }
    DispatchQueue.main.async { reregisterHotkeys() }
}
