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
    CommandAction(id: "go",          name: "Go",                 detail: "New Claude session, auto-submit, then return focus to where you were."),
    CommandAction(id: "comment",     name: "Comment",            detail: "New session pre-filled; stays foreground so you add a note and send."),
    CommandAction(id: "todo",        name: "To-Do",              detail: "Native popup → your tracker intake. No Claude chat."),
    CommandAction(id: "shotadd",     name: "Screenshot Add",     detail: "Capture → paste image into the already-open Claude chat."),
    CommandAction(id: "shotgo",      name: "Screenshot Go",      detail: "Capture (drag area / press Space for a window) → new session, auto-submit."),
    CommandAction(id: "shotcomment", name: "Screenshot Comment", detail: "Capture → new session; you add a note."),
    CommandAction(id: "cliphistory", name: "Clipboard History",  detail: "Floating picker of recent clips."),
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

// One binding per catalog action, in catalog order; unbound actions get keycode 0.
func loadBindings() -> [HotkeyBinding] {
    var byAction: [String: HotkeyBinding] = [:]
    if let data = FileManager.default.contents(atPath: CFG),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        for d in arr {
            if let a = d["action"] as? String, let k = d["keycode"] as? Int, let m = d["mods"] as? Int {
                let en = d["enabled"] as? Bool ?? true
                byAction[a] = HotkeyBinding(action: a, keycode: UInt32(k), mods: UInt32(m), enabled: en)
            }
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
