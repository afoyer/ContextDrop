import Foundation

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

    static let fallback = RouteDecision(route: .quick, folder: nil, reason: "", fellBack: true)
}

/// Auto mode: asks the OpenAI Decisions API whether a question needs a coding agent on this Mac,
/// and which folder shortcut it means. The API returns probabilities over the choices it is given
/// (no generated text), so the reason shown is built locally.
struct AutoRouter: Sendable {
    static let endpoint = URL(string: "https://api.openai.com/v1/decisions")!
    /// The only model the Decisions API accepts.
    static let model = "gpt-6-luna"
    private static let noFolder = "(none)"

    let apiKey: String

    /// Never fails: any problem with the call means a quick answer.
    func decide(question: String, codeAvailable: Bool, shortcuts: [FolderShortcut], defaultFolder: String?) async -> RouteDecision {
        // Nothing to decide when no coding agent is ready.
        guard codeAvailable else { return RouteDecision(route: .quick, folder: nil, reason: "no coding agent ready") }
        do {
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: Self.body(question: question, shortcuts: shortcuts, defaultFolder: defaultFolder))

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
            guard http.statusCode == 200 else {
                throw ProviderError.http(http.statusCode, OpenAIClient.errorMessage(String(decoding: data.prefix(4_000), as: UTF8.self)))
            }
            return try Self.decision(from: data)
        } catch {
            return .fallback
        }
    }

    static func body(question: String, shortcuts: [FolderShortcut], defaultFolder: String?) -> [String: Any] {
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
                "instructions": "Which of the user's project folder shortcuts does the question clearly refer to (by name, path or \"/name\")? Pick \(noFolder) unless it clearly names one.",
                "choices": [["value": noFolder, "description": "No specific project is named."]]
                    + shortcuts.map { ["value": $0.name, "description": "/\($0.name) = \($0.display)"] },
            ])
        }
        return ["model": model, "input": String(question.prefix(4_000)), "questions": questions]
    }

    /// Reads the API's reply. A refusal (or a missing answer) for "route" throws, so the caller falls back to a quick answer.
    static func decision(from data: Data) throws -> RouteDecision {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [[String: Any]] else { throw ProviderError.badResponse }
        func answer(_ name: String) -> [String: Any]? {
            answers.first { $0["name"] as? String == name && $0["type"] as? String == "choice" }
        }
        guard let routeAnswer = answer("route"), let choice = routeAnswer["choice"] as? String else { throw ProviderError.badResponse }

        let route: RouteDecision.Route = choice == "code" ? .code : .quick
        let folder = (answer("folder")?["choice"] as? String).flatMap { $0 == noFolder ? nil : $0.lowercased() }
        var reason = route == .code ? "needs your files" : "general question"
        if let confidence = routeAnswer["confidence"] as? Double { reason += " (\(Int((confidence * 100).rounded()))% sure)" }
        return RouteDecision(route: route, folder: folder, reason: reason)
    }
}
