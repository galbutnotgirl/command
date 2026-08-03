import Foundation

public typealias ImportFileMutation = StateFileMutation

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
    do {
        try applyStateFileMutations(
            mutations,
            fileManager: fileManager,
            writer: writer
        )
    } catch let error as StateFileTransactionError {
        switch error {
        case .duplicateDestination(let path):
            throw ImportTransactionError.duplicateDestination(path)
        case .snapshotFailed(let path, let reason):
            throw ImportTransactionError.snapshotFailed(path, reason)
        case .writeFailed(let path, let reason, let rollbackFailures):
            throw ImportTransactionError.writeFailed(
                path,
                reason,
                rollbackFailures: rollbackFailures
            )
        case .verificationFailed(let path, let rollbackFailures):
            throw ImportTransactionError.writeFailed(
                path,
                "saved data could not be verified",
                rollbackFailures: rollbackFailures
            )
        }
    }
}
