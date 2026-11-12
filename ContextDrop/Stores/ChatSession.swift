import Observation
import SwiftUI

/// Input state of one place you type into: the home field, or one conversation.
/// Each conversation has its own, so several chat windows / tabs don't share a draft, attachments or focus.
@MainActor
@Observable
final class ChatSession {
    /// nil for the home input.
    let conversationID: UUID?
    @ObservationIgnored private let folders: FolderShortcutStore

    var draft = "" {
        didSet { if oldValue.hasPrefix("/") != draft.hasPrefix("/") || slashQuery != nil { slashSelection = 0 } }
    }
    /// Screenshots / images waiting to go with the next question.
    var pendingAttachments: [Attachment] = []
    /// Answer highlighted with ↑↓ (⌘C / ⌘K act on it).
    var focusedMessageID: UUID?
    /// Highlighted row of the "/" completion list.
    var slashSelection = 0
    /// Bumped to ask this session's input to take focus.
    var focusToken = 0
    /// Skills picked for the next message (shown as chips; pinned skills live on the conversation).
    var skills: [String] = []

    init(conversationID: UUID?, folders: FolderShortcutStore) {
        self.conversationID = conversationID
        self.folders = folders
    }

    func requestFocus() { focusToken += 1 }

    /// Clears what's being composed (draft and attachments).
    func resetComposer() {
        draft = ""
        pendingAttachments = []
        skills = []
    }

    // MARK: Slash commands

    /// The active command token, including one after other completed commands.
    var slashQuery: String? {
        guard draft.last?.isWhitespace != true, let slash = draft.lastIndex(of: "/") else { return nil }
        let token = draft[slash...]
        guard !token.contains(where: \.isWhitespace),
              SlashCommand.parseChain(String(draft[..<slash]), folders: folders).rest.isEmpty else { return nil }
        return String(token.dropFirst())
    }

    func slashMatches(autoAvailable: Bool) -> [SlashItem] {
        guard let query = slashQuery else { return [] }
        return SlashItem.matches(query, folders: folders, autoAvailable: autoAvailable, inChat: conversationID != nil,
                                 preferImages: pendingAttachments.contains(where: \.isImage))
    }
}
