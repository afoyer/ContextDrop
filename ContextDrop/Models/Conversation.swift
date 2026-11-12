import Foundation

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
    /// Subagent that took this step (nil = the main agent).
    var agentID: String?
}

/// How much a coding agent may do in a chat without asking. Declared in cycle order (⇧Tab, the menus).
enum PermissionLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    /// `auto` is the agent's own reviewed mode: Claude Code's `--permission-mode auto`, Codex's auto review.
    case readOnly, ask, acceptEdits, auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .readOnly: "Read-only"
        case .ask: "Ask before editing"
        case .acceptEdits: "Edits allowed"
        case .auto: "Auto-approve"
        }
    }

    var detail: String {
        switch self {
        case .readOnly: "Never edits files or runs commands that change things"
        case .ask: "Asks you before edits and commands that change things"
        case .acceptEdits: "Edits files in the folder without asking; still asks for commands"
        case .auto: "Edits and runs commands without asking; a safety check still stops risky ones"
        }
    }

    /// Short form for the Activity pane chip and the composer chip.
    var chip: String {
        switch self {
        case .readOnly: "read-only"
        case .ask: "asks first"
        case .acceptEdits: "edits allowed"
        case .auto: "auto"
        }
    }

    var icon: String {
        switch self {
        case .readOnly: "lock"
        case .ask: "hand.raised"
        case .acceptEdits: "pencil"
        case .auto: "bolt"
        }
    }

    /// May change files without asking (tinted in the UI).
    var changesWithoutAsking: Bool { self == .acceptEdits || self == .auto }

    /// This level, or `cap` when that allows less (levels are listed from least to most allowed).
    func capped(at cap: PermissionLevel) -> PermissionLevel {
        let all = Self.allCases
        return all.firstIndex(of: self)! <= all.firstIndex(of: cap)! ? self : cap
    }

    /// The next level in the ⇧Tab cycle, wrapping around.
    var next: PermissionLevel {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Something the agent wants to do that needs the user's say-so (an edit, a command, another tool).
struct PermissionRequest: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case pending, allowed, denied, expired }

    /// Control-request id (live), or the tool-use id of a refused call.
    let id: String
    var tool: String
    /// The command, file name or other one-line description.
    var summary: String
    var filePath: String?
    /// Preview of the edit, when the tool is an edit and the file could be read.
    var hunks: [DiffHunk] = []
    var added = 0
    var removed = 0
    /// Subagent that asked, if any.
    var agentID: String?
    /// True when the agent is paused waiting for this answer. False = it was refused and needs a follow-up run.
    var live = true
    /// The tool input, sent back unchanged when allowing.
    var input = Data()
    var status: Status = .pending
    var createdAt = Date()

    /// Claude Code's tools that change a file.
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    var isEdit: Bool { Self.editTools.contains(tool) }

    /// "Allow edits in this folder": offered by an agent that can't ask about each edit (Codex's sandbox).
    static let folderEdits = PermissionRequest(id: "codex-edits", tool: "Edit", summary: "files in this folder", live: false)
    var isFolderWide: Bool { id == Self.folderEdits.id }
    var fileName: String { ((filePath ?? "") as NSString).lastPathComponent }

    /// Key used by "Always allow in this chat": the tool, or for shell commands the tool plus the program.
    var rule: String {
        guard tool == "Bash" else { return tool }
        let program = summary.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return "Bash:\(program)"
    }

    var ruleLabel: String {
        if tool == "Bash" { return "`\(rule.dropFirst(5))` commands" }
        return isEdit ? "edits" : tool
    }
}

/// A question the agent asked with choices (Claude's AskUserQuestion).
struct AgentQuestion: Codable, Hashable, Identifiable, Sendable {
    struct Option: Codable, Hashable, Sendable {
        var label: String
        var detail: String
    }

    struct Item: Codable, Hashable, Identifiable, Sendable {
        var question: String
        var header: String
        var options: [Option]
        var multiSelect: Bool
        var answer: String?
        var id: String { question }
    }

    enum Status: String, Codable, Sendable { case pending, answered, expired }

    let id: String
    var items: [Item]
    var agentID: String?
    var input = Data()
    var status: Status = .pending
    var createdAt = Date()

    /// The first question still waiting for an answer.
    var current: Item? { items.first { $0.answer == nil } }
    var title: String { (current ?? items.first)?.question ?? "Question" }
}

/// A helper agent started by the main agent (Claude Code's Task tool).
struct Subagent: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, done, failed }

    let id: String
    var type: String
    var task: String
    var status: Status = .running
    /// What it is doing right now ("Reading StreamParser.swift").
    var current = ""
    var startedAt = Date()
    var endedAt: Date?
}

/// A file the agent changed during a run, with the diff when it could be worked out.
struct FileChange: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case created, modified, deleted }

    let id: String
    var path: String
    var kind: Kind = .modified
    var hunks: [DiffHunk] = []
    var added = 0
    var removed = 0

    var fileName: String { (path as NSString).lastPathComponent }
}

/// What a tab's dot shows.
enum TabState: Sendable { case idle, running, needsYou, finishedUnseen }

struct Message: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    let id: UUID
    let role: Role
    var author: String
    var text: String
    var kept = false
    var steps: [ToolStep] = []
    var permissions: [PermissionRequest] = []
    var questions: [AgentQuestion] = []
    var subagents: [Subagent] = []
    /// Files changed while writing this answer.
    var changes: [FileChange] = []
    /// Skills this question asked for (names).
    var skills: [String] = []
    /// The run ended early or oddly (max turns, non-zero exit after output).
    var warning: String?
    /// Images attached to a question (screenshots, pasted or dropped files).
    var attachments: [Attachment] = []
    var isStreaming = false
    var error: String?
    /// What kind of error it was, so the error card can offer the right way out.
    var failure: ProviderFailure?
    var createdAt = Date()

    init(id: UUID = UUID(), role: Role, author: String, text: String, attachments: [Attachment] = [], isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.author = author
        self.text = text
        self.attachments = attachments
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
    /// Screenshots that came with the picked-up share, saved on this Mac. Given to the AI with the context.
    var pickedUpAttachments: [Attachment] = []
    var sharedWith: [String] = []
    var cliSessionID: String?
    /// How much the coding agent may do without asking.
    var permissionLevel: PermissionLevel = AppDefaults.permissionLevel
    /// Tools the user chose to always allow in this chat (see `PermissionRequest.rule`).
    var alwaysAllowed: Set<String> = []
    /// Skills used with every message in this chat.
    var pinnedSkills: [String] = []
    /// Auto mode: how the first question was routed (shown as a caption).
    var routedBy: RouteDecision?
    /// Waiting for the routing decision.
    var isRouting = false
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
    var allAttachments: [Attachment] { pickedUpAttachments + messages.flatMap(\.attachments) }
    var isEmpty: Bool { messages.isEmpty && pickedUp == nil }

    /// Requests and questions still waiting for the user.
    var pendingPermissions: [PermissionRequest] { messages.last?.permissions.filter { $0.status == .pending } ?? [] }
    var pendingQuestions: [AgentQuestion] { messages.last?.questions.filter { $0.status == .pending } ?? [] }
    var needsUser: Bool { !pendingPermissions.isEmpty || !pendingQuestions.isEmpty }
    var runningSubagents: Int { messages.last?.subagents.filter { $0.status == .running }.count ?? 0 }

    /// File names touched by agent steps or edits. Never contents.
    var referencedFileNames: [String] {
        var seen: [String] = []
        for message in messages {
            let paths = message.steps.compactMap(\.filePath) + message.permissions.compactMap(\.filePath) + message.changes.map(\.path)
            for path in paths {
                let name = (path as NSString).lastPathComponent
                if !name.isEmpty, !seen.contains(name) { seen.append(name) }
            }
        }
        return seen
    }
}
