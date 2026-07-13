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

private func decodeTrigger(_ d: [String: Any]) -> ActionTrigger? {
    guard let id = d["id"] as? String,
          let rawKind = d["kind"] as? String, let kind = ActionKind(rawValue: rawKind) else { return nil }
    let delivery = (d["deliveryOverride"] as? String).flatMap(ActionDelivery.init(rawValue:))
    let destination = (d["destinationOverride"] as? String).flatMap(ClaudeDestination.init(rawValue:))
    let provider = (d["providerOverride"] as? String).flatMap(AIProviderChoice.init(rawValue:))
    return ActionTrigger(
        id: id, kind: kind,
        keycode: UInt32(d["keycode"] as? Int ?? 0), mods: UInt32(d["mods"] as? Int ?? 0),
        enabled: d["enabled"] as? Bool ?? true,
        isAutoSubmitOverride: d["isAutoSubmitOverride"] as? Bool,
        sessionModeOverride: d["sessionModeOverride"] as? String,
        includeSourceOverride: d["includeSourceOverride"] as? Bool,
        deliveryOverride: delivery,
        destinationOverride: destination,
        providerOverride: provider
    )
}

func loadCustomActions() -> [CustomAction] {
    guard let data = FileManager.default.contents(atPath: CUSTOM_ACTIONS_PATH),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return arr.compactMap { d in
        guard let id = d["id"] as? String,
              let name = d["name"] as? String,
              let prompt = d["prompt"] as? String else { return nil }

        // "triggers" is the current schema. Two older shapes read as a
        // one-time migration, both collapsing to a single trigger: "kind"
        // (flat kind/keycode/mods, no multi-trigger support yet) and, before
        // that, "isShot" (a plain screenshot/text bool, from before the kind
        // enum existed at all).
        let triggers: [ActionTrigger]
        if let rawTriggers = d["triggers"] as? [[String: Any]], !rawTriggers.isEmpty {
            triggers = rawTriggers.compactMap(decodeTrigger)
        } else {
            let kind: ActionKind
            if let raw = d["kind"] as? String, let k = ActionKind(rawValue: raw) {
                kind = k
            } else {
                kind = (d["isShot"] as? Bool ?? false) ? .screenshot : .text
            }
            triggers = [ActionTrigger(kind: kind,
                                       keycode: UInt32(d["keycode"] as? Int ?? 0),
                                       mods: UInt32(d["mods"] as? Int ?? 0),
                                       enabled: d["enabled"] as? Bool ?? true)]
        }
        guard !triggers.isEmpty else { return nil }

        return CustomAction(
            id: id, name: name, prompt: prompt,
            isAutoSubmit: d["isAutoSubmit"] as? Bool ?? false,
            sessionMode: d["sessionMode"] as? String ?? "new",
            includeSource: d["includeSource"] as? Bool ?? true,
            enabled: d["enabled"] as? Bool ?? true,
            isHandoff: d["isHandoff"] as? Bool ?? false,
            skill: d["skill"] as? String ?? "",
            delivery: (d["delivery"] as? String).flatMap(ActionDelivery.init(rawValue:)),
            destination: (d["destination"] as? String).flatMap(ClaudeDestination.init(rawValue:)) ?? .default,
            provider: (d["provider"] as? String).flatMap(AIProviderChoice.init(rawValue:)) ?? .default,
            triggers: triggers
        )
    }
}

private func encodeTrigger(_ t: ActionTrigger) -> [String: Any] {
    var d: [String: Any] = ["id": t.id, "kind": t.kind.rawValue,
                             "keycode": Int(t.keycode), "mods": Int(t.mods), "enabled": t.enabled]
    if let v = t.isAutoSubmitOverride { d["isAutoSubmitOverride"] = v }
    if let v = t.sessionModeOverride { d["sessionModeOverride"] = v }
    if let v = t.includeSourceOverride { d["includeSourceOverride"] = v }
    if let v = t.deliveryOverride { d["deliveryOverride"] = v.rawValue }
    if let v = t.destinationOverride { d["destinationOverride"] = v.rawValue }
    if let v = t.providerOverride { d["providerOverride"] = v.rawValue }
    return d
}

func saveCustomActions(_ actions: [CustomAction]) {
    let arr = actions.map { ca -> [String: Any] in
        ["id": ca.id, "name": ca.name, "prompt": ca.prompt,
         "isAutoSubmit": ca.isAutoSubmit, "sessionMode": ca.sessionMode,
         "includeSource": ca.includeSource, "enabled": ca.enabled,
         "isHandoff": ca.isHandoff, "skill": ca.skill,
         "delivery": ca.delivery.rawValue, "destination": ca.destination.rawValue,
         "provider": ca.provider.rawValue,
         "triggers": ca.triggers.map(encodeTrigger)]
    }
    if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: CUSTOM_ACTIONS_PATH))
    }
    DispatchQueue.main.async { reregisterHotkeys() }
}
