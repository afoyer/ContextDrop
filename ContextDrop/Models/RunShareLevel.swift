import Foundation

/// How much of one of this Mac's runs its owner shows the room. Kept on this Mac only; never sent.
enum RunShareLevel: String, CaseIterable, Sendable, Identifiable {
    /// The plan, state, subagents and changed files.
    case steps
    /// All of that plus the last log lines (secrets masked).
    case withLog

    var id: String { rawValue }

    var label: String {
        switch self {
        case .steps: "Live run"
        case .withLog: "Live run + log"
        }
    }

    var detail: String {
        switch self {
        case .steps: "Steps, files and the final answer"
        case .withLog: "Also the latest log lines, secrets hidden"
        }
    }
}
