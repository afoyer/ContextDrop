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
    /// True when the decision call failed and local routing was used.
    var fellBack = false

    static let fallback = RouteDecision(route: .quick, folder: nil, reason: "", fellBack: true)
}

/// One Decisions API call chooses the route, folder and optionally the CLI.
/// Selected folders and literal shortcut mentions take precedence over a quick-answer prediction.
struct AutoRouter: Sendable {
    static let endpoint = URL(string: "https://api.openai.com/v1/decisions")!
    static let model = "gpt-6-luna"
    private static let noFolder = "(none)"

    let apiKey: String

    func decide(question: String, availableCLIs: [ProviderKind], preferredCLI: ProviderKind,
                shortcuts: [FolderShortcut], defaultFolder: String?, selectedFolder: String?,
                workPreferences: String?) async -> RouteDecision {
        guard availableCLIs.contains(where: \.isDeep) else {
            return RouteDecision(route: .quick, folder: nil, reason: "no coding agent ready")
        }
        let decision: RouteDecision
        do {
            let http = OpenAIHTTP(apiKey: apiKey)
            let request = try http.request(Self.endpoint, timeout: 8,
                json: Self.body(question: question, shortcuts: shortcuts, defaultFolder: defaultFolder,
                                selectedFolder: selectedFolder, availableCLIs: availableCLIs,
                                preferredCLI: preferredCLI, workPreferences: workPreferences))
            let data = try await http.data(for: request)
            decision = try Self.decision(from: data)
        } catch {
            decision = .fallback
        }
        return Self.resolve(decision, question: question, shortcuts: shortcuts, selectedFolder: selectedFolder,
                            availableCLIs: availableCLIs, preferredCLI: preferredCLI,
                            chooseCLIByTask: workPreferences != nil)
    }

    static func body(question: String, shortcuts: [FolderShortcut], defaultFolder: String?,
                     selectedFolder: String? = nil, availableCLIs: [ProviderKind] = [],
                     preferredCLI: ProviderKind = .claudeCode, workPreferences: String? = nil) -> [String: Any] {
        let folderList = shortcuts.map { "/\($0.name) = \($0.display)" }.joined(separator: "; ")
        var questions: [[String: Any]] = [[
            "type": "choice",
            "name": "route",
            "instructions": """
            Which assistant should answer this question from a user on their Mac?
            Strongly prefer "code" whenever the user mentions a local folder, path, project, repository or folder shortcut, \
            even for explanations, planning, summaries, reviews or an ambiguous request. They usually expect you to inspect \
            that project. Do not require an explicit request to edit files or run commands. When in doubt about a project, choose code.
            "code" runs a coding CLI in a folder: it can read files, search, run commands and propose edits.
            "quick" has no access to the Mac. Use it for clearly standalone general knowledge, writing, math, generic programming \
            questions or pasted snippets/screenshots with no local project context. A hypothetical example path alone is not a local project.
            Explicitly selected folder: \(selectedFolder ?? "none"). If selected, choose code.
            Saved folder shortcuts: \(folderList.isEmpty ? "none" : folderList).
            Default/last folder: \(defaultFolder ?? "none"). This alone does not imply the question is about that folder.
            """,
            "choices": [
                ["value": "quick", "description": "Standalone general answer with no local project context."],
                ["value": "code", "description": "A folder or project is mentioned, or local files, tools or edits would help."],
            ],
        ]]
        if !shortcuts.isEmpty {
            questions.append([
                "type": "choice",
                "name": "folder",
                "instructions": "Which saved folder does the question refer to by name, path, /shortcut or project context? Pick \(noFolder) if none matches. Do not choose a folder merely because it was used previously.",
                "choices": [["value": noFolder, "description": "No saved folder matches."]]
                    + shortcuts.map { ["value": $0.name, "description": "/\($0.name) = \($0.display)"] },
            ])
        }
        let clis = ProviderKind.deep.filter { availableCLIs.contains($0) }
        if let workPreferences, clis.count > 1 {
            questions.append([
                "type": "choice",
                "name": "cli",
                "instructions": """
                If this request goes to a coding CLI, choose the CLI according to the user's work preferences below.
                Both CLIs can read files, edit code and run commands. Do not invent specializations.
                If no preference matches, preferences are empty, or the work is ambiguous, choose \(preferredCLI.rawValue).
                User's work preferences: \(workPreferences)
                """,
                "choices": clis.map { ["value": $0.rawValue, "description": $0.displayName] },
            ])
        }
        return ["model": model, "input": String(question.prefix(4_000)), "questions": questions]
    }

    /// Enforces folder intent and CLI availability, including when the API fails or refuses.
    static func resolve(_ prediction: RouteDecision, question: String, shortcuts: [FolderShortcut], selectedFolder: String?,
                        availableCLIs: [ProviderKind], preferredCLI: ProviderKind, chooseCLIByTask: Bool) -> RouteDecision {
        var result = prediction
        let mentioned = shortcuts.filter { shortcut in
            [shortcut.name, shortcut.path, shortcut.display].contains { value in
                let pattern = "(?<![\\p{L}\\p{N}_-])" + NSRegularExpression.escapedPattern(for: value) + "(?![\\p{L}\\p{N}_-])"
                return question.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
        // Only accept folder choices actually supplied to the API.
        result.folder = shortcuts.first { $0.name.lowercased() == prediction.folder?.lowercased() }?.name
        if mentioned.count == 1 { result.folder = mentioned[0].name }
        if selectedFolder != nil || !mentioned.isEmpty || result.folder != nil {
            result.route = .code
            result.reason = selectedFolder != nil ? "folder selected" : "folder mentioned"
        }
        let available = ProviderKind.deep.filter { availableCLIs.contains($0) }
        let preferred = available.contains(preferredCLI) ? preferredCLI : available.first
        if result.route == .code, let preferred {
            result.provider = chooseCLIByTask && available.contains(prediction.provider) ? prediction.provider : preferred
        } else {
            result.route = .quick
            result.provider = .openAI
            result.folder = nil
            if available.isEmpty { result.reason = "no coding agent ready" }
        }
        return result
    }

    /// A missing, refused or unknown route triggers local fallback. Optional CLI failures keep the preferred CLI.
    static func decision(from data: Data) throws -> RouteDecision {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [[String: Any]] else { throw ProviderError.badResponse }
        func answer(_ name: String) -> [String: Any]? {
            answers.first { $0["name"] as? String == name && $0["type"] as? String == "choice" }
        }
        guard let routeAnswer = answer("route"), let choice = routeAnswer["choice"] as? String,
              let route = RouteDecision.Route(rawValue: choice) else { throw ProviderError.badResponse }
        let folder = (answer("folder")?["choice"] as? String).flatMap { $0 == noFolder ? nil : $0.lowercased() }
        var reason = route == .code ? "needs your files" : "general question"
        if let confidence = routeAnswer["confidence"] as? Double, confidence.isFinite, (0...1).contains(confidence) {
            reason += " (\(Int((confidence * 100).rounded()))% sure)"
        }
        let cli = (answer("cli")?["choice"] as? String).flatMap(ProviderKind.init(rawValue:))
        return RouteDecision(route: route, folder: folder, reason: reason, provider: cli.flatMap { $0.isDeep ? $0 : nil } ?? .openAI)
    }
}
