// DictationLab — standalone dictation menu-bar app.
//
// Menu-bar icon turns purple while recording.
// Global hotkeys: F10 = insert at cursor, ⌥F10 = send to Claude.
// Hold F10 = push-to-talk; double-tap F10 = lock mode.
// Uses Parakeet TDT via FluidAudio (local CoreML, ANE, no server round-trip).
//
// Build: ./dictation-lab/build.sh → dictation-lab/DictationLab.app

import Cocoa
import SwiftUI
import AVFoundation
import CoreAudio
import AudioToolbox
import Carbon.HIToolbox
import ApplicationServices
import FluidAudio
#if canImport(FoundationModels)
import FoundationModels
#endif

// ─── Mode ──────────────────────────────────────────────────────────────────────

enum DictMode { case insert, claude }

// ─── Keycode / modifier helpers ────────────────────────────────────────────────

private let FKEY_NAMES: [UInt32: String] = [
    122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",
    101:"F9",109:"F10",103:"F11",111:"F12",
    105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"
]
private let LETTER_NAMES: [UInt32: String] = [
    0:"A",11:"B",8:"C",2:"D",14:"E",3:"F",5:"G",4:"H",34:"I",38:"J",
    40:"K",37:"L",46:"M",45:"N",31:"O",35:"P",12:"Q",15:"R",1:"S",17:"T",
    32:"U",9:"V",13:"W",7:"X",16:"Y",6:"Z",18:"1",19:"2",20:"3",21:"4",
    23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",49:"Space"
]
private let SPECIAL_NAMES: [UInt32: String] = [
    36:"Return", 48:"Tab", 51:"⌫", 53:"Esc", 57:"Caps",
    71:"Num⌧", 76:"Num↩",
    115:"Home", 116:"PgUp", 117:"Del", 119:"End", 121:"PgDn",
    123:"←", 124:"→", 125:"↓", 126:"↑"
]

func keycodeLabel(_ kc: UInt32) -> String {
    FKEY_NAMES[kc] ?? SPECIAL_NAMES[kc] ?? LETTER_NAMES[kc] ?? "key(\(kc))"
}

func humanShortcut(keycode: UInt32, mods: UInt32) -> String {
    if keycode == 0 { return "—" }
    var s = ""
    if mods & 4096 != 0 { s += "⌃" }
    if mods & 2048 != 0 { s += "⌥" }
    if mods & 512  != 0 { s += "⇧" }
    if mods & 256  != 0 { s += "⌘" }
    return s + keycodeLabel(keycode)
}

// ─── Binding storage ───────────────────────────────────────────────────────────

final class HotkeyState: ObservableObject {
    @Published var insertKeycode: UInt32
    @Published var insertMods: UInt32
    @Published var claudeKeycode: UInt32
    @Published var claudeMods: UInt32

    static let shared = HotkeyState()

    private init() {
        let ud = UserDefaults.standard
        if !ud.bool(forKey: "hk_init") {
            ud.set(109,  forKey: "hk_insert_kc");  ud.set(0,    forKey: "hk_insert_mods")
            ud.set(109,  forKey: "hk_claude_kc");  ud.set(2048, forKey: "hk_claude_mods")
            ud.set(true, forKey: "hk_init")
        }
        insertKeycode = UInt32(ud.integer(forKey: "hk_insert_kc"))
        insertMods    = UInt32(ud.integer(forKey: "hk_insert_mods"))
        claudeKeycode = UInt32(ud.integer(forKey: "hk_claude_kc"))
        claudeMods    = UInt32(ud.integer(forKey: "hk_claude_mods"))
    }

    func save() {
        let ud = UserDefaults.standard
        ud.set(Int(insertKeycode), forKey: "hk_insert_kc")
        ud.set(Int(insertMods),   forKey: "hk_insert_mods")
        ud.set(Int(claudeKeycode), forKey: "hk_claude_kc")
        ud.set(Int(claudeMods),   forKey: "hk_claude_mods")
    }

    var insertHuman: String { humanShortcut(keycode: insertKeycode, mods: insertMods) }
    var claudeHuman: String { humanShortcut(keycode: claudeKeycode, mods: claudeMods) }
}

// ─── Debug log ────────────────────────────────────────────────────────────────

@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published var lines: [String] = []
    private let maxLines = 200

    func append(_ s: String) {
        let ts = {
            let c = Calendar.current; let n = Date()
            return String(format: "%02d:%02d:%02d", c.component(.hour, from: n),
                          c.component(.minute, from: n), c.component(.second, from: n))
        }()
        let line = "\(ts)  \(s)"
        NSLog("[dictlab] %@", s)
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// ─── Vocabulary store ──────────────────────────────────────────────────────────

@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    struct Replacement: Identifiable {
        let id = UUID()
        var wrong: String
        var correct: String
    }

    struct FillerEntry: Identifiable {
        let id: UUID
        var phrase: String
        var customPattern: String?   // nil → auto-generate from phrase
        var enabled: Bool

        init(phrase: String, customPattern: String? = nil, enabled: Bool = true, id: UUID = UUID()) {
            self.id = id; self.phrase = phrase; self.customPattern = customPattern; self.enabled = enabled
        }

        var regexPattern: String {
            if let p = customPattern { return p }
            let esc = NSRegularExpression.escapedPattern(for: phrase)
            // Single words: match repetition (um → um, umm, ummm). Multi-word: exact boundary.
            return phrase.contains(" ") ? "\\b\(esc)\\b" : "\\b\(esc)+\\b"
        }

        static let defaults: [FillerEntry] = [
            FillerEntry(phrase: "um"),
            FillerEntry(phrase: "uh"),
            FillerEntry(phrase: "ah"),
            FillerEntry(phrase: "er"),
            FillerEntry(phrase: "hmm"),
            FillerEntry(phrase: "you know"),
            FillerEntry(phrase: "you see"),
            FillerEntry(phrase: "like (pause)", customPattern: ",\\s*like\\s*,"),
        ]
    }

    @Published var replacements: [Replacement] = []
    @Published var vocab: [String] = []
    @Published var fillers: [FillerEntry] = FillerEntry.defaults

    private init() { load() }

    private var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("DictationLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.json")
    }

    private struct VocabFile: Codable {
        struct Entry: Codable { var wrong, correct: String }
        struct FillerFile: Codable { var phrase: String; var customPattern: String?; var enabled: Bool }
        var replacements: [Entry] = []
        var vocab: [String] = []
        var fillers: [FillerFile]?   // optional for backward compat with old JSON
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let f = try? JSONDecoder().decode(VocabFile.self, from: data) else { return }
        replacements = f.replacements.map { Replacement(wrong: $0.wrong, correct: $0.correct) }
        vocab = f.vocab
        if let ff = f.fillers {
            fillers = ff.map { FillerEntry(phrase: $0.phrase, customPattern: $0.customPattern, enabled: $0.enabled) }
        }
    }

    private func persist() {
        let f = VocabFile(
            replacements: replacements.map { .init(wrong: $0.wrong, correct: $0.correct) },
            vocab: vocab,
            fillers: fillers.map { .init(phrase: $0.phrase, customPattern: $0.customPattern, enabled: $0.enabled) }
        )
        try? JSONEncoder().encode(f).write(to: fileURL, options: .atomic)
    }

    func addReplacement(wrong: String, correct: String) {
        let w = wrong.trimmingCharacters(in: .whitespaces)
        let c = correct.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !c.isEmpty else { return }
        replacements.removeAll { $0.wrong.lowercased() == w.lowercased() }
        replacements.append(Replacement(wrong: w, correct: c))
        persist()
    }

    func removeReplacement(id: UUID) {
        replacements.removeAll { $0.id == id }
        persist()
    }

    func addVocab(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !vocab.contains(where: { $0.lowercased() == t.lowercased() }) else { return }
        vocab.append(t)
        persist()
    }

    func removeVocab(at offsets: IndexSet) {
        vocab.remove(atOffsets: offsets)
        persist()
    }

    func toggleFiller(id: UUID) {
        guard let i = fillers.firstIndex(where: { $0.id == id }) else { return }
        fillers[i].enabled.toggle()
        persist()
    }

    func addFiller(phrase: String) {
        let p = phrase.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !fillers.contains(where: { $0.phrase.lowercased() == p.lowercased() }) else { return }
        fillers.append(FillerEntry(phrase: p))
        persist()
    }

    func removeFiller(id: UUID) {
        fillers.removeAll { $0.id == id }
        persist()
    }
}

// ─── Processing settings ───────────────────────────────────────────────────────

@MainActor
final class ProcessingSettings: ObservableObject {
    static let shared = ProcessingSettings()

    @Published var fillerRemoval: Bool  { didSet { UserDefaults.standard.set(fillerRemoval,  forKey: "proc_filler") } }
    @Published var smartFormatting: Bool { didSet { UserDefaults.standard.set(smartFormatting, forKey: "proc_format") } }
    @Published var aiCleanup: Bool       { didSet { UserDefaults.standard.set(aiCleanup,       forKey: "proc_ai") } }

    private init() {
        let ud = UserDefaults.standard
        fillerRemoval   = ud.object(forKey: "proc_filler") as? Bool ?? true
        smartFormatting = ud.object(forKey: "proc_format") as? Bool ?? true
        // Migration v3: AI on by default
        if ud.object(forKey: "proc_ai_v3") == nil {
            ud.set(true, forKey: "proc_ai"); ud.set(true, forKey: "proc_ai_v3")
        }
        aiCleanup = ud.object(forKey: "proc_ai") as? Bool ?? true
    }
}

// ─── Transcription history ────────────────────────────────────────────────────

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    struct Record: Identifiable, Codable {
        var id = UUID()
        var timestamp: Date
        var raw: String
        var processed: String
        var mode: String   // "insert" | "claude"
    }

    @Published var records: [Record] = []
    private static let maxRecords = 100

    private init() { load() }

    func add(raw: String, processed: String, mode: DictMode) {
        let r = Record(timestamp: Date(), raw: raw, processed: processed,
                       mode: mode == .insert ? "insert" : "claude")
        records.insert(r, at: 0)
        if records.count > Self.maxRecords { records = Array(records.prefix(Self.maxRecords)) }
        save()
    }

    func remove(id: UUID) { records.removeAll { $0.id == id }; save() }
    func clearAll()        { records.removeAll(); save() }

    // Find word substitutions that appear consistently across sessions.
    // Returns (wrong, correct, count) sorted by count desc, min count 2.
    func suggestions(ignoring existing: Set<String>) -> [(wrong: String, correct: String, count: Int)] {
        var tally: [String: Int] = [:]
        let sep = CharacterSet.whitespaces.union(.punctuationCharacters)
        for r in records where r.raw != r.processed {
            let rawWords  = r.raw.components(separatedBy: sep).filter { !$0.isEmpty }
            let procWords = r.processed.components(separatedBy: sep).filter { !$0.isEmpty }
            guard rawWords.count == procWords.count else { continue }
            for (rw, pw) in zip(rawWords, procWords) where rw.lowercased() != pw.lowercased() {
                let key = "\(rw.lowercased())→\(pw)"
                tally[key, default: 0] += 1
            }
        }
        return tally
            .filter { $0.value >= 2 }
            .compactMap { key, count -> (wrong: String, correct: String, count: Int)? in
                let parts = key.components(separatedBy: "→")
                guard parts.count == 2 else { return nil }
                let w = parts[0], c = parts[1]
                guard !existing.contains(w) else { return nil }
                return (wrong: w, correct: c, count: count)
            }
            .sorted { $0.count > $1.count }
    }

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("DictationLab")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }
    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else { return }
        records = decoded
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storeURL)
    }
}

// ─── Transcript processor ──────────────────────────────────────────────────────

enum TranscriptProcessor {

    // Spoken punctuation → symbol (longer/more-specific phrases first)
    private static let punctCommands: [(pat: String, repl: String)] = [
        // Structural
        ("(\\w)\\s+new paragraph\\b",                                              "$1\n\n"),
        ("(\\w)\\s+(?:new line|next line|line break|skip a line)\\b",              "$1\n"),
        ("\\bnew paragraph\\b",                                                     "\n\n"),
        ("\\b(?:new line|next line|line break|skip a line)\\b",                    "\n"),
        // End-of-dictation Enter
        ("\\s*\\bpress enter\\b\\.?\\s*$",                                         "\n"),
        // Sentence punctuation
        ("(\\w)\\s+(?:exclamation point|exclamation mark)\\b",                     "$1!"),
        ("(\\w)\\s+question mark\\b",                                               "$1?"),
        ("(\\w)\\s+semicolon\\b",                                                   "$1;"),
        ("(\\w)\\s+colon\\b",                                                       "$1:"),
        ("(\\w)\\s+(?:period|full stop|dot)\\b",                                   "$1."),
        ("(\\w)\\s+comma\\b",                                                       "$1,"),
        // Dashes
        ("(\\w)\\s+(?:em dash|em-dash|emdash)\\b",                                "$1\u{2014}"),
        ("(\\w)\\s+(?:en dash|en-dash|endash)\\b",                                "$1\u{2013}"),
        // Quotes + parens
        ("(\\w)\\s+(?:apostrophe|single quote)\\b",                                "$1\u{2019}"),
        ("(\\w)\\s+(?:quotation mark|open quote|open quotation|quote that)\\b",    "$1 \u{201C}"),
        ("\\b(?:close quote|end quote|unquote|close quotation)\\s*(\\w)",          "\u{201D} $1"),
        ("(\\w)\\s+(?:open (?:paren|parenthesis)|left paren|left bracket)\\b",     "$1 ("),
        ("\\b(?:close (?:paren|parenthesis)|right paren|right bracket)\\s*(\\w)", ") $1"),
        // Special symbols
        ("(\\w)\\s+(?:ellipsis|dot dot dot)\\b",                                   "$1\u{2026}"),
        ("(\\w)\\s+(?:ampersand|and sign)\\b",                                     "$1 &"),
        ("(\\w)\\s+(?:asterisk|star)\\b",                                           "$1*"),
        ("(\\w)\\s+(?:percent sign|per cent|percentage symbol)\\b",                "$1%"),
        ("(\\w)\\s+(?:slash|forward slash|divided by|per)\\b",                     "$1/"),
        ("(\\w)\\s+backslash\\b",                                                   "$1\\\\"),
        ("(\\w)\\s+underscore\\b",                                                  "$1_"),
        ("(\\w)\\s+(?:hashtag|hash)\\b",                                           "$1#"),
        ("(\\w)\\s+tilde\\b",                                                       "$1~"),
        ("(\\w)\\s+(?:at sign|at symbol)\\b",                                      "$1@"),
        ("(\\w)\\s+(?:plus sign|plus)\\b",                                          "$1+"),
        ("(\\w)\\s+(?:minus sign|minus|negative)\\b",                              "$1-"),
        ("(\\w)\\s+(?:equals sign|equals)\\b",                                     "$1="),
        ("(\\w)\\s+(?:angle bracket|greater than sign|greater-than)\\b",           "$1>"),
        ("(\\w)\\s+(?:less than sign|less-than)\\b",                               "$1<"),
        ("(\\w)\\s+(?:trademark|tm)\\b",                                            "$1\u{2122}"),
        ("(\\w)\\s+(?:registered trademark|registered)\\b",                        "$1\u{00AE}"),
        ("(\\w)\\s+(?:copyright symbol|copyright)\\b",                             "$1\u{00A9}"),
        ("(\\w)\\s+(?:degree sign|degree symbol)\\b",                              "$1\u{00B0}"),
    ]

    // Backtrack: remove the preceding phrase when user says "scratch that" etc.
    // "Let's meet at 7pm scratch that let's meet at 8pm" → "Let's meet at 8pm"
    private static func applyBacktrack(_ text: String) -> (String, Bool) {
        let triggers = "scratch that|forget that|never mind|no wait|no wait actually|i mean|disregard that|cancel that|start over"
        guard let re = try? NSRegularExpression(
            pattern: "([^.!?\\n]*)\\s*\\b(?:\(triggers))\\b\\.?\\s*",
            options: .caseInsensitive
        ) else { return (text, false) }
        let new = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let changed = new != text
        return (new.trimmingCharacters(in: .whitespaces), changed)
    }

    // Capitalize the first letter after sentence-ending punctuation
    private static func capitalizeAfterPunctuation(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "([.!?]\\s+)([a-z])") else { return text }
        let ns = NSMutableString(string: text)
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let r = match.range(at: 2)
            ns.replaceCharacters(in: r, with: (text as NSString).substring(with: r).uppercased())
        }
        return ns as String
    }

    // Sequences for list detection — checked in order (ordinal first, more specific)
    private static let listSeqs: [[String]] = [
        ["first","second","third","fourth","fifth","sixth","seventh","eighth","ninth","tenth"],
        ["one","two","three","four","five","six","seven","eight","nine","ten"],
    ]

    @MainActor
    static func process(
        _ raw: String,
        vocab: VocabularyStore,
        settings: ProcessingSettings,
        log: (String) -> Void
    ) async -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return raw }
        var text = raw
        log("input: \"\(text.prefix(60))\"")

        // 1. Vocabulary replacements (exact, case-insensitive word boundary)
        for r in vocab.replacements {
            let escaped = NSRegularExpression.escapedPattern(for: r.wrong)
            guard let re = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive) else { continue }
            let new = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: r.correct)
            if new != text { log("vocab: \"\(r.wrong)\"→\"\(r.correct)\""); text = new }
        }

        // 2. Filler removal — uses user-configured list from VocabularyStore
        if settings.fillerRemoval {
            for filler in vocab.fillers where filler.enabled {
                guard let re = try? NSRegularExpression(pattern: filler.regexPattern, options: .caseInsensitive) else { continue }
                let new = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                if new != text { log("filler: \"\(filler.phrase)\" stripped"); text = new }
            }
            if let re = try? NSRegularExpression(pattern: "  +") {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
            // Collapse repeated commas left when filler between two commas is removed
            // e.g. "vocabulary, um, history" → filler removes "um" → "vocabulary, , history" → "vocabulary, history"
            if let re = try? NSRegularExpression(pattern: ",\\s*,+") {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ",")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Smart formatting: backtrack, punctuation commands, list detection, auto-capitalize
        if settings.smartFormatting {
            // Backtrack — "scratch that / forget that / never mind" removes preceding phrase
            let (backtracted, didBacktrack) = applyBacktrack(text)
            if didBacktrack { log("backtrack applied"); text = backtracted }

            // Spoken symbols / punctuation
            for (pat, repl) in punctCommands {
                guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else { continue }
                let new = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: repl)
                if new != text { log("punct applied"); text = new }
            }
            let listed = detectList(text)
            if listed != text { log("list formatted"); text = listed }
            // Auto-capitalize after .!? and at start
            text = capitalizeAfterPunctuation(text)
            if let s = text.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(s) {
                text = text.prefix(1).uppercased() + text.dropFirst()
            }
        }

        // 4. Apple Intelligence on-device cleanup
        if settings.aiCleanup {
            let hint = (vocab.vocab + vocab.replacements.map(\.correct)).joined(separator: ", ")
            text = await aiCleanup(text, vocabHint: hint, log: log) ?? text
        }

        log("output: \"\(text.prefix(80))\"")
        return text
    }

    // MARK: - List detection

    private static func detectList(_ text: String) -> String {
        let ns = text as NSString
        for seq in listSeqs {
            var positions: [(loc: Int, len: Int)] = []
            var searchFrom = 0
            for word in seq {
                guard let re = try? NSRegularExpression(pattern: "\\b\(word)\\b", options: .caseInsensitive),
                      let m = re.firstMatch(in: text, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                else { break }
                positions.append((m.range.location, m.range.length))
                searchFrom = m.range.location + m.range.length
            }
            guard positions.count >= 2 else { continue }

            let preamble = positions[0].loc > 0
                ? ns.substring(to: positions[0].loc).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            var items: [String] = []
            for i in 0..<positions.count {
                let start = positions[i].loc + positions[i].len
                let end   = i + 1 < positions.count ? positions[i + 1].loc : ns.length
                guard start < end else { continue }
                let item = ns.substring(with: NSRange(location: start, length: end - start))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
                if !item.isEmpty { items.append(item) }
            }
            guard items.count >= 2 else { continue }

            var result = ""
            if !preamble.isEmpty {
                var p = preamble.trimmingCharacters(in: CharacterSet(charactersIn: ",:; "))
                if !p.hasSuffix(":") { p += ":" }
                result = p + "\n"
            }
            for (i, item) in items.enumerated() {
                var s = item.trimmingCharacters(in: CharacterSet(charactersIn: ".,;: "))
                if let c = s.unicodeScalars.first { s = String(c).uppercased() + String(s.dropFirst()) }
                result += "\(i + 1). \(s)\n"
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Apple Intelligence

    @MainActor
    private static func aiCleanup(_ text: String, vocabHint: String, log: (String) -> Void) async -> String? {
        guard #available(macOS 26.0, *) else { log("AI: macOS 26 required"); return nil }
        #if canImport(FoundationModels)
        do {
            let hint = vocabHint.isEmpty ? "" : " Prefer these terms: \(vocabHint)."
            let instructions = """
                You clean up speech-to-text transcripts. Rules:
                1. Fix grammar, punctuation, and capitalization.
                2. Remove filler words (um, uh, "like" as a pause, "you know").
                3. Handle self-corrections: "X actually Y" means replace X with Y \
                (e.g. "coffee at 2 actually 3" → "coffee at 3"; \
                "I mean", "I meant", "let me rephrase" work the same way).
                4. Preserve "actually" as an adverb when context is not a correction \
                (e.g. "I actually enjoyed it" stays intact).
                5. Do not add or invent content — only clean what was said.\(hint)
                Return only the cleaned text with no explanation.
                """
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: text)
            log("AI: done (\(response.content.count)ch)")
            return response.content
        } catch {
            log("AI: \(error.localizedDescription)")
            return nil
        }
        #else
        log("AI: FoundationModels not compiled in")
        return nil
        #endif
    }
}

// ─── Recorder ─────────────────────────────────────────────────────────────────

@MainActor
final class Recorder: ObservableObject {
    enum State: String { case idle, loading, starting, listening, error }
    enum ModelStatus { case notDownloaded, downloading(Double), ready, error(String) }

    @Published var state: State = .idle
    @Published var liveTranscript = ""
    @Published var modelStatus: ModelStatus = .notDownloaded
    @Published var audioLevel: Float = 0

    var onFinal: ((String, DictMode) -> Void)?
    private(set) var currentMode: DictMode = .insert
    var prevBundle = ""

    // Models kept loaded; fresh SlidingWindowAsrManager created per session
    // because inputBuilder.finish() permanently closes the stream.
    private var loadedModels: AsrModels?
    private var currentMgr: SlidingWindowAsrManager?
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: DispatchSourceTimer?
    private var lastTranscript = ""
    private var sessionID = 0
    private var streamTask: Task<Void, Never>?

    private func log(_ s: String) { DebugLog.shared.append(s) }

    func initModels() async {
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
        if AsrModels.modelsExist(at: cacheDir) {
            log("models cached — loading")
            await loadFromCache(cacheDir: cacheDir)
        } else {
            log("models not cached — open Settings to download")
            modelStatus = .notDownloaded
        }
    }

    func downloadModels() async {
        guard case .notDownloaded = modelStatus else { return }
        log("downloading models…")
        modelStatus = .downloading(0)
        do {
            let models = try await AsrModels.downloadAndLoad(progressHandler: { [weak self] progress in
                Task { @MainActor in
                    self?.modelStatus = .downloading(progress.fractionCompleted)
                    if Int(progress.fractionCompleted * 100) % 10 == 0 {
                        DebugLog.shared.append("download \(Int(progress.fractionCompleted * 100))%")
                    }
                }
            })
            loadedModels = models
            modelStatus = .ready
            log("models downloaded and ready")
        } catch {
            log("download failed: \(error)")
            modelStatus = .error(error.localizedDescription)
        }
    }

    func removeModels() {
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
        do {
            try FileManager.default.removeItem(at: cacheDir)
            log("model cache removed")
        } catch {
            log("remove failed: \(error.localizedDescription)")
        }
        loadedModels = nil
        currentMgr = nil
        modelStatus = .notDownloaded
    }

    private func loadFromCache(cacheDir: URL) async {
        state = .loading
        do {
            let models = try await AsrModels.downloadAndLoad(to: cacheDir)
            loadedModels = models
            modelStatus = .ready
            state = .idle
            log("models loaded from cache — ready")
        } catch {
            log("cache load failed: \(error)")
            modelStatus = .error(error.localizedDescription)
            state = .idle
        }
    }

    func toggle(mode: DictMode) {
        if state == .listening || state == .starting { stop() }
        else if state == .idle { start(mode: mode) }
    }

    func start(mode: DictMode) {
        guard state == .idle || state == .error else { return }
        guard loadedModels != nil else {
            fail("models not loaded")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Model not downloaded"
                alert.informativeText = "Open Settings and click Download to get the Parakeet model (~650 MB), then try again."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NotificationCenter.default.post(name: .init("OpenSettings"), object: nil)
                }
            }
            return
        }
        sessionID += 1
        let mySession = sessionID
        currentMode = mode
        lastTranscript = ""; liveTranscript = ""
        state = .starting
        log("▶ session \(mySession) start mode=\(mode)")

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            beginStreaming(session: mySession)
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self = self else { return }
                    if granted { self.beginStreaming(session: mySession) }
                    else { self.fail("microphone access denied") }
                }
            }
        }
    }

    private func beginStreaming(session: Int) {
        guard let models = loadedModels else { fail("loadedModels nil"); return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        log("audio format: \(hwFormat.sampleRate)Hz ch=\(hwFormat.channelCount)")

        streamTask = Task {
            let mgr = SlidingWindowAsrManager(config: .default)
            do { try await mgr.loadModels(models) }
            catch { self.fail("mgr.loadModels: \(error)"); return }
            self.currentMgr = mgr

            var bufCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buf, _ in
                bufCount += 1
                if bufCount == 1 || bufCount % 50 == 0 {
                    Task { @MainActor in self?.log("audio buf #\(bufCount)") }
                }
                // Compute RMS audio level for waveform animation
                if let channelData = buf.floatChannelData?[0] {
                    let frameCount = Int(buf.frameLength)
                    var sum: Float = 0
                    for i in 0..<frameCount { let s = channelData[i]; sum += s * s }
                    let rms = frameCount > 0 ? sqrt(sum / Float(frameCount)) : 0
                    Task { @MainActor in self?.audioLevel = min(rms * 20, 1.0) }
                }
                Task { await mgr.streamAudio(buf) }
            }

            do {
                try await mgr.startStreaming(source: .microphone)
                self.log("startStreaming ok")

                do { try engine.start(); self.log("engine started") }
                catch {
                    self.fail("engine.start: \(error.localizedDescription)")
                    inputNode.removeTap(onBus: 0)
                    return
                }
                self.audioEngine = engine

                guard self.sessionID == session, !Task.isCancelled else {
                    engine.stop(); inputNode.removeTap(onBus: 0); self.audioEngine = nil
                    return
                }
                self.state = .listening
                self.log("🎙 listening")
                self.resetSilenceTimer()

                for await update in await mgr.transcriptionUpdates {
                    guard self.sessionID == session, !Task.isCancelled else { break }
                    self.liveTranscript = update.text
                    self.lastTranscript = update.text
                    self.log("partial: \"\(update.text)\"")
                }
                self.log("transcriptionUpdates stream ended")
            } catch {
                guard self.sessionID == session else { return }
                self.fail("streaming error: \(error.localizedDescription)")
            }
            engine.stop()
            inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
            self.log("engine stopped, buf total=\(bufCount)")
        }
    }

    func stop() {
        guard state == .listening || state == .starting else { return }
        let mode = currentMode
        let wasListening = state == .listening
        let mgr = currentMgr
        currentMgr = nil
        log("■ stop wasListening=\(wasListening)")
        cancelSilenceTimer()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        streamTask?.cancel(); streamTask = nil
        state = .idle
        guard wasListening else { return }

        Task {
            do {
                self.log("calling finish()…")
                let text = try await mgr?.finish() ?? ""
                self.log("finish() → \"\(text)\" (\(text.count) chars)")
                if !text.isEmpty {
                    self.onFinal?(text, mode)
                } else if !self.lastTranscript.isEmpty {
                    self.log("using lastTranscript fallback")
                    self.onFinal?(self.lastTranscript, mode)
                } else {
                    self.log("⚠ finish empty, lastTranscript empty — nothing to dispatch")
                    DispatchQueue.main.async { NSSound.beep() }
                }
            } catch {
                self.log("finish() threw: \(error)")
                if !self.lastTranscript.isEmpty { self.onFinal?(self.lastTranscript, mode) }
            }
        }
    }

    func cancel() {
        log("cancel")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        streamTask?.cancel(); streamTask = nil
        cancelSilenceTimer()
        lastTranscript = ""; liveTranscript = ""
        state = .idle
        let mgr = currentMgr; currentMgr = nil
        Task { try? await mgr?.finish() }
    }

    private func resetSilenceTimer() {
        cancelSilenceTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 120)
        t.setEventHandler { [weak self] in
            guard let self = self, self.state == .listening else { return }
            self.log("120s timeout — stopping")
            self.stop()
        }
        t.resume()
        silenceTimer = t
    }

    private func cancelSilenceTimer() { silenceTimer?.cancel(); silenceTimer = nil }

    private func fail(_ msg: String) {
        log("ERROR: \(msg)")
        streamTask?.cancel(); streamTask = nil
        state = .error
    }
}

// ─── Purple dot overlay ────────────────────────────────────────────────────────

private final class DotState: ObservableObject {
    @Published var shown = false
}

private struct DotView: View {
    @ObservedObject var s: DotState

    var body: some View {
        Capsule()
            .fill(LinearGradient(
                colors: [Color(red: 0.74, green: 0.26, blue: 1.0),
                         Color(red: 0.50, green: 0.16, blue: 0.90)],
                startPoint: .leading, endPoint: .trailing))
            .frame(width: 44, height: 5)
            .shadow(color: Color.purple.opacity(0.9), radius: 7, x: 0, y: 1)
            .scaleEffect(x: s.shown ? 1.0 : 0.05, y: s.shown ? 1.0 : 0.15)
            .opacity(s.shown ? 1.0 : 0)
            .animation(.spring(response: 0.27, dampingFraction: 0.55), value: s.shown)
            .frame(width: 76, height: 20)
    }
}

final class OverlayController {
    private var panel: NSPanel?
    private var escMonitor: Any?
    private let dot = DotState()
    private var hideToken = 0

    func show(rec: Recorder) {
        hideToken += 1
        if panel == nil { build() }
        position()
        panel?.orderFront(nil)
        installEscMonitor(rec: rec)
        dot.shown = true
    }

    func hide() {
        removeEscMonitor()
        dot.shown = false
        let tok = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.hideToken == tok else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func build() {
        let w: CGFloat = 76, h: CGFloat = 20
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = false; p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.ignoresMouseEvents = true
        let host = NSHostingView(rootView: DotView(s: dot))
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        p.contentView = host
        panel = p
    }

    private func position() {
        guard let p = panel, let screen = NSScreen.main else { return }
        p.setFrameOrigin(NSPoint(x: screen.frame.midX - 38,
                                 y: screen.frame.maxY - 40))
    }

    private func installEscMonitor(rec: Recorder) {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { DispatchQueue.main.async { rec.cancel(); self?.hide() } }
        }
    }

    private func removeEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }
}

// ─── Settings window ───────────────────────────────────────────────────────────

private enum SettingsTab: String, CaseIterable {
    case general = "General", processing = "Processing"
    case vocabulary = "Vocabulary", history = "History", debug = "Debug"
    var icon: String {
        switch self {
        case .general:    return "gear"
        case .processing: return "wand.and.sparkles"
        case .vocabulary: return "book.closed"
        case .history:    return "clock"
        case .debug:      return "terminal"
        }
    }
}

private struct SettingsContent: View {
    @ObservedObject var hk: HotkeyState
    @ObservedObject var rec: Recorder
    @ObservedObject var dbg: DebugLog = DebugLog.shared
    @ObservedObject var vocab: VocabularyStore = .shared
    @ObservedObject var proc: ProcessingSettings = .shared
    @ObservedObject var history: HistoryStore = .shared
    @State private var tab: SettingsTab = .general
    @State var recording: String? = nil
    @State var newWrong = ""
    @State var newCorrect = ""
    @State var newVocabTerm = ""
    @State var newFiller = ""
    @State var showRemoveConfirm = false
    @State var showClearHistoryConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { t in tabButton(t) }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .general:    generalTab
                    case .processing: processingTab
                    case .vocabulary: vocabularyTab
                    case .history:    historyTab
                    case .debug:      debugTab
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Text("Dictation Lab \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") • Parakeet TDT • Apple Intelligence")
                    .font(.caption2).foregroundColor(.secondary.opacity(0.6))
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .frame(minWidth: 520, idealWidth: 580, maxWidth: .infinity,
               minHeight: 400, idealHeight: 660, maxHeight: .infinity)
        .onAppear { recording = nil }
        .background(KeyCaptureView(recording: $recording, hk: hk))
    }

    @ViewBuilder
    private func tabButton(_ t: SettingsTab) -> some View {
        Button { tab = t } label: {
            Label(t.rawValue, systemImage: t.icon)
                .font(.system(size: 11, weight: tab == t ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(tab == t ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .foregroundColor(tab == t ? .accentColor : .secondary)
    }

    @ViewBuilder
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("Model").bold()) {
                HStack(spacing: 12) {
                    modelStatusIcon
                    modelStatusText
                    Spacer()
                    modelActionButton
                }
                .padding(.vertical, 8)
            }

            GroupBox(label: Text("Hotkeys").bold()) {
                VStack(spacing: 0) {
                    hotkeyRow(label: "Dictate (insert at cursor)",
                              detail: "Transcribes speech and types it at your cursor.",
                              human: hk.insertHuman, key: "insert")
                    Divider()
                    hotkeyRow(label: "Dictate → Claude",
                              detail: "Pastes transcribed text into the active Claude session.",
                              human: hk.claudeHuman, key: "claude")
                    if hk.insertKeycode != 0 && hk.claudeKeycode != 0
                        && hk.insertKeycode == hk.claudeKeycode
                        && hk.insertMods == hk.claudeMods {
                        Divider()
                        Label("Both hotkeys are identical — one won't fire", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange).font(.caption).padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Text("Permissions").bold()) {
                VStack(spacing: 8) {
                    permRow("Microphone",
                            ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                            action: { AVCaptureDevice.requestAccess(for: .audio) { _ in } })
                    permRow("Accessibility (needed for paste-at-cursor)",
                            ok: AXIsProcessTrusted(),
                            action: {
                                let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                                _ = AXIsProcessTrustedWithOptions(o)
                            })
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var processingTab: some View {
        GroupBox(label: Text("Processing").bold()) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Remove filler words", isOn: $proc.fillerRemoval)

                if proc.fillerRemoval {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Active fillers").font(.caption).bold().foregroundColor(.secondary)
                            Spacer()
                            Text("\(vocab.fillers.filter(\.enabled).count) of \(vocab.fillers.count) enabled")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(vocab.fillers) { filler in
                                    HStack(spacing: 6) {
                                        Button { vocab.toggleFiller(id: filler.id) } label: {
                                            Image(systemName: filler.enabled
                                                  ? "checkmark.square.fill" : "square")
                                                .foregroundColor(filler.enabled ? .accentColor : .secondary)
                                        }.buttonStyle(.plain)
                                        Text(filler.phrase)
                                            .font(.system(size: 11))
                                            .foregroundColor(filler.enabled ? .primary : .secondary)
                                        Spacer()
                                        Button { vocab.removeFiller(id: filler.id) } label: {
                                            Image(systemName: "minus.circle")
                                                .foregroundColor(.red).opacity(0.7)
                                        }.buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(height: 90)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(4)
                        HStack {
                            TextField("Add filler word or phrase", text: $newFiller)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                vocab.addFiller(phrase: newFiller); newFiller = ""
                            }
                            .disabled(newFiller.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.leading, 20)
                }

                Divider()

                Toggle("Smart formatting (spoken punctuation + auto-capitalize)", isOn: $proc.smartFormatting)
                if proc.smartFormatting {
                    Text("Punctuation: \"period\", \"comma\", \"question mark\", \"em dash\", \"colon\", \"semicolon\", \"open paren\", \"close paren\", \"open quote\", \"close quote\", \"ampersand\", \"asterisk\", \"percent sign\", \"slash\", \"hashtag\", \"at sign\", \"underscore\", \"ellipsis\", \"plus\", \"minus\", \"equals\", \"trademark\", \"copyright\", \"degree sign\".\nLayout: \"new line\", \"new paragraph\", \"skip a line\", \"press enter\" (at end).\nLists: \"first … second …\" or \"one … two …\".\nBacktrack: \"scratch that\", \"forget that\", \"never mind\", \"no wait\" removes preceding phrase.\nAuto-capitalize after . ! ?")
                        .font(.caption).foregroundColor(.secondary).padding(.leading, 20)
                }
                if #available(macOS 26.0, *) {
                    Toggle("AI cleanup (Apple Intelligence, on-device)", isOn: $proc.aiCleanup)
                    if proc.aiCleanup {
                        Text("Runs Apple Intelligence on this Mac after all rules. Fixes grammar, punctuation, capitalization, and residual fillers. No data leaves your device. Model: Apple on-device LLM (macOS 26+).")
                            .font(.caption).foregroundColor(.secondary).padding(.leading, 20)
                    }
                } else {
                    Toggle("AI cleanup (requires macOS 26)", isOn: .constant(false))
                        .disabled(true)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var vocabularyTab: some View {
        GroupBox(label: Text("Vocabulary").bold()) {
            VStack(alignment: .leading, spacing: 10) {

                HStack {
                    Text("Corrections").font(.caption).bold().foregroundColor(.secondary)
                    Spacer()
                    Text("\(vocab.replacements.count) entries").font(.caption).foregroundColor(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(vocab.replacements) { r in
                            HStack(spacing: 6) {
                                Text(r.wrong).foregroundColor(.secondary).lineLimit(1)
                                Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                                Text(r.correct).bold().lineLimit(1)
                                Spacer()
                                Button {
                                    vocab.removeReplacement(id: r.id)
                                } label: {
                                    Image(systemName: "minus.circle").foregroundColor(.red)
                                }.buttonStyle(.plain)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                        }
                    }
                }
                .frame(height: 72)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)

                HStack(spacing: 6) {
                    TextField("Wrong spelling", text: $newWrong).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    TextField("Correct form", text: $newCorrect).textFieldStyle(.roundedBorder)
                    Button("Add") {
                        vocab.addReplacement(wrong: newWrong, correct: newCorrect)
                        newWrong = ""; newCorrect = ""
                    }
                    .disabled(newWrong.trimmingCharacters(in: .whitespaces).isEmpty ||
                              newCorrect.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Divider()

                HStack {
                    Text("Vocabulary terms").font(.caption).bold().foregroundColor(.secondary)
                    Text("(boost recognition + fed to AI)").font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vocab.vocab.enumerated()), id: \.offset) { i, term in
                            HStack {
                                Text(term)
                                Spacer()
                                Button {
                                    vocab.removeVocab(at: IndexSet(integer: i))
                                } label: {
                                    Image(systemName: "minus.circle").foregroundColor(.red)
                                }.buttonStyle(.plain)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                        }
                    }
                }
                .frame(height: 56)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)

                HStack {
                    TextField("Add terms, comma-separated (GSO, DXP, Contentstack)", text: $newVocabTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let terms = newVocabTerm.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            terms.forEach { vocab.addVocab($0) }
                            newVocabTerm = ""
                        }
                    Button("Add") {
                        let terms = newVocabTerm.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        terms.forEach { vocab.addVocab($0) }
                        newVocabTerm = ""
                    }
                    .disabled(newVocabTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(history.records.count) transcriptions").font(.caption).foregroundColor(.secondary)
                Spacer()
                if !history.records.isEmpty {
                    Button("Clear All") { showClearHistoryConfirm = true }
                        .buttonStyle(.bordered).controlSize(.small).foregroundColor(.red)
                        .alert("Clear history?", isPresented: $showClearHistoryConfirm) {
                            Button("Clear All", role: .destructive) { history.clearAll() }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("Removes all \(history.records.count) saved transcriptions.")
                        }
                }
            }

            // Correction suggestions from recurring raw→processed patterns
            let existingWrong = Set(vocab.replacements.map { $0.wrong.lowercased() })
            let suggestions = history.suggestions(ignoring: existingWrong)
            if !suggestions.isEmpty {
                GroupBox(label: HStack {
                    Image(systemName: "lightbulb.fill").foregroundColor(.yellow)
                    Text("Suggested corrections").bold()
                    Spacer()
                    Text("\(suggestions.count) pattern\(suggestions.count == 1 ? "" : "s")").font(.caption).foregroundColor(.secondary)
                }) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(suggestions.prefix(5), id: \.wrong) { s in
                            HStack(spacing: 8) {
                                Text(s.wrong).foregroundColor(.secondary).font(.system(size: 11))
                                Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                                Text(s.correct).bold().font(.system(size: 11))
                                Text("×\(s.count)").font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                Button("Add") {
                                    vocab.addReplacement(wrong: s.wrong, correct: s.correct)
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if history.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.largeTitle).foregroundColor(.secondary.opacity(0.4))
                    Text("No transcriptions yet").foregroundColor(.secondary)
                    Text("Dictated text appears here so you can review, copy, or add corrections.")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(history.records) { record in
                        HistoryRow(record: record,
                                   onDelete: { history.remove(id: record.id) })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var debugTab: some View {
        GroupBox(label: HStack {
            Text("Debug Log").bold()
            Spacer()
            Button("Clear") { DebugLog.shared.lines.removeAll() }.controlSize(.small)
            Button("Copy All") { DebugLog.shared.copyAll() }.controlSize(.small)
        }) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(dbg.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.85))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 130)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
                .onChange(of: dbg.lines.count) {
                    if let last = dbg.lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelStatusIcon: some View {
        switch rec.modelStatus {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).frame(width: 18)
        case .downloading:
            ProgressView().controlSize(.small).frame(width: 18)
        case .notDownloaded, .error:
            Image(systemName: "arrow.down.circle").foregroundColor(.secondary).frame(width: 18)
        }
    }

    @ViewBuilder
    private var modelStatusText: some View {
        switch rec.modelStatus {
        case .ready:
            VStack(alignment: .leading, spacing: 2) {
                Text("Parakeet TDT v3 ready")
                Text("Local model — no internet needed").font(.caption).foregroundColor(.secondary)
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloading… \(Int(p * 100))%")
                Text("~650 MB, one-time download").font(.caption).foregroundColor(.secondary)
            }
        case .notDownloaded:
            VStack(alignment: .leading, spacing: 2) {
                Text("Model not downloaded")
                Text("~650 MB, cached in Application Support").font(.caption).foregroundColor(.secondary)
            }
        case .error(let msg):
            VStack(alignment: .leading, spacing: 2) {
                Text("Download failed").foregroundColor(.red)
                Text(msg).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var modelActionButton: some View {
        switch rec.modelStatus {
        case .notDownloaded, .error:
            Button("Download") { Task { await rec.downloadModels() } }
        case .downloading:
            EmptyView()
        case .ready:
            Button("Remove") { showRemoveConfirm = true }
                .foregroundColor(.red)
                .alert("Remove model cache?", isPresented: $showRemoveConfirm) {
                    Button("Remove", role: .destructive) { rec.removeModels() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Deletes ~650 MB. You'll need to re-download before dictating again.")
                }
        }
    }

    @ViewBuilder
    private func hotkeyRow(label: String, detail: String, human: String, key: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Group {
                if recording == key {
                    Text("Press keys…").foregroundColor(.accentColor).italic()
                } else {
                    Text(human).font(.system(.body, design: .rounded)).bold()
                }
            }.frame(width: 100, alignment: .trailing)
            Button(recording == key ? "…" : "Set") {
                if recording == key { recording = nil; reregisterHotkeys() }
                else { unregisterHotkeys(); recording = key }
            }
            .frame(width: 48)
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Clear") {
                if key == "insert" { hk.insertKeycode = 0; hk.insertMods = 0 }
                else               { hk.claudeKeycode = 0; hk.claudeMods = 0 }
                hk.save(); reregisterHotkeys()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(key == "insert" ? hk.insertKeycode == 0 : hk.claudeKeycode == 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func permRow(_ title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red).frame(width: 18)
            Text(title)
            Spacer()
            if !ok { Button("Enable") { action() }.controlSize(.small) }
        }
    }
}

private struct HistoryRow: View {
    let record: HistoryStore.Record
    let onDelete: () -> Void

    @State private var expanded = false
    @State private var showCorrectionForm = false
    @State private var corrWrong = ""
    @State private var corrRight = ""

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10)).foregroundColor(.secondary).frame(width: 12)
                    Text(String(record.processed.prefix(80)))
                        .lineLimit(1).font(.system(size: 12))
                    Spacer()
                    Text(Self.df.string(from: record.timestamp))
                        .font(.caption2).foregroundColor(.secondary)
                    Image(systemName: record.mode == "claude" ? "brain" : "keyboard")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if record.raw != record.processed {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Raw ASR").font(.caption2).foregroundColor(.secondary)
                            Text(record.raw).font(.system(size: 11)).foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("After processing").font(.caption2).foregroundColor(.secondary)
                            Text(record.processed).font(.system(size: 11)).textSelection(.enabled)
                        }
                    } else {
                        Text(record.processed).font(.system(size: 11)).textSelection(.enabled)
                    }

                    if showCorrectionForm {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Add correction — select a word from above, paste it in the fields below:")
                                .font(.caption2).foregroundColor(.secondary)
                            HStack(spacing: 6) {
                                TextField("Misheard word", text: $corrWrong)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                                Image(systemName: "arrow.right").foregroundColor(.secondary).font(.caption)
                                TextField("Correct form", text: $corrRight)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                                Button("Save") {
                                    let w = corrWrong.trimmingCharacters(in: .whitespaces)
                                    let r = corrRight.trimmingCharacters(in: .whitespaces)
                                    guard !w.isEmpty, !r.isEmpty else { return }
                                    VocabularyStore.shared.addReplacement(wrong: w, correct: r)
                                    corrWrong = ""; corrRight = ""
                                    showCorrectionForm = false
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(corrWrong.trimmingCharacters(in: .whitespaces).isEmpty ||
                                          corrRight.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel") { showCorrectionForm = false; corrWrong = ""; corrRight = "" }
                                    .buttonStyle(.plain).controlSize(.small).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.accentColor.opacity(0.06))
                        .cornerRadius(6)
                    }

                    HStack(spacing: 8) {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.processed, forType: .string)
                        }
                        .buttonStyle(.bordered).controlSize(.small)

                        Button(showCorrectionForm ? "Hide Correction" : "Add Correction") {
                            showCorrectionForm.toggle()
                        }
                        .buttonStyle(.bordered).controlSize(.small)

                        Spacer()

                        Button("Delete") { onDelete() }
                            .foregroundColor(.red).buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    @Binding var recording: String?
    var hk: HotkeyState

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onKey = { keycode, mods in
            guard let action = recording else { return }
            if action == "insert" { hk.insertKeycode = keycode; hk.insertMods = mods }
            else                  { hk.claudeKeycode = keycode; hk.claudeMods = mods }
            hk.save()
            recording = nil
            reregisterHotkeys()
        }
        return v
    }

    func updateNSView(_ v: KeyView, context: Context) { v.isActive = recording != nil }

    class KeyView: NSView {
        var onKey: ((UInt32, UInt32) -> Void)?
        var isActive = false

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard isActive, event.keyCode != 53 else {
                if event.keyCode == 53 { onKey = nil }
                super.keyDown(with: event)
                return
            }
            let kc = UInt32(event.keyCode)
            let mods: UInt32 = {
                var m: UInt32 = 0
                let f = event.modifierFlags
                if f.contains(.command) { m |= 256 }
                if f.contains(.shift)   { m |= 512 }
                if f.contains(.option)  { m |= 2048 }
                if f.contains(.control) { m |= 4096 }
                return m
            }()
            onKey?(kc, mods)
        }
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var rec: Recorder?

    func show(rec: Recorder) {
        self.rec = rec
        if window == nil { build(rec: rec) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build(rec: Recorder) {
        let host = NSHostingController(rootView: SettingsContent(hk: HotkeyState.shared, rec: rec))
        let w = NSWindow(contentViewController: host)
        w.title = "Dictation Lab"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 540, height: 860))
        w.minSize = NSSize(width: 500, height: 500)
        w.center()
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

let settingsController = SettingsWindowController()

// ─── Icons ─────────────────────────────────────────────────────────────────────

private func brandIcon() -> NSImage {
    let h = NSStatusBar.system.thickness
    let img = NSImage(size: NSSize(width: h, height: h), flipped: false) { full in
        let inset = full.width * 0.18
        let rect = full.insetBy(dx: inset, dy: inset)
        let radius = rect.width * 0.22
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.isTemplate = true
    return img
}

private func dockIcon() -> NSImage {
    let size: CGFloat = 256
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { full in
        let inset = size * 0.08
        let rect = full.insetBy(dx: inset, dy: inset)
        let radius = rect.width * 0.22
        NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    return img
}

// ─── Carbon global hotkeys ─────────────────────────────────────────────────────

private var hkActions: [UInt32: DictMode] = [:]
private var hkRefs: [EventHotKeyRef?] = []

private let hkHandler: EventHandlerUPP = { _, event, _ -> OSStatus in
    var hkID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    NSLog("[dictlab] hotkey fired id=%d", hkID.id)
    if let mode = hkActions[hkID.id] {
        DispatchQueue.main.async { appController.triggerDictation(mode: mode) }
    } else {
        NSLog("[dictlab] hotkey id=%d not in hkActions (keys=%@)", hkID.id, hkActions.keys.map{$0} as NSArray)
    }
    return noErr
}

func registerHotkeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), hkHandler, 1, &spec, nil, nil)
    reregisterHotkeys()
}

func reregisterHotkeys() {
    unregisterHotkeys()
    let hk = HotkeyState.shared
    let sig = OSType(0x44494354)
    let pairs: [(UInt32, UInt32, DictMode)] = [
        (hk.insertKeycode, hk.insertMods, .insert),
        (hk.claudeKeycode, hk.claudeMods, .claude)
    ]
    for (i, (kc, mods, mode)) in pairs.enumerated() {
        guard kc != 0 else { continue }
        let id = EventHotKeyID(signature: sig, id: UInt32(i + 1))
        hkActions[UInt32(i + 1)] = mode
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(kc, mods, id, GetApplicationEventTarget(), 0, &ref)
        NSLog("[dictlab] registerHotkey kc=%d mods=%d id=%d err=%d", kc, mods, i+1, err)
        hkRefs.append(ref)
    }
}

func unregisterHotkeys() {
    for ref in hkRefs { if let r = ref { UnregisterEventHotKey(r) } }
    hkRefs.removeAll(); hkActions.removeAll()
}

// ─── App controller ────────────────────────────────────────────────────────────

@MainActor
final class AppController: NSObject {
    private let rec = Recorder()
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem!

    private enum TrigMode { case idle, pushToTalk, lock }
    private var trigMode: TrigMode = .idle
    private var ptTimer: Timer?
    private var autoStopTimer: Timer?
    private var levelTimer: Timer?
    private var escMonitor: Any?
    private var lastPressTime: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.35
    private var wavePhase: [Double] = (0..<5).map { Double($0) * 0.7 }

    private static let recoveryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("DictationLab")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("recording_recovery.txt")
    }()

    // ── Sound feedback ─────────────────────────────────────────────────────────
    private func playSound(_ name: String, volume: Float = 0.35) {
        if let s = NSSound(named: NSSound.Name(name)) {
            s.volume = volume; s.play()
        }
    }
    private func playStartSound()  { playSound("Tink", volume: 0.4) }
    private func playStopSound()   { playSound("Pop",  volume: 0.3) }

    // ── Menu bar waveform ──────────────────────────────────────────────────────
    private func waveformImage(level: Float) -> NSImage {
        let sz = NSSize(width: 16, height: 11)
        let img = NSImage(size: sz)
        img.lockFocus()
        // Hardcoded sRGB — systemPurple is adaptive and can resolve wrong outside a view context
        NSColor(srgbRed: 0.686, green: 0.322, blue: 0.871, alpha: 1.0).setFill()
        let barW: CGFloat = 2, gap: CGFloat = 1.5, maxH: CGFloat = 10, minH: CGFloat = 2
        let totalW = CGFloat(5) * barW + CGFloat(4) * gap
        let startX = (sz.width - totalW) / 2
        for i in 0..<5 {
            let ph = wavePhase[i]
            let barLevel = max(Float(minH / maxH), level * Float(0.45 + 0.55 * sin(ph)))
            let h = max(minH, CGFloat(barLevel) * maxH)
            let x = startX + CGFloat(i) * (barW + gap)
            let y = (sz.height - h) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: h),
                         xRadius: 1, yRadius: 1).fill()
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    override init() {
        super.init()
        setupStatusItem()
        setupRecorder()
        NotificationCenter.default.addObserver(forName: .init("OpenSettings"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
        Task { await rec.initModels() }
        checkCrashRecovery()
    }

    private func checkCrashRecovery() {
        guard FileManager.default.fileExists(atPath: Self.recoveryURL.path),
              let saved = try? String(contentsOf: Self.recoveryURL, encoding: .utf8),
              !saved.isEmpty else { return }
        try? FileManager.default.removeItem(at: Self.recoveryURL)
        let alert = NSAlert()
        alert.messageText = "Recording interrupted"
        alert.informativeText = "Dictation Lab was quit or crashed mid-session. Recovered text:\n\n\(saved.prefix(300))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(saved, forType: .string)
        }
    }

    private func setupStatusItem() {
        NSApp.applicationIconImage = dockIcon()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let btn = statusItem.button else { return }
        btn.image = brandIcon()
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        let hk = HotkeyState.shared
        addItem(m, "Dictate (insert)", action: #selector(triggerInsert),
                key: hk.insertKeycode, mods: hk.insertMods)
        addItem(m, "Dictate → Claude", action: #selector(triggerClaude),
                key: hk.claudeKeycode, mods: hk.claudeMods)
        m.addItem(.separator())
        addItem(m, "Settings…", action: #selector(openSettings))
        addItem(m, "Quit", action: #selector(quit), shortcutKey: "q")
        return m
    }

    private func buildRecordingMenu() -> NSMenu {
        let m = NSMenu()
        let stop = m.addItem(withTitle: "■  Stop Recording", action: #selector(stopFromMenu), keyEquivalent: "")
        stop.target = self
        let cancel = m.addItem(withTitle: "Cancel (discard)", action: #selector(cancelFromMenu), keyEquivalent: "")
        cancel.target = self
        m.addItem(.separator())
        addItem(m, "Quit", action: #selector(quit), shortcutKey: "q")
        return m
    }

    @objc private func stopFromMenu() {
        cancelTimers()
        try? FileManager.default.removeItem(at: Self.recoveryURL)
        rec.stop(); overlay.hide(); setRecording(false); trigMode = .idle
    }
    @objc private func cancelFromMenu() {
        cancelTimers()
        try? FileManager.default.removeItem(at: Self.recoveryURL)
        rec.cancel(); overlay.hide(); setRecording(false); trigMode = .idle
    }

    private func cancelTimers() {
        autoStopTimer?.invalidate(); autoStopTimer = nil
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, action: Selector,
                         key: UInt32 = 0, mods: UInt32 = 0, shortcutKey: String = "") -> NSMenuItem {
        let it = menu.addItem(withTitle: title, action: action, keyEquivalent: shortcutKey)
        it.target = self
        if key != 0 {
            let fkeys: [UInt32: UInt32] = [
                101: 0xF70C, 100: 0xF70B, 98: 0xF70A, 97: 0xF709, 96: 0xF708,
                109: 0xF70D, 103: 0xF70E, 111: 0xF70F, 122: 0xF704, 120: 0xF705
            ]
            if let scalar = fkeys[key], let u = Unicode.Scalar(scalar) {
                it.keyEquivalent = String(u)
                var f: NSEvent.ModifierFlags = []
                if mods & 256 != 0  { f.insert(.command) }
                if mods & 512 != 0  { f.insert(.shift) }
                if mods & 2048 != 0 { f.insert(.option) }
                if mods & 4096 != 0 { f.insert(.control) }
                it.keyEquivalentModifierMask = f
            }
        }
        return it
    }

    private func setRecording(_ on: Bool) {
        statusItem.menu = on ? buildRecordingMenu() : buildMenu()
        if on {
            statusItem.button?.contentTintColor = nil  // clear any residual tint before waveform takes over
            levelTimer?.invalidate()
            levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0/20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    let t = Date().timeIntervalSinceReferenceDate
                    for i in 0..<5 { self.wavePhase[i] = t * (5.0 + Double(i) * 1.3) }
                    self.statusItem.button?.image = self.waveformImage(level: self.rec.audioLevel)
                    self.statusItem.button?.image?.isTemplate = false
                }
            }
        } else {
            levelTimer?.invalidate(); levelTimer = nil
            statusItem.button?.image = brandIcon()
            statusItem.button?.contentTintColor = nil
        }
    }

    private func setupRecorder() {
        rec.onFinal = { [weak self] text, mode in
            guard let self = self else { return }
            if self.rec.state == .idle || self.rec.state == .error {
                self.cancelTimers()
                try? FileManager.default.removeItem(at: Self.recoveryURL)
                self.overlay.hide()
                self.setRecording(false)
                self.trigMode = .idle
            }
            self.dispatch(text: text, mode: mode)
        }
    }

    private func ensurePermissions() -> Bool {
        let hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let hasAX  = AXIsProcessTrusted()
        guard !hasMic || !hasAX else { return true }

        var missing: [String] = []
        if !hasMic { missing.append("Microphone — needed to capture speech") }
        if !hasAX  { missing.append("Accessibility — needed to paste transcribed text") }

        let alert = NSAlert()
        alert.messageText = "Permissions needed"
        alert.informativeText = "Dictation Lab needs:\n\n• " + missing.joined(separator: "\n• ")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        if !hasMic { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        if !hasAX {
            let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(o)
            // Bring System Settings → Accessibility pane to the front
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }

    func triggerDictation(mode: DictMode) {
        guard rec.state != .loading else { return }

        switch trigMode {
        case .lock:
            cancelTimers()
            try? FileManager.default.removeItem(at: Self.recoveryURL)
            rec.stop(); overlay.hide(); setRecording(false); trigMode = .idle

        case .pushToTalk:
            ptTimer?.invalidate(); ptTimer = nil; trigMode = .lock

        case .idle:
            let now = Date().timeIntervalSinceReferenceDate
            let isDouble = (now - lastPressTime) < doubleTapWindow
            lastPressTime = now

            guard ensurePermissions() else { return }

            if isDouble {
                if rec.state == .idle || rec.state == .error { beginRecording(mode: mode) }
                trigMode = .lock
            } else {
                beginRecording(mode: mode)
                trigMode = .pushToTalk
                let trigKc: CGKeyCode = mode == .insert
                    ? CGKeyCode(HotkeyState.shared.insertKeycode)
                    : CGKeyCode(HotkeyState.shared.claudeKeycode)
                startPushToTalkPolling(keycode: trigKc)
            }
        }
    }

    private func beginRecording(mode: DictMode) {
        rec.prevBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        rec.start(mode: mode)
        // overlay.show(rec: rec)  // hidden — indicator moved to menu bar waveform
        setRecording(true)
        playStartSound()

        // ESC cancels recording without switching apps
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { DispatchQueue.main.async {
                self?.cancelTimers()
                try? FileManager.default.removeItem(at: Self.recoveryURL)
                self?.rec.cancel(); self?.overlay.hide()
                self?.setRecording(false); self?.trigMode = .idle
            }}
        }

        // Auto-stop at 10 minutes; save + paste whatever was captured
        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.cancelTimers()
                try? FileManager.default.removeItem(at: Self.recoveryURL)
                self.rec.stop(); self.overlay.hide(); self.setRecording(false); self.trigMode = .idle
            }
        }

        // Crash recovery: write live transcript every 30 s
        Task { @MainActor in
            while self.rec.state == .starting { try? await Task.sleep(nanoseconds: 50_000_000) }
            if self.rec.state != .listening {
                self.ptTimer?.invalidate(); self.ptTimer = nil
                self.cancelTimers()
                self.overlay.hide(); self.setRecording(false); self.trigMode = .idle
            } else {
                // Periodic save for crash recovery
                while self.rec.state == .listening {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    let live = self.rec.liveTranscript
                    if !live.isEmpty { try? live.write(to: Self.recoveryURL, atomically: true, encoding: .utf8) }
                }
            }
        }
    }

    private func startPushToTalkPolling(keycode kc: CGKeyCode) {
        ptTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self = self, self.trigMode == .pushToTalk else { t.invalidate(); return }
                if !CGEventSource.keyState(.combinedSessionState, key: kc) {
                    t.invalidate()
                    self.ptTimer = nil
                    self.trigMode = .idle
                    self.cancelTimers()
                    try? FileManager.default.removeItem(at: Self.recoveryURL)
                    self.rec.stop()
                    self.overlay.hide()
                    self.setRecording(false)
                }
            }
        }
    }

    @objc func triggerInsert() { triggerDictation(mode: .insert) }
    @objc func triggerClaude() { triggerDictation(mode: .claude) }
    @objc func openSettings()  { settingsController.show(rec: rec) }
    @objc func quit()          { NSApp.terminate(nil) }

    // Run raw transcript through processor, record to history, then paste.
    private func dispatch(text: String, mode: DictMode) {
        Task { @MainActor in
            let processed = await TranscriptProcessor.process(
                text,
                vocab: VocabularyStore.shared,
                settings: ProcessingSettings.shared,
                log: { msg in DebugLog.shared.append("proc: \(msg)") }
            )
            HistoryStore.shared.add(raw: text, processed: processed, mode: mode)
            self.paste(processed, mode: mode)
        }
    }

    private func paste(_ text: String, mode: DictMode) {
        playStopSound()
        switch mode {
        case .insert:
            let pb = NSPasteboard.general
            let savedClipboard = pb.string(forType: .string)
            pb.clearContents(); pb.setString(text, forType: .string)

            let ax = AXIsProcessTrusted()
            let bundle = rec.prevBundle
            let targetApp = bundle.isEmpty ? nil :
                NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            let pid = targetApp?.processIdentifier ?? -1
            NSLog("[dispatch] ax=%@ bundle=%@ pid=%d textLen=%d", "\(ax)", bundle, pid, text.count)

            guard ax else {
                let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(o)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            if pid > 0 {
                postCmdV(toPid: pid_t(pid))
            } else {
                postCmdV(toPid: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pb.clearContents()
                if let saved = savedClipboard { pb.setString(saved, forType: .string) }
            }

        case .claude:
            let claudeBundle = "com.anthropic.claudefordesktop"
            let claudeApp = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundle).first
            let pb = NSPasteboard.general
            let savedClipboard = pb.string(forType: .string)
            pb.clearContents(); pb.setString(text, forType: .string)
            NSLog("[dispatch/claude] textLen=%d claudeRunning=%@", text.count, claudeApp != nil ? "yes" : "no")
            guard AXIsProcessTrusted() else {
                let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(o)
                pb.clearContents()
                if let saved = savedClipboard { pb.setString(saved, forType: .string) }
                return
            }
            if let app = claudeApp {
                app.activate(options: .activateIgnoringOtherApps)
                Task {
                    for _ in 0..<25 {
                        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundle { break }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    self.postCmdV(toPid: nil)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    pb.clearContents()
                    if let saved = savedClipboard { pb.setString(saved, forType: .string) }
                }
            } else {
                let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
                if let url = URL(string: "claude://code/new?q=\(encoded)") { NSWorkspace.shared.open(url) }
                pb.clearContents()
                if let saved = savedClipboard { pb.setString(saved, forType: .string) }
            }
        }
    }

    private func postCmdV(toPid: pid_t?) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let d = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let u = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else { return }
        d.flags = .maskCommand; u.flags = .maskCommand
        if let pid = toPid { d.postToPid(pid); u.postToPid(pid) }
        else                { d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap) }
    }
}

// ─── Entry ─────────────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appController = MainActor.assumeIsolated { AppController() }
registerHotkeys()
app.run()
