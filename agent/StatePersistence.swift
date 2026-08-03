import Foundation
import ClaudeCommandCore

extension Notification.Name {
    static let commandSettingsSaveFailed = Notification.Name("CommandSettingsSaveFailed")
}

@discardableResult
func persistStateMutations(_ mutations: [StateFileMutation], label: String) -> Bool {
    do {
        try applyStateFileMutations(mutations)
        return true
    } catch {
        reportStateSaveFailure(label: label, error: error)
        return false
    }
}

@discardableResult
func persistStateData(_ data: Data, to url: URL, label: String) -> Bool {
    persistStateMutations(
        [StateFileMutation(url: url, data: data)],
        label: label
    )
}

func reportStateSaveFailure(label: String, error: Error) {
    let detail = error.localizedDescription
    appendLog("[settings] save failed label=\(label) error=\(detail)")
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .commandSettingsSaveFailed,
            object: nil,
            userInfo: ["message": "\(label) could not be saved. \(detail)"]
        )
    }
}
