// Actions.swift — file I/O + hotkey-registration glue for the action catalog,
// hotkey bindings, and custom actions defined in ClaudeCommandCore/ActionModels.swift.
// Pure model logic lives there (and is unit-tested there); this file is the
// side-effecting half: read/write ~/.claude/state/*.json, kick reregisterHotkeys().

import Foundation
import ClaudeCommandCore
#if canImport(AppKit)
import AppKit
#endif

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

let CUSTOM_ACTIONS_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent(".claude/state/custom-actions.json")

func loadCustomActions() -> [CustomAction] {
    guard let data = FileManager.default.contents(atPath: CUSTOM_ACTIONS_PATH),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return arr.compactMap { d in
        guard let id = d["id"] as? String,
              let name = d["name"] as? String,
              let prompt = d["prompt"] as? String else { return nil }
        // "kind" is the current schema; "isShot" is a one-time read fallback
        // for custom-actions.json files written before the kind enum existed.
        let kind: ActionKind
        if let raw = d["kind"] as? String, let k = ActionKind(rawValue: raw) {
            kind = k
        } else {
            kind = (d["isShot"] as? Bool ?? false) ? .screenshot : .text
        }
        return CustomAction(
            id: id, name: name, prompt: prompt,
            kind: kind,
            isAutoSubmit: d["isAutoSubmit"] as? Bool ?? false,
            sessionMode: d["sessionMode"] as? String ?? "new",
            includeSource: d["includeSource"] as? Bool ?? true,
            keycode: UInt32(d["keycode"] as? Int ?? 0),
            mods: UInt32(d["mods"] as? Int ?? 0),
            enabled: d["enabled"] as? Bool ?? true,
            isHandoff: d["isHandoff"] as? Bool ?? false,
            skill: d["skill"] as? String ?? ""
        )
    }
}

func saveCustomActions(_ actions: [CustomAction]) {
    let arr = actions.map { ca -> [String: Any] in
        ["id": ca.id, "name": ca.name, "prompt": ca.prompt, "kind": ca.kind.rawValue,
         "isAutoSubmit": ca.isAutoSubmit, "sessionMode": ca.sessionMode,
         "includeSource": ca.includeSource, "keycode": Int(ca.keycode),
         "mods": Int(ca.mods), "enabled": ca.enabled,
         "isHandoff": ca.isHandoff, "skill": ca.skill]
    }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: CUSTOM_ACTIONS_PATH))
    }
    DispatchQueue.main.async { reregisterHotkeys() }
}
