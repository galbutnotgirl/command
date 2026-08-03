import Foundation

public struct StateFileMutation {
    public let url: URL
    public let data: Data

    public init(url: URL, data: Data) {
        self.url = url
        self.data = data
    }
}

public enum StateFileTransactionError: LocalizedError {
    case duplicateDestination(String)
    case snapshotFailed(String, String)
    case writeFailed(String, String, rollbackFailures: [String])
    case verificationFailed(String, rollbackFailures: [String])

    public var errorDescription: String? {
        switch self {
        case .duplicateDestination(let path):
            return "Tried to update the same settings file twice: \(path)"
        case .snapshotFailed(let path, let reason):
            return "Could not read current settings before saving (\(path)): \(reason)"
        case .writeFailed(let path, let reason, let rollbackFailures):
            return Self.rollbackDescription(
                base: "Could not save settings (\(path)): \(reason)",
                rollbackFailures: rollbackFailures
            )
        case .verificationFailed(let path, let rollbackFailures):
            return Self.rollbackDescription(
                base: "Saved settings could not be verified (\(path))",
                rollbackFailures: rollbackFailures
            )
        }
    }

    private static func rollbackDescription(base: String, rollbackFailures: [String]) -> String {
        guard !rollbackFailures.isEmpty else { return base + ". Previous settings were restored." }
        return base + ". Some previous settings could not be restored: " + rollbackFailures.joined(separator: ", ")
    }
}

private struct StateFileSnapshot {
    let url: URL
    let existed: Bool
    let data: Data?
}

public func applyStateFileMutations(
    _ mutations: [StateFileMutation],
    fileManager: FileManager = .default,
    writer: (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    },
    reader: (URL) throws -> Data = { try Data(contentsOf: $0) }
) throws {
    guard !mutations.isEmpty else { return }

    let normalized = mutations.map {
        StateFileMutation(url: $0.url.standardizedFileURL, data: $0.data)
    }
    var seen = Set<String>()
    for mutation in normalized {
        guard seen.insert(mutation.url.path).inserted else {
            throw StateFileTransactionError.duplicateDestination(mutation.url.path)
        }
    }

    var snapshots: [StateFileSnapshot] = []
    for mutation in normalized {
        let existed = fileManager.fileExists(atPath: mutation.url.path)
        do {
            snapshots.append(StateFileSnapshot(
                url: mutation.url,
                existed: existed,
                data: existed ? try reader(mutation.url) : nil
            ))
        } catch {
            throw StateFileTransactionError.snapshotFailed(
                mutation.url.path,
                error.localizedDescription
            )
        }
    }

    var activeURL: URL?
    do {
        for mutation in normalized {
            activeURL = mutation.url
            try fileManager.createDirectory(
                at: mutation.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer(mutation.data, mutation.url)
            guard try reader(mutation.url) == mutation.data else {
                throw StateFileTransactionError.verificationFailed(
                    mutation.url.path,
                    rollbackFailures: []
                )
            }
        }
    } catch {
        let rollbackFailures = rollback(snapshots, fileManager: fileManager)
        if case StateFileTransactionError.verificationFailed(let path, _) = error {
            throw StateFileTransactionError.verificationFailed(
                path,
                rollbackFailures: rollbackFailures
            )
        }
        throw StateFileTransactionError.writeFailed(
            activeURL?.path ?? normalized.last?.url.path ?? "settings file",
            error.localizedDescription,
            rollbackFailures: rollbackFailures
        )
    }
}

private func rollback(
    _ snapshots: [StateFileSnapshot],
    fileManager: FileManager
) -> [String] {
    var failures: [String] = []
    for snapshot in snapshots.reversed() {
        do {
            if snapshot.existed, let data = snapshot.data {
                try data.write(to: snapshot.url, options: .atomic)
            } else if fileManager.fileExists(atPath: snapshot.url.path) {
                try fileManager.removeItem(at: snapshot.url)
            }
        } catch {
            failures.append(snapshot.url.path)
        }
    }
    return failures
}
