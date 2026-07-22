// KeyCodes.swift — Carbon keycode/modifier maps + formatting, shared by the
// hotkey system, the Shortcuts editor, and (mirrored in) set-hotkeys.sh.
// Pure (no I/O, no app state) — moved out of the executable target so it's
// covered by ClaudeCommandCoreTests.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

// Carbon modifier masks: command 256, shift 512, option 2048, control 4096.
public let CARBON_MODS: [(symbol: String, mask: UInt32)] = [
    ("⌃", 4096),   // control
    ("⌥", 2048),   // option
    ("⇧", 512),    // shift
    ("⌘", 256),    // command
]

// Carbon virtual keycode → display label.
public let KEYCODE_NAMES: [UInt32: String] = [
    0:"A",11:"B",8:"C",2:"D",14:"E",3:"F",5:"G",4:"H",34:"I",38:"J",40:"K",
    37:"L",46:"M",45:"N",31:"O",35:"P",12:"Q",15:"R",1:"S",17:"T",32:"U",
    9:"V",13:"W",7:"X",16:"Y",6:"Z",18:"1",19:"2",20:"3",21:"4",23:"5",
    22:"6",26:"7",28:"8",25:"9",29:"0",49:"Space",
    63:"Fn",55:"Command",54:"Right Command",58:"Option",61:"Right Option",
    59:"Control",62:"Right Control",56:"Shift",60:"Right Shift",
    122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",
    101:"F9",109:"F10",103:"F11",111:"F12",
    115:"Home",119:"End",116:"PgUp",121:"PgDn",117:"⌦",
]

public let MODIFIER_ONLY_KEYCODES: Set<UInt32> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
public let MEDIA_KEYCODES: Set<UInt32> = [96, 97, 98, 99, 100, 101]

public func eventTapOwnsVoiceHotkey(keycode: UInt32) -> Bool {
    MODIFIER_ONLY_KEYCODES.contains(keycode) || MEDIA_KEYCODES.contains(keycode)
}

public func fnNavigationKeycode(sourceKeycode: UInt16, functionPressed: Bool) -> UInt32? {
    guard functionPressed else { return nil }
    switch sourceKeycode {
    case 123: return 115 // Fn+Left = Home
    case 124: return 119 // Fn+Right = End
    case 126: return 116 // Fn+Up = PgUp
    case 125: return 121 // Fn+Down = PgDn
    default: return nil
    }
}

public func humanShortcut(keycode: UInt32, mods: UInt32) -> String {
    var s = ""
    for mod in CARBON_MODS where (mods & mod.mask) != 0 { s += mod.symbol }
    s += KEYCODE_NAMES[keycode] ?? "?"
    return s
}

#if canImport(AppKit)
// Convert Cocoa modifier flags (from a recorded NSEvent) into Carbon masks.
public func carbonMods(from f: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if f.contains(.command) { m |= 256 }
    if f.contains(.shift)   { m |= 512 }
    if f.contains(.option)  { m |= 2048 }
    if f.contains(.control) { m |= 4096 }
    return m
}
#endif
