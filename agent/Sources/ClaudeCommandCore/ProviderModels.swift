import Foundation

public enum AIProvider: String, CaseIterable, Codable, Sendable {
    case claude
    case codex

    public var label: String { self == .codex ? "ChatGPT" : "Claude" }
    public var appBundleIdentifier: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        }
    }
    public var defaultCLICommand: String { rawValue }
    public var supportsDestinations: Bool { true }
    public var supportsWorkspace: Bool { self == .codex }
    public var supportsForeground: Bool { true }
    public var supportsBackground: Bool { true }
    public var supportsImages: Bool { true }
    public var supportsSkills: Bool { true }
    public var supportsAutoSubmit: Bool { true }

    public func skillInvocation(_ name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/$"))
        guard !clean.isEmpty else { return "" }
        return self == .claude ? "/\(clean)" : "$\(clean)"
    }
}

public enum AIProviderChoice: String, CaseIterable, Codable, Sendable {
    case `default`
    case claude
    case codex

    public var label: String { self == .default ? "Default" : (provider?.label ?? rawValue.capitalized) }
    public var provider: AIProvider? { self == .default ? nil : AIProvider(rawValue: rawValue) }

    public func resolve(default defaultProvider: AIProvider) -> AIProvider {
        provider ?? defaultProvider
    }
}

public enum PrimaryAssistantPreference: String, CaseIterable, Codable, Sendable {
    case claude
    case chatgpt
    case codex

    public var label: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .codex: return "Codex"
        }
    }

    public var detail: String {
        switch self {
        case .claude: return "Claude Chat, Cowork, or Code."
        case .chatgpt: return "ChatGPT chats and general prompts."
        case .codex: return "Codex coding sessions in a workspace."
        }
    }

    public var provider: AIProvider {
        switch self {
        case .claude: return .claude
        case .chatgpt, .codex: return .codex
        }
    }

    public var destination: ClaudeDestination {
        switch self {
        case .claude: return .recent
        case .codex: return .code
        case .chatgpt: return .chat
        }
    }
}

public enum CodexExecutionPreset: String, CaseIterable, Codable, Sendable {
    case readOnly
    case workspaceWrite

    public var label: String { self == .readOnly ? "Read-only" : "Workspace changes" }
    public var arguments: [String] {
        switch self {
        case .readOnly: return ["--sandbox", "read-only"]
        case .workspaceWrite: return ["--sandbox", "workspace-write"]
        }
    }
}

public struct ProviderCapabilities: Equatable, Sendable {
    public let destinations: Bool
    public let workspace: Bool
    public let foreground: Bool
    public let background: Bool
    public let images: Bool
    public let skills: Bool
    public let autoSubmit: Bool

    public init(provider: AIProvider) {
        destinations = provider.supportsDestinations
        workspace = provider.supportsWorkspace
        foreground = provider.supportsForeground
        background = provider.supportsBackground
        images = provider.supportsImages
        skills = provider.supportsSkills
        autoSubmit = provider.supportsAutoSubmit
    }
}
