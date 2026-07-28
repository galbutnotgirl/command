import AppKit
import Foundation

private let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
private let stateDirectory = "\(home)/.claude/state"
private let historyDirectory = "\(stateDirectory)/cliphistory"
private let metadataPath = "\(stateDirectory)/clipboard.json"
private let indexPath = "\(historyDirectory)/index.json"
private let configPath = "\(stateDirectory)/command-config.json"
private let copySourcePath = "\(stateDirectory)/last_copy.json"
private let attributionLogPath = "\(home)/.claude/logs/attribution.log"
private let maxItems = 1_000

private let blockedBundles: Set<String> = [
    "com.apple.keychainaccess", "com.apple.SecurityAgent",
    "com.1password.1password", "com.agilebits.onepassword7",
    "com.apple.wallet", "com.apple.Passwords", "com.claudecommand",
]
private let concealedTypes: Set<String> = [
    "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
    "com.agilebits.onepassword.metadata",
]
private let selfWriteOrigins = [
    "com.claudecommand.dictation": "dictation",
    "com.claudecommand.send": "sent",
]

private func createRuntimeDirectories() throws {
    let manager = FileManager.default
    try manager.createDirectory(atPath: historyDirectory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    try manager.createDirectory(atPath: "\(home)/.claude/logs", withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: historyDirectory)
}

private func appendLog(_ message: String) {
    let line = "\(Date().formatted(.iso8601)) [clipboard] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: attributionLogPath) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: attributionLogPath), options: .atomic)
    }
}

private func replaceJSON(_ value: Any, at path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    let temporary = path + ".tmp"
    try data.write(to: URL(fileURLWithPath: temporary), options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
    if FileManager.default.fileExists(atPath: path) {
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                   withItemAt: URL(fileURLWithPath: temporary))
    } else {
        try FileManager.default.moveItem(atPath: temporary, toPath: path)
    }
}

private func readJSONArray(at path: String) -> [[String: Any]] {
    guard let data = FileManager.default.contents(atPath: path),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return rows
}

private func retentionDays() -> Int {
    if let value = ProcessInfo.processInfo.environment["CLIP_RETENTION_DAYS"],
       let days = Int(value), days > 0 { return days }
    guard let data = FileManager.default.contents(atPath: configPath),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 7 }
    if let days = object["retentionDays"] as? Int, days > 0 { return days }
    if let days = object["retentionDays"] as? Double, days > 0 { return Int(days) }
    return 7
}

private func timestamp(_ row: [String: Any]) -> Double {
    (row["ts"] as? Double) ?? Double((row["ts"] as? Int) ?? 0)
}

private func prune(_ rows: [[String: Any]], now: Double) -> [[String: Any]] {
    let cutoff = now - Double(retentionDays() * 86_400)
    var kept: [[String: Any]] = []
    for row in rows {
        if timestamp(row) < cutoff {
            if let file = row["file"] as? String {
                try? FileManager.default.removeItem(atPath: "\(historyDirectory)/\(file)")
            }
        } else {
            kept.append(row)
        }
    }
    while kept.count > maxItems {
        let row = kept.removeLast()
        if let file = row["file"] as? String {
            try? FileManager.default.removeItem(atPath: "\(historyDirectory)/\(file)")
        }
    }
    return kept
}

private func readCopySource(changeCount: Int, now: Double) -> String? {
    guard let data = FileManager.default.contents(atPath: copySourcePath),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let bundle = object["bundle"] as? String, !bundle.isEmpty else { return nil }
    let created = (object["ts"] as? Double) ?? 0
    guard now - created <= 5 else { return nil }
    if let stamped = object["cc"] as? Int, stamped != changeCount { return nil }
    if object["cc"] == nil, now - created >= 1 { return nil }
    try? FileManager.default.removeItem(atPath: copySourcePath)
    return bundle
}

private func saveHistory(changeCount: Int, pasteboard: NSPasteboard, bundle: String,
                         origin: String, now: Double) throws {
    let types = Set((pasteboard.types ?? []).map(\.rawValue))
    let text = pasteboard.string(forType: .string)
    let isImage = types.contains(NSPasteboard.PasteboardType.png.rawValue)
        || types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
    var rows = readJSONArray(at: indexPath)

    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let first = rows.first,
           (first["full"] as? String == text
            || (origin == "sent" && now - timestamp(first) < 5)) {
            if !origin.isEmpty, first["origin"] as? String != origin {
                rows[0]["origin"] = origin
                try replaceJSON(prune(rows, now: now), at: indexPath)
            }
            return
        }
        let id = String(Int(now * 1_000))
        let file = "\(id).txt"
        try text.write(toFile: "\(historyDirectory)/\(file)", atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: "\(historyDirectory)/\(file)")
        var row: [String: Any] = [
            "id": id, "type": "text", "file": file,
            "preview": String(text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ").prefix(90)),
            "full": text, "ts": now, "bundle": bundle,
        ]
        if !origin.isEmpty { row["origin"] = origin }
        rows.insert(row, at: 0)
    } else if isImage {
        let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        guard let data else { return }
        let id = String(Int(now * 1_000))
        let file = "\(id).png"
        let destination = "\(historyDirectory)/\(file)"
        if pasteboard.data(forType: .png) != nil {
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        } else {
            guard let representation = NSBitmapImageRep(data: data),
                  let png = representation.representation(using: .png, properties: [:]) else { return }
            try png.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
        var row: [String: Any] = [
            "id": id, "type": "image", "file": file,
            "preview": "image", "ts": now, "bundle": bundle,
        ]
        if !origin.isEmpty { row["origin"] = origin }
        rows.insert(row, at: 0)
    } else {
        return
    }
    try replaceJSON(prune(rows, now: now), at: indexPath)
}

do {
    try createRuntimeDirectories()
    let pasteboard = NSPasteboard.general
    var lastChangeCount = pasteboard.changeCount
    var lastPrune = 0.0
    let initialBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    try replaceJSON(["epoch": Int(Date().timeIntervalSince1970),
                     "bundle": initialBundle, "blocked": false], at: metadataPath)
    appendLog("started native watcher pid=\(ProcessInfo.processInfo.processIdentifier)")

    while true {
        autoreleasepool {
            let now = Date().timeIntervalSince1970
            let changeCount = pasteboard.changeCount
            if changeCount != lastChangeCount {
                lastChangeCount = changeCount
                let copiedByCommand = readCopySource(changeCount: changeCount, now: now)
                let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                let bundle = copiedByCommand ?? frontmost
                let types = Set((pasteboard.types ?? []).map(\.rawValue))
                let blocked = concealedTypes.contains(where: types.contains)
                    || blockedBundles.contains(bundle)
                do {
                    try replaceJSON(["epoch": Int(now), "bundle": bundle, "blocked": blocked],
                                    at: metadataPath)
                    if !blocked {
                        try saveHistory(changeCount: changeCount, pasteboard: pasteboard,
                                        bundle: bundle,
                                        origin: copiedByCommand.flatMap { selfWriteOrigins[$0] } ?? "",
                                        now: now)
                    }
                } catch {
                    appendLog("change failed: \(error.localizedDescription)")
                }
            }
            if now - lastPrune >= 60 {
                lastPrune = now
                let rows = prune(readJSONArray(at: indexPath), now: now)
                try? replaceJSON(rows, at: indexPath)
            }
        }
        Thread.sleep(forTimeInterval: 0.025)
    }
} catch {
    fputs("CommandClipboardWatcher fatal: \(error)\n", stderr)
    exit(1)
}
