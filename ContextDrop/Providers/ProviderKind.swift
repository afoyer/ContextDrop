import Foundation

/// Which provider a chat uses. The properties below are everything the rest of the app needs to know
/// about one (menus, slash commands, what a view offers), so adding a case means filling them in here
/// rather than hunting for `switch`es.
enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The raw value is the name this had in the first build; it is what saved settings contain.
    case openAI = "openRouter", claudeCode, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    struct Capabilities: Sendable, Equatable {
        var requiresFolder: Bool
        var showsTerminal: Bool
        var supportsInteractiveControl: Bool
        var supportsContinuation: Bool
        var supportsAttachments: Bool
    }

    var capabilities: Capabilities {
        switch self {
        case .openAI:
            Capabilities(requiresFolder: false, showsTerminal: false, supportsInteractiveControl: false,
                         supportsContinuation: false, supportsAttachments: true)
        case .claudeCode:
            Capabilities(requiresFolder: true, showsTerminal: true, supportsInteractiveControl: true,
                         supportsContinuation: true, supportsAttachments: true)
        case .codex:
            Capabilities(requiresFolder: true, showsTerminal: true, supportsInteractiveControl: false,
                         supportsContinuation: true, supportsAttachments: true)
        }
    }

    /// Local coding agents, in preference order.
    static var deep: [ProviderKind] { allCases.filter(\.capabilities.requiresFolder) }

    var shortcutDigit: Character {
        switch self {
        case .openAI: "1"
        case .claudeCode: "2"
        case .codex: "3"
        }
    }

    /// `/token`s that pick this provider. The first one is shown in the `/` list.
    var slashTokens: [String] {
        switch self {
        case .openAI: ["quick", "openai", "openrouter"]
        case .claudeCode: ["claude"]
        case .codex: ["codex"]
        }
    }

    var slashSubtitle: String {
        capabilities.requiresFolder ? "Ask \(displayName) (reads a folder on this Mac)" : "Quick answer from \(displayName)"
    }

    /// Shown beside "Thinking…".
    var thinkingLabel: String {
        self == .openAI ? "\(displayName) · \(OpenAISettings.model)" : displayName
    }

    /// Runs Claude Code skills (`/name` from `SkillCatalog`).
    var supportsSkills: Bool { self == .claudeCode }

    /// The provider a question goes to once a skill is picked.
    static var forSkills: ProviderKind { .claudeCode }

    /// Where to get the CLI when it isn't installed.
    var installURL: URL? {
        switch self {
        case .openAI: nil
        case .claudeCode: URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")
        case .codex: URL(string: "https://github.com/openai/codex")
        }
    }

    /// The other coding agent this one may hand side tasks to (Settings › Providers).
    var delegatePartner: ProviderKind? {
        switch self {
        case .openAI: nil
        case .claudeCode: .codex
        case .codex: .claudeCode
        }
    }

    /// Its events arrive as whole items rather than a steady stream, so the activity pane shows that it is still working.
    var needsActivityHeartbeat: Bool { self == .codex }

    /// What putting one of its chats in a room makes.
    enum RoomShare: Sendable {
        /// Can't go in a room yet.
        case none
        /// A live tile that follows the run on its owner's Mac; people in the room can send follow-ups to continue it.
        case liveRun
        /// A copy of the chat that anyone in the room can reply in.
        case chatCopy
    }

    var roomShare: RoomShare {
        switch self {
        case .openAI: .chatCopy
        case .claudeCode: .liveRun
        case .codex: .liveRun
        }
    }
}
