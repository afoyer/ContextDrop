import Foundation

/// Hands a conversation to Claude: a claude.ai link whose prompt is the transcript,
/// plain Markdown, or a `claude --resume` command for Claude Code sessions.
enum ClaudeHandoff {
    /// claude.ai/new?q= prefills the composer. Very long URLs are rejected, so the prompt is capped
    /// (about 12 KB once percent-encoded) and keeps the most recent part of the chat.
    static let maxPromptCharacters = 4_000

    struct Link {
        let url: URL
        let truncated: Bool
    }

    static func markdown(_ conversation: Conversation) -> String {
        var out = "# \(conversation.title)\n\n"
        if let picked = conversation.pickedUp {
            out += "_Continued from \(picked.senderName)'s share._\n\n\(picked.contextPrompt())\n\n---\n\n"
        }
        for message in conversation.messages where message.error == nil && !message.text.isEmpty {
            let who = message.role == .user ? "You" : message.author
            out += "**\(who)\(message.kept ? " · kept" : ""):**\n\n\(message.text)\n\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func claudeLink(_ conversation: Conversation) -> Link {
        let via = conversation.provider == .openRouter ? "" : " with \(conversation.provider.displayName)"
        let intro = "Here's a conversation I had in ContextDrop\(via). Pick it up from where it left off.\n\n"
        let body = markdown(conversation)
        let budget = maxPromptCharacters - intro.count
        let truncated = body.count > budget
        let marker = "…(earlier messages omitted)\n\n"
        let text = truncated ? marker + String(body.suffix(budget - marker.count)) : body

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let query = (intro + text).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let url = URL(string: "https://claude.ai/new?q=\(query)") ?? URL(string: "https://claude.ai/new")!
        return Link(url: url, truncated: truncated)
    }

    /// `cd '<folder>' && claude --resume <session>`: continue the exact Claude Code session in a terminal.
    static func resumeCommand(_ conversation: Conversation) -> String? {
        guard conversation.provider == .claudeCode, let session = conversation.cliSessionID, let folder = conversation.folder else { return nil }
        return "cd \(shellQuote(folder.path)) && claude --resume \(session)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
