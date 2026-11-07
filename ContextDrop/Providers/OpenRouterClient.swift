import Foundation

struct ChatTurn: Codable, Sendable {
    let role: String
    let content: String
}

/// What OpenRouter extracts for the share sheet.
struct SummaryDraft: Decodable, Sendable {
    var title: String
    var summary: String
    var decisions: [String]
    var openQuestions: [String]

    private enum CodingKeys: String, CodingKey { case title, summary, decisions, openQuestions, open_questions }

    init(title: String, summary: String, decisions: [String], openQuestions: [String]) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.openQuestions = openQuestions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        decisions = (try? c.decode([String].self, forKey: .decisions)) ?? []
        openQuestions = (try? c.decode([String].self, forKey: .openQuestions))
            ?? (try? c.decode([String].self, forKey: .open_questions)) ?? []
    }
}

/// OpenRouter chat completions: streamed answers (SSE) and one-shot JSON summaries.
struct OpenRouterClient: Sendable {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    let apiKey: String
    let model: String

    static func fromSettings() throws -> OpenRouterClient {
        guard let key = OpenRouterSettings.apiKey() else { throw ProviderError.missingKey }
        return OpenRouterClient(apiKey: key, model: OpenRouterSettings.model)
    }

    private func request(_ turns: [ChatTurn], stream: Bool, jsonMode: Bool) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ContextDrop", forHTTPHeaderField: "X-Title")
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": turns.map { ["role": $0.role, "content": $0.content] },
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func stream(_ turns: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try request(turns, stream: true, jsonMode: false))
                    guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
                    if http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4_000 { break }
                        }
                        throw ProviderError.http(http.statusCode, Self.errorMessage(body))
                    }
                    for try await line in bytes.lines {
                        // SSE: "data: {...}"; lines starting with ":" are keep-alive comments.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = object["error"] as? [String: Any] {
                            throw ProviderError.http((error["code"] as? Int) ?? 0, (error["message"] as? String) ?? "Stream error")
                        }
                        if let choices = object["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(_ turns: [ChatTurn], jsonMode: Bool) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: try request(turns, stream: false, jsonMode: jsonMode))
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode, Self.errorMessage(String(decoding: data.prefix(4_000), as: UTF8.self)))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw ProviderError.badResponse }
        return content
    }

    /// Asks OpenRouter for the handoff brief as structured JSON. Kept answers are flagged so they anchor it.
    func summarize(_ conversation: Conversation) async throws -> SummaryDraft {
        let system = """
        You write handoff briefs so someone else can continue a chat. Reply with ONLY a JSON object:
        {"title": string (max 6 words), "summary": string (2-3 plain sentences: the goal and where it stands), \
        "decisions": [string] (max 5, short, only things actually decided), \
        "openQuestions": [string] (max 4, unresolved questions worth asking next)}.
        Answers marked [KEPT] matter most: the summary must be consistent with them. No markdown.
        """
        var transcript = ""
        if let picked = conversation.pickedUp {
            transcript += "Context this chat started from:\n\(picked.contextPrompt())\n\n---\n"
        }
        for message in conversation.messages where message.error == nil && !message.text.isEmpty {
            transcript += "\n[\(message.author)\(message.kept ? " · KEPT" : "")]\n\(message.text)\n"
        }
        if transcript.count > 30_000 { transcript = "…" + String(transcript.suffix(30_000)) }
        let turns = [ChatTurn(role: "system", content: system), ChatTurn(role: "user", content: transcript)]

        let raw: String
        do {
            raw = try await complete(turns, jsonMode: true)
        } catch ProviderError.http(400, _) {
            raw = try await complete(turns, jsonMode: false) // model without json_object support
        }
        return try Self.parseDraft(raw)
    }

    static func parseDraft(_ raw: String) throws -> SummaryDraft {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8) else { throw ProviderError.badResponse }
        var draft = try JSONDecoder().decode(SummaryDraft.self, from: data)
        draft.summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.decisions = draft.decisions.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(5).map { $0 }
        draft.openQuestions = draft.openQuestions.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(4).map { $0 }
        guard !draft.summary.isEmpty else { throw ProviderError.badResponse }
        return draft
    }

    static func errorMessage(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(body.prefix(200))
    }
}
