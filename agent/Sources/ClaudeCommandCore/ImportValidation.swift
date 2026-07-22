import Foundation

public enum ImportPayloadSection: Sendable {
    case shortcutBindings
    case customActions
    case builtInCompose
    case commandTemplates
    case contextRules
    case vocabulary
    case handoffSettings
    case appPreferences
}

public func isValidImportPayload(_ payload: Any, for section: ImportPayloadSection) -> Bool {
    switch section {
    case .shortcutBindings:
        return (payload as? [[String: Any]])?.allSatisfy {
            $0["action"] is String && $0["keycode"] is Int && $0["mods"] is Int
                && ($0["enabled"] == nil || $0["enabled"] is Bool)
        } == true
    case .customActions:
        return (payload as? [[String: Any]])?.allSatisfy {
            $0["id"] is String && $0["name"] is String && $0["prompt"] is String
        } == true
    case .builtInCompose:
        guard let value = payload as? [String: Any] else { return false }
        return value["autoSubmitDefault"] is Bool
            && value["autoSubmitOverrides"] is [String: Bool]
    case .commandTemplates:
        return payload is [String: String]
    case .contextRules:
        return (payload as? [[String: Any]])?.allSatisfy {
            guard let rawMatch = $0["match"] as? String else { return false }
            return EnrichMatchType(rawValue: rawMatch) != nil
                && $0["pattern"] is String && $0["text"] is String
        } == true
    case .vocabulary:
        guard let value = payload as? [String: Any] else { return false }
        let replacementsValid = (value["replacements"] as? [[String: Any]])?.allSatisfy {
            $0["wrong"] is String && $0["correct"] is String
        } ?? (value["replacements"] == nil)
        let termsValid = value["vocab"] is [String] || value["vocab"] == nil
        let fillersValid = (value["fillers"] as? [[String: Any]])?.allSatisfy {
            $0["phrase"] is String
        } ?? (value["fillers"] == nil)
        return replacementsValid && termsValid && fillersValid
    case .handoffSettings:
        return payload is [String: Any]
    case .appPreferences:
        guard let value = payload as? [String: Any] else { return false }
        let providerValid = value["defaultProvider"] == nil
            || (value["defaultProvider"] as? String).flatMap(AIProvider.init(rawValue:)) != nil
        let claudeDestinationValid = value["claudeDestination"] == nil
            || (value["claudeDestination"] as? String)
                .flatMap(ClaudeDestination.init(rawValue:)).map { $0 != .default } == true
        let codexDestinationValid = value["codexDestination"] == nil
            || ["recent", "chat", "code"].contains(value["codexDestination"] as? String ?? "")
        let workspaceValid = value["codexWorkspace"] == nil || value["codexWorkspace"] is String
        let retentionValid = ["clipRetentionDays", "commandRetentionDays", "handoffRetentionDays"].allSatisfy {
            value[$0] == nil || (value[$0] as? Int).map { $0 >= 1 && $0 <= 365 } == true
        }
        let boolKeys = [
            VoiceSettingsKeys.soundsEnabled,
            VoiceSettingsKeys.dictationEnabled,
            VoiceSettingsKeys.fillerRemoval,
            VoiceSettingsKeys.smartFormatting,
            VoiceSettingsKeys.aiCleanup
        ]
        let booleansValid = boolKeys.allSatisfy { value[$0] == nil || value[$0] is Bool }
        let soundNamesValid = [VoiceSettingsKeys.startSound, VoiceSettingsKeys.stopSound].allSatisfy {
            value[$0] == nil || value[$0] is String
        }
        let volumeValid = value[VoiceSettingsKeys.soundVolume] == nil
            || (value[VoiceSettingsKeys.soundVolume] as? Double).map { $0 >= 0 && $0 <= 1 } == true
        let durationValid = value[VoiceSettingsKeys.minDictationDuration] == nil
            || (value[VoiceSettingsKeys.minDictationDuration] as? Double).map { $0 >= 0 && $0 <= 1.5 } == true
        let assistantKeys = [
            VoiceSettingsKeys.dictationAssistantProvider,
            VoiceSettingsKeys.dictationAssistant2Provider
        ]
        let assistantsValid = assistantKeys.allSatisfy {
            value[$0] == nil || (value[$0] as? String).flatMap(AIProviderChoice.init(rawValue:)) != nil
        }
        return providerValid && claudeDestinationValid && codexDestinationValid
            && workspaceValid && retentionValid && booleansValid && soundNamesValid
            && volumeValid && durationValid && assistantsValid
    }
}
