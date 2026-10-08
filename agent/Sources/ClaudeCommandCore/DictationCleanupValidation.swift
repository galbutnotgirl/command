import Foundation

/// Generative formatting must never change dictated words. Deterministic vocabulary,
/// filler removal, and spoken formatting commands run before this boundary.
public enum DictationCleanupValidation {
    public static func preservesWords(original: String, candidate: String) -> Bool {
        let source = words(original)
        return !source.isEmpty && source == words(candidate)
    }

    private static func words(_ text: String) -> [String] {
        // Apostrophe style, capitalization, and punctuation may change; word order may not.
        let normalized = text.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
        return pattern.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
            .map { (normalized as NSString).substring(with: $0.range) }
    }
}
