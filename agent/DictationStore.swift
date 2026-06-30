// DictationStore.swift — shared dictation state: debug log, vocabulary,
// processing settings, transcription history. Persisted in
// ~/Library/Application Support/DictationLab/ (same path as DictationLab.app
// so both apps share the same vocab/history file).

import Cocoa
import Foundation

// ─── Debug log ────────────────────────────────────────────────────────────────

@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published var lines: [String] = []
    private let maxLines = 200

    func append(_ s: String) {
        let c = Calendar.current; let n = Date()
        let ts = String(format: "%02d:%02d:%02d",
                        c.component(.hour, from: n),
                        c.component(.minute, from: n),
                        c.component(.second, from: n))
        lines.append("\(ts)  \(s)")
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
        var customPattern: String?
        var enabled: Bool

        init(phrase: String, customPattern: String? = nil, enabled: Bool = true, id: UUID = UUID()) {
            self.id = id; self.phrase = phrase
            self.customPattern = customPattern; self.enabled = enabled
        }

        var regexPattern: String {
            if let p = customPattern { return p }
            let esc = NSRegularExpression.escapedPattern(for: phrase)
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
        var fillers: [FillerFile]?
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

    func removeReplacement(id: UUID) { replacements.removeAll { $0.id == id }; persist() }

    func addVocab(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !vocab.contains(where: { $0.lowercased() == t.lowercased() }) else { return }
        vocab.append(t); persist()
    }

    func removeVocab(at offsets: IndexSet) { vocab.remove(atOffsets: offsets); persist() }

    func toggleFiller(id: UUID) {
        guard let i = fillers.firstIndex(where: { $0.id == id }) else { return }
        fillers[i].enabled.toggle(); persist()
    }

    func addFiller(phrase: String) {
        let p = phrase.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !fillers.contains(where: { $0.phrase.lowercased() == p.lowercased() }) else { return }
        fillers.append(FillerEntry(phrase: p)); persist()
    }

    func removeFiller(id: UUID) { fillers.removeAll { $0.id == id }; persist() }
}

// ─── Processing settings ───────────────────────────────────────────────────────

@MainActor
final class ProcessingSettings: ObservableObject {
    static let shared = ProcessingSettings()

    @Published var fillerRemoval: Bool   { didSet { UserDefaults.standard.set(fillerRemoval,   forKey: "proc_filler") } }
    @Published var smartFormatting: Bool { didSet { UserDefaults.standard.set(smartFormatting, forKey: "proc_format") } }
    @Published var aiCleanup: Bool       { didSet { UserDefaults.standard.set(aiCleanup,       forKey: "proc_ai") } }

    private init() {
        let ud = UserDefaults.standard
        fillerRemoval   = ud.object(forKey: "proc_filler") as? Bool ?? true
        smartFormatting = ud.object(forKey: "proc_format") as? Bool ?? true
        if ud.object(forKey: "proc_ai_v3") == nil {
            ud.set(true, forKey: "proc_ai"); ud.set(true, forKey: "proc_ai_v3")
        }
        aiCleanup = ud.object(forKey: "proc_ai") as? Bool ?? true
    }
}

// ─── Transcription history ─────────────────────────────────────────────────────

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

    func suggestions(ignoring existing: Set<String>) -> [(wrong: String, correct: String, count: Int)] {
        var tally: [String: Int] = [:]
        let sep = CharacterSet.whitespaces.union(.punctuationCharacters)
        for r in records where r.raw != r.processed {
            let rawWords  = r.raw.components(separatedBy: sep).filter { !$0.isEmpty }
            let procWords = r.processed.components(separatedBy: sep).filter { !$0.isEmpty }
            guard rawWords.count == procWords.count else { continue }
            for (rw, pw) in zip(rawWords, procWords) where rw.lowercased() != pw.lowercased() {
                tally["\(rw.lowercased())→\(pw)", default: 0] += 1
            }
        }
        return tally.filter { $0.value >= 2 }
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
