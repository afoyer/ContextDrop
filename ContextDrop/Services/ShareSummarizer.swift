import Foundation

/// Writes the handoff brief for a share: asks OpenAI for it as JSON and reads the reply.
enum ShareSummarizer {
    /// Kept answers are flagged in the transcript so they anchor the brief.
    static func summarize(_ conversation: Conversation, detail: ShareDetail) async throws -> SummaryDraft {
        let client = try OpenAIClient.fromSettings()
        let turns = [ChatTurn(role: "system", content: instructions(for: detail)),
                     ChatTurn(role: "user", content: transcript(of: conversation, detail: detail))]
        let raw: String
        do {
            raw = try await client.complete(turns, jsonMode: true)
        } catch ProviderError.http(400, _) {
            raw = try await client.complete(turns, jsonMode: false) // model without json_object support
        }
        return try parseDraft(raw)
    }

    static func instructions(for detail: ShareDetail) -> String {
        switch detail {
        case .brief:
            """
            You write handoff briefs so someone else can continue a chat. Reply with ONLY a JSON object:
            {"title": string (max 6 words), "summary": string (2-3 plain sentences: the goal and where it stands), \
            "decisions": [string] (max 5, short, only things actually decided), \
            "openQuestions": [string] (max 4, unresolved questions worth asking next)}.
            Answers marked [KEPT] matter most: the summary must be consistent with them. No markdown.
            """
        case .detailed:
            """
            You write detailed handoff briefs so someone else (and their AI) can continue this work without the original chat. \
            Reply with ONLY a JSON object:
            {"title": string (max 6 words), \
            "summary": string (2 short paragraphs, max 180 words: the goal and why, what was tried or found, and exactly where it stands now), \
            "keyFacts": [string] (max 8: concrete specifics someone would need: names, numbers, versions, commands, file paths, \
            code identifiers, URLs, error messages; each one line and self-contained), \
            "decisions": [string] (max 6, only things actually decided, with the reason when given), \
            "nextSteps": [string] (max 5, concrete actions in order), \
            "openQuestions": [string] (max 4, unresolved questions worth asking next)}.
            Answers marked [KEPT] matter most: everything must be consistent with them. \
            Agent actions show what a coding agent ran or read; use them for facts. Never invent details. No markdown.
            """
        }
    }

    /// The chat as the model reads it, cut to its most recent 40,000 characters.
    static func transcript(of conversation: Conversation, detail: ShareDetail) -> String {
        var transcript = ""
        if let picked = conversation.pickedUp {
            transcript += "Context this chat started from:\n\(picked.contextPrompt())\n\n---\n"
        }
        for message in conversation.messages where message.error == nil && (!message.text.isEmpty || !message.steps.isEmpty) {
            let images = message.attachments.isEmpty ? "" : " · \(message.attachments.count) screenshot(s) attached"
            transcript += "\n[\(message.author)\(message.kept ? " · KEPT" : "")\(images)]\n\(message.text)\n"
            if detail == .detailed, !message.steps.isEmpty {
                let actions = message.steps.prefix(25).map { "\($0.label) \($0.detail)" }.joined(separator: "; ")
                transcript += "[agent actions] \(actions)\n"
            }
        }
        return transcript.count > 40_000 ? "…" + String(transcript.suffix(40_000)) : transcript
    }

    static func parseDraft(_ raw: String) throws -> SummaryDraft {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8) else { throw ProviderError.badResponse }
        var draft = try JSONDecoder().decode(SummaryDraft.self, from: data)
        func clean(_ items: [String], _ max: Int) -> [String] {
            items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(max).map { String($0.prefix(400)) }
        }
        draft.summary = String(draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6_000))
        draft.decisions = clean(draft.decisions, 6)
        draft.openQuestions = clean(draft.openQuestions, 4)
        draft.keyFacts = clean(draft.keyFacts, 8)
        draft.nextSteps = clean(draft.nextSteps, 5)
        guard !draft.summary.isEmpty else { throw ProviderError.badResponse }
        return draft
    }
}
