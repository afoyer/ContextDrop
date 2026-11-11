import Foundation

struct ChatTurn: Sendable {
    let role: String
    let content: String
    /// Local image files sent with this turn (as JPEG data URLs; needs a vision-capable model).
    var images: [URL] = []

    var payload: [String: Any] {
        guard !images.isEmpty else { return ["role": role, "content": content] }
        var parts: [[String: Any]] = [["type": "text", "text": content.isEmpty ? "(see image)" : content]]
        for url in images {
            if let dataURL = Attachments.dataURL(url) { parts.append(["type": "image_url", "image_url": ["url": dataURL]]) }
        }
        return ["role": role, "content": parts]
    }
}

/// Auto mode's decision for a new chat's first question.
struct RouteDecision: Codable, Hashable, Sendable {
    enum Route: String, Codable, Sendable { case quick, code }
    var route: Route
    /// Folder shortcut name the question refers to, if any.
    var folder: String?
    var reason: String
    /// What was actually used after availability checks.
    var provider: ProviderKind = .openAI
    /// True when the decision call failed and the chat fell back to a quick answer.
    var fellBack = false
}

/// How much the share brief should carry.
enum ShareDetail: String, CaseIterable, Sendable {
    case brief, detailed

    var label: String { self == .brief ? "Brief" : "Detailed" }

    private static let key = "ContextDrop.shareDetail"
    static var preferred: ShareDetail {
        get { UserDefaults.standard.string(forKey: key).flatMap(ShareDetail.init(rawValue:)) ?? .detailed }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// What OpenAI extracts for the share sheet.
struct SummaryDraft: Decodable, Sendable {
    var title: String
    var summary: String
    var decisions: [String]
    var openQuestions: [String]
    var keyFacts: [String] = []
    var nextSteps: [String] = []

    private enum CodingKeys: String, CodingKey {
        case title, summary, decisions, openQuestions, open_questions, keyFacts, key_facts, nextSteps, next_steps
    }

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
        keyFacts = (try? c.decode([String].self, forKey: .keyFacts)) ?? (try? c.decode([String].self, forKey: .key_facts)) ?? []
        nextSteps = (try? c.decode([String].self, forKey: .nextSteps)) ?? (try? c.decode([String].self, forKey: .next_steps)) ?? []
    }
}

/// OpenAI chat completions: streamed answers (SSE) and one-shot JSON summaries.
struct OpenAIClient: Sendable {
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    let apiKey: String
    let model: String

    static func fromSettings() throws -> OpenAIClient {
        guard let key = OpenAISettings.apiKey() else { throw ProviderError.missingKey }
        return OpenAIClient(apiKey: key, model: OpenAISettings.model)
    }

    private func request(_ turns: [ChatTurn], stream: Bool, jsonMode: Bool, maxTokens: Int? = nil, timeout: TimeInterval = 120) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": turns.map(\.payload),
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        if Self.isReasoningModel(model) {
            // Reasoning models spend hidden tokens before answering; keep that short so the
            // decision call stays inside its timeout, and do not cap output with a tiny budget.
            body["reasoning_effort"] = "low"
        } else if let maxTokens {
            body["max_completion_tokens"] = maxTokens
        }
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

    func complete(_ turns: [ChatTurn], jsonMode: Bool, maxTokens: Int? = nil, timeout: TimeInterval = 120) async throws -> String {
        let (data, response) = try await URLSession.shared.data(
            for: try request(turns, stream: false, jsonMode: jsonMode, maxTokens: maxTokens, timeout: timeout))
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

    /// Asks OpenAI for the handoff brief as structured JSON. Kept answers are flagged so they anchor it.
    func summarize(_ conversation: Conversation, detail: ShareDetail) async throws -> SummaryDraft {
        let system: String
        switch detail {
        case .brief:
            system = """
            You write handoff briefs so someone else can continue a chat. Reply with ONLY a JSON object:
            {"title": string (max 6 words), "summary": string (2-3 plain sentences: the goal and where it stands), \
            "decisions": [string] (max 5, short, only things actually decided), \
            "openQuestions": [string] (max 4, unresolved questions worth asking next)}.
            Answers marked [KEPT] matter most: the summary must be consistent with them. No markdown.
            """
        case .detailed:
            system = """
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
        if transcript.count > 40_000 { transcript = "…" + String(transcript.suffix(40_000)) }
        let turns = [ChatTurn(role: "system", content: system), ChatTurn(role: "user", content: transcript)]

        let raw: String
        do {
            raw = try await complete(turns, jsonMode: true)
        } catch ProviderError.http(400, _) {
            raw = try await complete(turns, jsonMode: false) // model without json_object support
        }
        return try Self.parseDraft(raw)
    }

    // MARK: Decisions API (Auto routing)

    static let decisionsEndpoint = URL(string: "https://api.openai.com/v1/decisions")!
    /// The only model the Decisions API accepts.
    static let decisionsModel = "gpt-6-luna"
    private static let noFolder = "(none)"

    /// Auto mode: asks the Decisions API whether a question needs a coding agent on this Mac, and which folder shortcut it means.
    /// The API returns probabilities over the choices we give it (no generated text), so the reason shown is built locally.
    func route(question: String, codeAvailable: Bool, shortcuts: [FolderShortcut], defaultFolder: String?) async throws -> RouteDecision {
        // Nothing to decide when no coding agent is ready.
        guard codeAvailable else { return RouteDecision(route: .quick, folder: nil, reason: "no coding agent ready") }

        var questions: [[String: Any]] = [[
            "type": "choice",
            "name": "route",
            "instructions": """
            Which assistant should answer this question from a user on their Mac?
            "code" is a coding agent that runs inside one of the user's project folders: it can read files, search the repo, \
            run commands (git, builds, tests) and propose edits. Pick it only when answering needs the user's own files, \
            repository, terminal or code changes (e.g. "why does X in my project fail", "refactor this file", "what changed in git").
            "quick" is a general chat model with no access to the Mac: general knowledge, explanations, writing, math, \
            generic programming questions that don't need the user's code, or anything about a pasted snippet or screenshot alone.
            Default project folder: \(defaultFolder ?? "none").
            """,
            "choices": [
                ["value": "quick", "description": "General answer; no access to the user's files."],
                ["value": "code", "description": "Needs the user's own files, repository, terminal or code changes."],
            ],
        ]]
        if !shortcuts.isEmpty {
            questions.append([
                "type": "choice",
                "name": "folder",
                "instructions": "Which of the user's project folder shortcuts does the question clearly refer to (by name, path or \"/name\")? Pick \(Self.noFolder) unless it clearly names one.",
                "choices": [["value": Self.noFolder, "description": "No specific project is named."]]
                    + shortcuts.map { ["value": $0.name, "description": "/\($0.name) = \($0.display)"] },
            ])
        }
        let body: [String: Any] = [
            "model": Self.decisionsModel,
            "input": String(question.prefix(4_000)),
            "questions": questions,
        ]

        var request = URLRequest(url: Self.decisionsEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode, Self.errorMessage(String(decoding: data.prefix(4_000), as: UTF8.self)))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [[String: Any]] else { throw ProviderError.badResponse }
        func answer(_ name: String) -> [String: Any]? {
            answers.first { $0["name"] as? String == name && $0["type"] as? String == "choice" }
        }
        // A refusal (or a missing answer) for "route" counts as a failed call: the caller falls back to a quick answer.
        guard let routeAnswer = answer("route"), let choice = routeAnswer["choice"] as? String else { throw ProviderError.badResponse }

        let route: RouteDecision.Route = choice == "code" ? .code : .quick
        let folder = (answer("folder")?["choice"] as? String).flatMap { $0 == Self.noFolder ? nil : $0.lowercased() }
        var reason = route == .code ? "needs your files" : "general question"
        if let confidence = routeAnswer["confidence"] as? Double { reason += " (\(Int((confidence * 100).rounded()))% sure)" }
        return RouteDecision(route: route, folder: folder, reason: reason)
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

    /// o-series and gpt-5 models reason before answering and reject some chat parameters.
    static func isReasoningModel(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.hasPrefix("gpt-5") || id.range(of: #"^o\d"#, options: .regularExpression) != nil
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
