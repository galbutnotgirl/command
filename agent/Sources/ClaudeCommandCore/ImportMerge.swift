import Foundation

public struct ImportPreviewCounts: Equatable, Sendable {
    public let incoming: Int
    public let current: Int
    public let same: Int
    public let added: Int
    public let updated: Int
    public let currentOnly: Int

    public init(incoming: Int, current: Int, same: Int, added: Int, updated: Int, currentOnly: Int) {
        self.incoming = incoming
        self.current = current
        self.same = same
        self.added = added
        self.updated = updated
        self.currentOnly = currentOnly
    }
}

private func canonicalImportJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }
    return text
}

public func vocabularyImportPreviewCounts(
    current: [String: Any],
    incoming: [String: Any]
) -> ImportPreviewCounts {
    func keyedCounts(field: String, key: String) -> (incoming: Int, current: Int, same: Int, added: Int, updated: Int, currentOnly: Int) {
        let currentItems = current[field] as? [[String: Any]] ?? []
        let incomingItems = incoming[field] as? [[String: Any]] ?? []
        var currentByKey: [String: [String: Any]] = [:]
        for item in currentItems {
            if let id = item[key] as? String { currentByKey[id] = item }
        }
        var incomingByKey: [String: [String: Any]] = [:]
        for item in incomingItems {
            if let id = item[key] as? String { incomingByKey[id] = item }
        }
        let currentKeys = Set(currentByKey.keys)
        let incomingKeys = Set(incomingByKey.keys)
        let shared = currentKeys.intersection(incomingKeys)
        let same = shared.filter {
            canonicalImportJSON(currentByKey[$0] ?? [:]) == canonicalImportJSON(incomingByKey[$0] ?? [:])
        }.count
        return (
            incomingItems.count,
            currentItems.count,
            same,
            incomingKeys.subtracting(currentKeys).count,
            shared.count - same,
            currentKeys.subtracting(incomingKeys).count
        )
    }

    let replacements = keyedCounts(field: "replacements", key: "wrong")
    let fillers = keyedCounts(field: "fillers", key: "phrase")
    let currentTerms = Set(current["vocab"] as? [String] ?? [])
    let incomingTerms = Set(incoming["vocab"] as? [String] ?? [])
    return ImportPreviewCounts(
        incoming: replacements.incoming + fillers.incoming + incomingTerms.count,
        current: replacements.current + fillers.current + currentTerms.count,
        same: replacements.same + fillers.same + currentTerms.intersection(incomingTerms).count,
        added: replacements.added + fillers.added + incomingTerms.subtracting(currentTerms).count,
        updated: replacements.updated + fillers.updated,
        currentOnly: replacements.currentOnly + fillers.currentOnly + currentTerms.subtracting(incomingTerms).count
    )
}

public func mergeDictionaryValues(current: [String: Any], incoming: [String: Any]) -> [String: Any] {
    var merged = current
    for (key, value) in incoming { merged[key] = value }
    return merged
}

public func mergeDictionaryArrays(current: [[String: Any]], incoming: [[String: Any]], key: String) -> [[String: Any]] {
    var byKey: [String: [String: Any]] = [:]
    var order: [String] = []
    for item in current + incoming {
        let id = item[key] as? String ?? UUID().uuidString
        if byKey[id] == nil { order.append(id) }
        byKey[id] = item
    }
    return order.compactMap { byKey[$0] }
}

public func mergeEnrichRuleDictionaries(current: [[String: Any]], incoming: [[String: Any]]) -> [[String: Any]] {
    func ruleKey(_ item: [String: Any]) -> String {
        let match = item["match"] as? String ?? ""
        let pattern = item["pattern"] as? String ?? ""
        let pathPrefix = item["pathPrefix"] as? String ?? ""
        return "\(match)\u{1F}\(pattern)\u{1F}\(pathPrefix)"
    }

    var byKey: [String: [String: Any]] = [:]
    var order: [String] = []
    for item in current + incoming {
        let id = ruleKey(item)
        if byKey[id] == nil { order.append(id) }
        byKey[id] = item
    }
    return order.compactMap { byKey[$0] }
}

public func mergeVocabularyDictionaries(current: [String: Any], incoming: [String: Any]) -> [String: Any] {
    var merged = mergeDictionaryValues(current: current, incoming: incoming)
    merged["replacements"] = mergeDictionaryArrays(
        current: current["replacements"] as? [[String: Any]] ?? [],
        incoming: incoming["replacements"] as? [[String: Any]] ?? [],
        key: "wrong"
    )
    let vocab = Set((current["vocab"] as? [String] ?? []) + (incoming["vocab"] as? [String] ?? []))
    merged["vocab"] = Array(vocab).sorted()
    merged["fillers"] = mergeDictionaryArrays(
        current: current["fillers"] as? [[String: Any]] ?? [],
        incoming: incoming["fillers"] as? [[String: Any]] ?? [],
        key: "phrase"
    )
    return merged
}
