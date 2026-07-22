import Foundation

public struct ImportFileMutation {
    public let url: URL
    public let data: Data

    public init(url: URL, data: Data) {
        self.url = url
        self.data = data
    }
}

public enum ImportTransactionError: LocalizedError {
    case invalidJSONObject
    case duplicateDestination(String)
    case snapshotFailed(String, String)
    case writeFailed(String, String, rollbackFailures: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidJSONObject:
            return "Imported settings contain data that cannot be saved as JSON."
        case .duplicateDestination(let path):
            return "Import tried to update the same settings file twice: \(path)"
        case .snapshotFailed(let path, let reason):
            return "Could not read current settings before import (\(path)): \(reason)"
        case .writeFailed(let path, let reason, let rollbackFailures):
            let base = "Could not save imported settings (\(path)): \(reason)"
            guard !rollbackFailures.isEmpty else { return base + ". Current settings were restored." }
            return base + ". Some settings could not be restored: " + rollbackFailures.joined(separator: ", ")
        }
    }
}

public func encodeImportJSONObject(_ value: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(value) else {
        throw ImportTransactionError.invalidJSONObject
    }
    return try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
}

public func applyImportFileMutations(
    _ mutations: [ImportFileMutation],
    fileManager: FileManager = .default,
    writer: (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }
) throws {
    guard !mutations.isEmpty else { return }

    var seen = Set<String>()
    for mutation in mutations {
        let path = mutation.url.standardizedFileURL.path
        guard seen.insert(path).inserted else {
            throw ImportTransactionError.duplicateDestination(path)
        }
    }

    struct Snapshot {
        let url: URL
        let existed: Bool
        let data: Data?
    }

    var snapshots: [Snapshot] = []
    for mutation in mutations {
        let url = mutation.url.standardizedFileURL
        let existed = fileManager.fileExists(atPath: url.path)
        do {
            let data = existed ? try Data(contentsOf: url) : nil
            snapshots.append(Snapshot(url: url, existed: existed, data: data))
        } catch {
            throw ImportTransactionError.snapshotFailed(url.path, error.localizedDescription)
        }
    }

    var activeURL: URL?
    do {
        for mutation in mutations {
            let url = mutation.url.standardizedFileURL
            activeURL = url
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer(mutation.data, url)
        }
    } catch {
        var rollbackFailures: [String] = []
        for snapshot in snapshots.reversed() {
            do {
                if snapshot.existed, let data = snapshot.data {
                    try data.write(to: snapshot.url, options: .atomic)
                } else if fileManager.fileExists(atPath: snapshot.url.path) {
                    try fileManager.removeItem(at: snapshot.url)
                }
            } catch {
                rollbackFailures.append(snapshot.url.path)
            }
        }
        let destination = activeURL?.path
            ?? mutations.last?.url.path
            ?? "settings file"
        throw ImportTransactionError.writeFailed(
            destination,
            error.localizedDescription,
            rollbackFailures: rollbackFailures
        )
    }
}
