import Foundation

enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case openRouter, claudeCode, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Deep providers run a local CLI agent inside a project folder.
    var isDeep: Bool { self != .openRouter }

    var shortcutDigit: Character {
        switch self {
        case .openRouter: "1"
        case .claudeCode: "2"
        case .codex: "3"
        }
    }
}

/// One visible step taken by a CLI agent (search, read, command, edit).
struct ToolStep: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case search, read, command, edit, other }
    let id: String
    var kind: Kind
    var label: String
    var detail: String
    var done: Bool
    var failed: Bool = false

    /// File path touched by this step, if any (only names ever leave the Mac).
    var filePath: String?
}

/// An edit the agent wanted to make but was not yet allowed to.
struct EditRequest: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var filePath: String
    var oldText: String
    var newText: String
    var status: Status = .pending

    enum Status: String, Codable, Sendable { case pending, allowed, applied }

    var fileName: String { (filePath as NSString).lastPathComponent }
    var addedLines: Int { newText.isEmpty ? 0 : newText.components(separatedBy: "\n").count }
}

struct Message: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    let id: UUID
    let role: Role
    var author: String
    var text: String
    var kept = false
    var steps: [ToolStep] = []
    var editRequests: [EditRequest] = []
    var isStreaming = false
    var error: String?
    var createdAt = Date()

    init(id: UUID = UUID(), role: Role, author: String, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.author = author
        self.text = text
        self.isStreaming = isStreaming
    }
}

struct Conversation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var provider: ProviderKind
    var folder: URL?
    var messages: [Message] = []
    /// Set when this chat was continued from someone else's share. Its `contextPrompt()` is the AI context.
    var pickedUp: ShareSummary?
    var sharedWith: [String] = []
    var cliSessionID: String?
    var createdAt = Date()
    var updatedAt = Date()

    init(id: UUID = UUID(), title: String = "New chat", provider: ProviderKind, folder: URL? = nil, pickedUp: ShareSummary? = nil) {
        self.id = id
        self.title = title
        self.provider = provider
        self.folder = folder
        self.pickedUp = pickedUp
    }

    var keptCount: Int { messages.filter(\.kept).count }
    var isEmpty: Bool { messages.isEmpty && pickedUp == nil }

    /// File names touched by agent steps or edits. Never contents.
    var referencedFileNames: [String] {
        var seen: [String] = []
        for message in messages {
            let paths = message.steps.compactMap(\.filePath) + message.editRequests.map(\.filePath)
            for path in paths {
                let name = (path as NSString).lastPathComponent
                if !name.isEmpty, !seen.contains(name) { seen.append(name) }
            }
        }
        return seen
    }
}
