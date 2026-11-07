import Foundation

/// Events a provider streams back while answering.
enum ProviderEvent: Sendable {
    case text(String)                 // append to the answer
    case textBlockBreak               // a new paragraph from a later agent turn
    case step(ToolStep)               // insert or update by id
    case stepFinished(id: String, failed: Bool)
    case editRequest(EditRequest)     // an edit the agent wasn't allowed to make yet
    case editsBlocked                 // Codex: a patch was rejected by the read-only sandbox
    case session(String)              // CLI session / thread id for resuming
    case log(TerminalLine.Kind, String) // terminal pane only
    case runInfo(TerminalRunPatch)    // terminal pane status (pid, model, tokens, exit code…)

    /// Terminal-pane telemetry that doesn't count as an answer.
    var isTelemetry: Bool {
        switch self {
        case .log, .runInfo: true
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
        case .missingKey: "No OpenRouter API key. Add one in Settings."
        case .http(let code, let message): code == 401 ? "OpenRouter rejected the API key (401). \(message)" : "OpenRouter error \(code): \(message)"
        case .badResponse: "OpenRouter sent an unexpected response."
        case .notInstalled(let tool): "\(tool) isn't installed on this Mac."
        case .process(let message): message
        case .noFolder: "Choose a project folder first."
        }
    }

    /// Short headline for the error card.
    var headline: String {
        switch self {
        case .missingKey: "Add your OpenRouter key"
        case .http, .badResponse: "OpenRouter didn’t respond"
        case .notInstalled: "Tool not found"
        case .process: "The agent stopped"
        case .noFolder: "No folder chosen"
        }
    }
}
