// Processor.swift — text processing pipeline for raw ASR transcripts.
// Stages: vocabulary replacements → filler removal → smart formatting
// (backtrack / punctuation commands / list detection / auto-capitalize)
// → Apple Intelligence on-device cleanup.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum TranscriptProcessor {

    private static let punctCommands: [(pat: String, repl: String)] = [
        ("(\\w)\\s+new paragraph\\b",                                              "$1\n\n"),
        ("(\\w)\\s+(?:new line|next line|line break|skip a line)\\b",              "$1\n"),
        ("\\bnew paragraph\\b",                                                     "\n\n"),
        ("\\b(?:new line|next line|line break|skip a line)\\b",                    "\n"),
        ("\\s*\\bpress enter\\b\\.?\\s*$",                                         "\n"),
        ("(\\w)\\s+(?:exclamation point|exclamation mark)\\b",                     "$1!"),
        ("(\\w)\\s+question mark\\b",                                               "$1?"),
        ("(\\w)\\s+semicolon\\b",                                                   "$1;"),
        ("(\\w)\\s+colon\\b",                                                       "$1:"),
        ("(\\w)\\s+(?:period|full stop|dot)\\b",                                   "$1."),
        ("(\\w)\\s+comma\\b",                                                       "$1,"),
        ("(\\w)\\s+(?:em dash|em-dash|emdash)\\b",                                "$1\u{2014}"),
        ("(\\w)\\s+(?:en dash|en-dash|endash)\\b",                                "$1\u{2013}"),
        ("(\\w)\\s+(?:apostrophe|single quote)\\b",                                "$1\u{2019}"),
        ("(\\w)\\s+(?:quotation mark|open quote|open quotation|quote that)\\b",    "$1 \u{201C}"),
        ("\\b(?:close quote|end quote|unquote|close quotation)\\s*(\\w)",          "\u{201D} $1"),
        ("(\\w)\\s+(?:open (?:paren|parenthesis)|left paren|left bracket)\\b",     "$1 ("),
        ("\\b(?:close (?:paren|parenthesis)|right paren|right bracket)\\s*(\\w)", ") $1"),
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

    private static func applyBacktrack(_ text: String) -> (String, Bool) {
        let triggers = "scratch that|forget that|never mind|no wait|no wait actually|i mean|disregard that|cancel that|start over"
        guard let re = try? NSRegularExpression(
            pattern: "([^.!?\\n]*)\\s*\\b(?:\(triggers))\\b\\.?\\s*",
            options: .caseInsensitive
        ) else { return (text, false) }
        let new = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return (new.trimmingCharacters(in: .whitespaces), new != text)
    }

    private static func capitalizeAfterPunctuation(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "([.!?]\\s+)([a-z])") else { return text }
        let ns = NSMutableString(string: text)
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let r = match.range(at: 2)
            ns.replaceCharacters(in: r, with: (text as NSString).substring(with: r).uppercased())
        }
        return ns as String
    }

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

        for r in vocab.replacements {
            let escaped = NSRegularExpression.escapedPattern(for: r.wrong)
            guard let re = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive) else { continue }
            let new = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: r.correct)
            if new != text { log("vocab: \"\(r.wrong)\"→\"\(r.correct)\""); text = new }
        }

        if settings.fillerRemoval {
            for filler in vocab.fillers where filler.enabled {
                guard let re = try? NSRegularExpression(pattern: filler.regexPattern, options: .caseInsensitive) else { continue }
                let new = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                if new != text { log("filler: \"\(filler.phrase)\" stripped"); text = new }
            }
            if let re = try? NSRegularExpression(pattern: "  +") {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
            if let re = try? NSRegularExpression(pattern: ",\\s*,+") {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ",")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if settings.smartFormatting {
            let (backtracted, didBacktrack) = applyBacktrack(text)
            if didBacktrack { log("backtrack applied"); text = backtracted }
            for (pat, repl) in punctCommands {
                guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else { continue }
                let new = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: repl)
                if new != text { log("punct applied"); text = new }
            }
            let listed = detectList(text)
            if listed != text { log("list formatted"); text = listed }
            text = capitalizeAfterPunctuation(text)
            if let s = text.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(s) {
                text = text.prefix(1).uppercased() + text.dropFirst()
            }
        }

        if settings.aiCleanup {
            let hint = (vocab.vocab + vocab.replacements.map(\.correct)).joined(separator: ", ")
            text = await aiCleanup(text, vocabHint: hint, log: log) ?? text
        }

        log("output: \"\(text.prefix(80))\"")
        return text
    }

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
                ? ns.substring(to: positions[0].loc).trimmingCharacters(in: .whitespacesAndNewlines) : ""
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
