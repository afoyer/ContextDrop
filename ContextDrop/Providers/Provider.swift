import Foundation

/// Events a provider streams back while answering.
enum ProviderEvent: Sendable {
    case text(String)                 // append to the answer
    case textBlockBreak               // a new paragraph from a later agent turn
    case step(ToolStep)               // insert or update by id
    case stepFinished(id: String, failed: Bool)
    case permissionRequest(PermissionRequest) // the agent wants to do something that needs a yes
    case question(AgentQuestion)      // the agent asked a multiple-choice question
    case requestCancelled(String)     // the CLI withdrew a pending request or question
    case subagentStarted(Subagent)
    case subagentActivity(id: String, current: String)
    case subagentFinished(id: String, failed: Bool)
    case fileChange(FileChange)       // a file was changed (with its diff when known)
    case warning(String)              // the run ended early or oddly
    case session(String)              // CLI session / thread id for resuming
    case log(TerminalLine.Kind, String, agent: String? = nil) // activity pane only
    case raw(String)                  // the CLI's JSON line, for the Raw JSON view
    case runInfo(TerminalRunPatch)    // terminal pane status (pid, model, tokens, exit code…)
    case plan([RunPlanStep])          // the agent's to-do list (replaces the previous one)

    /// Terminal-pane telemetry that doesn't count as an answer.
    var isTelemetry: Bool {
        switch self {
        case .log, .runInfo, .raw, .plan: true
        default: false
        }
    }
}

enum ProviderStatus: Equatable, Sendable {
    case checking
    case ready(String)
    case notFound(String)
    case notSignedIn(String)
    case missingKey

    var isReady: Bool { if case .ready = self { true } else { false } }
    /// Ready, or not known yet: worth trying rather than refusing up front.
    var isUsable: Bool { isReady || self == .checking }

    var detail: String {
        switch self {
        case .checking: "Checking…"
        case .ready(let s), .notFound(let s), .notSignedIn(let s): s
        case .missingKey: "No API key. Add one in Settings"
        }
    }
}

enum ProviderError: LocalizedError {
    case missingKey
    case http(Int, String)
    case badResponse
    case notInstalled(String)
    case process(String)
    case noFolder

    var errorDescription: String? {
        switch self {
        case .missingKey: "No OpenAI API key. Add one in Settings."
        case .http(let code, let message): code == 401 ? "OpenAI rejected the API key (401). \(message)" : "OpenAI error \(code): \(message)"
        case .badResponse: "OpenAI sent an unexpected response."
        case .notInstalled(let tool): "\(tool) isn't installed on this Mac."
        case .process(let message): message
        case .noFolder: "Choose a project folder first."
        }
    }

    /// Short headline for the error card.
    var headline: String {
        switch self {
        case .missingKey: "Add your OpenAI key"
        case .http, .badResponse: "OpenAI didn’t respond"
        case .notInstalled: "Tool not found"
        case .process: "The agent stopped"
        case .noFolder: "No folder chosen"
        }
    }
}

extension Error {
    /// What to show the user: the error's own description when it has one.
    var userMessage: String { (self as? LocalizedError)?.errorDescription ?? localizedDescription }

    /// The work was stopped on purpose (Stop, a closed tab), not a failure.
    var isCancellation: Bool { self is CancellationError || (self as? URLError)?.code == .cancelled }
}
