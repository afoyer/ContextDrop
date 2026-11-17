import Foundation

/// One coding-agent CLI: how to start it and how to read it. `CLIRunner` does the rest.
///
/// To add a CLI: write a `CLIAgent` and a `CLIParser`, add a `ProviderKind` case, and register
/// `CLIProvider(agent:)` in `Providers.all`.
protocol CLIAgent: Sendable {
    var kind: ProviderKind { get }
    /// The command to look for on the user's PATH.
    var executableName: String { get }

    /// Whether the CLI is signed in, asked with its own status command.
    func signInStatus(executable: String, environment: [String: String]) async -> ProviderStatus
    func arguments(for request: CLIRunner.Request) -> [String]
    /// The first JSON message written to the CLI's stdin. Nil = it doesn't read stdin (the prompt is an argument).
    func openingInput(for request: CLIRunner.Request) -> [String: Any]?
    /// Last changes to the child's environment (e.g. dropping a key it must not inherit).
    func adjust(environment: inout [String: String])
    func makeParser(for request: CLIRunner.Request) -> any CLIParser

    /// The question as this agent should get it when the user picked skills for it.
    func prompt(_ text: String, skills: [String]) -> String
    /// What the agent is told when it may hand side tasks to the other CLI. Nil = it can't at this level.
    func delegateInstructions(level: PermissionLevel) -> String?
    /// How to run again after the user allowed something that was refused in a run that couldn't ask.
    func retry(afterApproving what: String) -> ApprovedRetry

    /// Ways setup can install this CLI, in order of preference (`CLISetup`). Empty = setup can't install it.
    var installOptions: [CLIInstallOption] { get }
    /// Arguments that start the CLI's own sign-in (it opens the browser). Empty = setup can't sign it in.
    var signInArguments: [String] { get }
}

extension CLIAgent {
    var installOptions: [CLIInstallOption] { [] }
    var signInArguments: [String] { [] }
    func openingInput(for request: CLIRunner.Request) -> [String: Any]? { nil }
    func adjust(environment: inout [String: String]) {}
    func prompt(_ text: String, skills: [String]) -> String { text }
    func delegateInstructions(level: PermissionLevel) -> String? { nil }
}

/// Turns one CLI's output lines into events. One parser lives for one run.
protocol CLIParser {
    mutating func parse(_ line: String) -> [ProviderEvent]

    /// Something that counts as an answer arrived (not only telemetry).
    var producedOutput: Bool { get }
    /// The CLI reported that the run failed; shown as the error.
    var failure: String? { get }
    /// The agent began its turn (the start-up watchdog stops waiting).
    var turnStarted: Bool { get }
    /// The answer is complete: stdin can be closed so the CLI exits.
    var finished: Bool { get }

    /// Lines too chatty for the Raw JSON view.
    func isNoise(_ line: String) -> Bool
    /// Requests from the CLI that nothing here handles; the runner answers them with an error so it never waits.
    mutating func takeUnsupportedRequests() -> [String]
    /// Work a line set off that needs time (e.g. reading a diff from git). Called after every line.
    mutating func followUp(in folder: URL) async -> [ProviderEvent]
    /// A last look once the process is gone, with everything it wrote to stderr.
    func afterExit(stderr: String) -> [ProviderEvent]
}

extension CLIParser {
    var finished: Bool { false }
    func isNoise(_ line: String) -> Bool { false }
    mutating func takeUnsupportedRequests() -> [String] { [] }
    mutating func followUp(in folder: URL) async -> [ProviderEvent] { [] }
    func afterExit(stderr: String) -> [ProviderEvent] { [] }
}

/// Text helpers shared by the parsers (what goes in the activity pane).
enum CLIText {
    /// A JSON line with a `type`, or nil for anything else.
    static func typed(_ line: String) -> (type: String, object: [String: Any])? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        return (type, object)
    }

    /// First `lines` lines, each at most 300 characters, with a note of what was cut.
    static func clip(_ text: String, lines: Int) -> String {
        let all = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var kept = all.prefix(lines).map { $0.count > 300 ? String($0.prefix(299)) + "…" : $0 }
        if all.count > lines { kept.append("… \(all.count - lines) more line(s)") }
        return kept.joined(separator: "\n")
    }

    /// One-line description of a tool input: the interesting argument first.
    static func describe(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "pattern", "path", "url", "query", "description"] {
            if let value = input[key] as? String, !value.isEmpty {
                let single = value.replacingOccurrences(of: "\n", with: " ")
                return single.count > 200 ? String(single.prefix(199)) + "…" : single
            }
        }
        return ""
    }

    /// Claude tool_result content is a string or an array of {type: text, text}.
    static func resultText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block in
                if block["type"] as? String == "image" { return "[image]" }
                return block["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }
}
