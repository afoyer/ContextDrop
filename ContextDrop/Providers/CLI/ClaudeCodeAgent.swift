import Foundation

/// Claude Code (`claude`). Verified against claude 2.1.322.
///
/// `-p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio`.
/// The prompt goes in on stdin as a JSON user message. When a tool needs a yes, the CLI pauses and writes a
/// `control_request` (`can_use_tool`) on stdout; we answer with a `control_response` on stdin (`CLIRunner.Handle.respond`).
/// `AskUserQuestion` arrives the same way and is answered by returning the input with `answers` filled in.
/// Read-only chats use `--permission-mode dontAsk` instead: refused tools are listed in the final `permission_denials`.
struct ClaudeCodeAgent: CLIAgent {
    let kind = ProviderKind.claudeCode
    let executableName = "claude"

    /// The only way Claude Code may start Codex without asking: read-only.
    static let codexDelegatePrefix = "codex exec --sandbox read-only --skip-git-repo-check"

    /// Read-only tools Claude may use without asking.
    static let readOnlyTools = ["Read", "Grep", "Glob", "LS", "Bash(git status:*)", "Bash(git log:*)", "Bash(git diff:*)", "Bash(ls:*)"]

    func signInStatus(executable exe: String, environment env: [String: String]) async -> ProviderStatus {
        let result = await CLIRunner.runCapture(exe, ["auth", "status"], env: env, timeout: 10)
        if let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["loggedIn"] as? Bool == true {
            return .ready("claude CLI found · signed in")
        }
        return .notSignedIn("claude found · not signed in (run `claude auth login`)")
    }

    func arguments(for request: CLIRunner.Request) -> [String] {
        // The prompt is sent on stdin, so it can start with "-", be long, and stays out of `ps`.
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--forward-subagent-text"]
        switch request.level {
        case .readOnly: args += ["--permission-mode", "dontAsk"]
        case .ask: args += ["--permission-prompt-tool", "stdio", "--permission-mode", "manual"]
        case .acceptEdits: args += ["--permission-prompt-tool", "stdio", "--permission-mode", "acceptEdits"]
        // Claude's own safety check decides; anything it escalates still reaches us on stdio.
        case .auto: args += ["--permission-prompt-tool", "stdio", "--permission-mode", "auto"]
        }
        args += ["--allowedTools"] + Self.readOnlyTools + (request.delegate ? ["Bash(\(Self.codexDelegatePrefix):*)"] : [])
        if !request.images.isEmpty || request.filesInAttachments { args += ["--add-dir", Attachments.directory.path] }
        if let id = request.sessionID { args += ["--resume", id] }
        if let system = request.systemAppend, !system.isEmpty { args += ["--append-system-prompt", system] }
        return args
    }

    func openingInput(for request: CLIRunner.Request) -> [String: Any]? {
        ["type": "user", "message": ["role": "user", "content": Self.prompt(for: request)]]
    }

    /// The text Claude is asked, with attached images listed for its Read tool.
    static func prompt(for request: CLIRunner.Request) -> String {
        guard !request.images.isEmpty else { return request.prompt }
        return request.prompt + "\n\nAttached image(s). Open each with the Read tool before answering:\n"
            + request.images.map { "- \($0)" }.joined(separator: "\n")
    }

    func makeParser(for request: CLIRunner.Request) -> any CLIParser {
        ClaudeCodeParser(folder: request.folder.path, level: request.level)
    }

    func prompt(_ text: String, skills: [String]) -> String {
        guard !skills.isEmpty else { return text }
        let names = skills.map { "`\($0)`" }.joined(separator: ", ")
        return "Use the \(names) skill\(skills.count == 1 ? "" : "s") for this request (load \(skills.count == 1 ? "it" : "them") with the Skill tool first).\n\n" + text
    }

    func delegateInstructions(level: PermissionLevel) -> String? {
        return """
        You can hand self-contained, read-only side tasks to Codex, another coding agent on this Mac, to save your own context: broad code searches, reading and summarising many files, a second opinion on a diff. Run it with Bash, exactly in this form (it is pre-approved; allow up to 10 minutes): \(Self.codexDelegatePrefix) "<a complete, standalone task that says what to report back>"
        Codex starts with no knowledge of this conversation and cannot edit files. Use it only when it saves real work, check what it reports before relying on it, and do the editing yourself.
        """
    }

    /// Claude asks again for the one thing that was approved (answered for the user) and for anything else.
    func retry(afterApproving what: String) -> ApprovedRetry {
        ApprovedRetry(prompt: "The user approved only this refused request (\(what)). Do that now, then confirm in one sentence. Ask before any other changes.",
                      level: .ask, asksAgain: true)
    }
}

/// Reads Claude Code's `stream-json` output.
struct ClaudeCodeParser: CLIParser {
    let folder: String
    let level: PermissionLevel
    private(set) var producedOutput = false
    private(set) var failure: String?
    private(set) var turnStarted = false
    /// The final `result` arrived: nothing more will be asked.
    private(set) var finished = false
    private var sawText = false
    private var streamMessageID = ""
    private var streamedText: [String: [Int: String]] = [:]
    private var emittedText: [String: Set<String>] = [:]
    private var subagentIDs: Set<String> = []
    private var pendingEdits: [String: (tool: String, input: [String: Any], before: String?)] = [:]
    private var unsupportedRequests: [String] = []
    /// Tool + summary of requests already put to the user live (their denials are the user's own answer).
    private var askedLive: Set<String> = []

    init(folder: String, level: PermissionLevel = .ask) {
        self.folder = folder
        self.level = level
    }

    mutating func parse(_ line: String) -> [ProviderEvent] {
        guard let (type, object) = CLIText.typed(line) else { return [] }
        let events = events(type, object)
        if events.contains(where: { !$0.isTelemetry }) { producedOutput = true }
        return events
    }

    /// Partial-message deltas arrive many times a second and are already in the answer.
    func isNoise(_ line: String) -> Bool { line.contains("\"type\":\"stream_event\"") }

    /// Control requests we don't handle: the runner answers them with an error so the CLI never waits.
    mutating func takeUnsupportedRequests() -> [String] {
        defer { unsupportedRequests = [] }
        return unsupportedRequests
    }

    private func relative(_ path: String) -> String {
        FolderDrop.relative(path, to: folder) ?? path
    }

    private mutating func text(_ value: String) -> [ProviderEvent] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        defer { sawText = true }
        return sawText ? [.textBlockBreak, .text(trimmed)] : [.text(trimmed)]
    }

    private mutating func events(_ type: String, _ o: [String: Any]) -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        // Set on everything a subagent says or does.
        let agent = o["parent_tool_use_id"] as? String
        switch type {
        case "control_request":
            guard let requestID = o["request_id"] as? String else { break }
            let request = o["request"] as? [String: Any] ?? [:]
            guard request["subtype"] as? String == "can_use_tool" else {
                unsupportedRequests.append(requestID)
                break
            }
            let tool = request["tool_name"] as? String ?? "Tool"
            let input = request["input"] as? [String: Any] ?? [:]
            let inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
            if tool == "AskUserQuestion", let question = Self.question(id: requestID, input: input, data: inputData) {
                events.append(.question(question))
                events.append(.log(.info, "? waiting on you: \(question.title)", agent: agent))
            } else {
                let permission = permissionRequest(id: requestID, tool: tool, input: input, data: inputData, live: true)
                askedLive.insert(permission.tool + permission.summary)
                events.append(.permissionRequest(permission))
                events.append(.log(.info, "? needs your OK: \(tool) \(permission.summary)", agent: agent))
            }
        case "control_cancel_request":
            if let requestID = o["request_id"] as? String { events.append(.requestCancelled(requestID)) }
        case "stream_event":
            guard agent == nil, let event = o["event"] as? [String: Any], let eventType = event["type"] as? String else { break }
            if eventType == "message_start" {
                streamMessageID = (event["message"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
                streamedText = [streamMessageID: [:]]
            }
            if eventType == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let value = delta["text"] as? String, !value.isEmpty {
                let index = event["index"] as? Int ?? 0
                if streamedText[streamMessageID]?[index] == nil, sawText { events.append(.textBlockBreak) }
                streamedText[streamMessageID, default: [:]][index, default: ""] += value
                sawText = true
                events.append(.text(value))
            }
        case "system":
            if o["subtype"] as? String == "init" {
                turnStarted = true
                if let id = o["session_id"] as? String { events.append(.session(id)) }
                let tools = o["tools"] as? [Any]
                events.append(.runInfo(TerminalRunPatch(turnStarted: true)))
                events.append(.runInfo(TerminalRunPatch(model: o["model"] as? String,
                                                        cliVersion: o["claude_code_version"] as? String,
                                                        toolCount: tools?.count)))
                events.append(.log(.info, "session \((o["session_id"] as? String)?.prefix(8) ?? "?") · \(o["model"] as? String ?? "model ?") · \(tools?.count ?? 0) tools"))
            }
        case "assistant":
            let message = o["message"] as? [String: Any] ?? [:]
            let messageID = message["id"] as? String ?? ""
            let content = message["content"] as? [[String: Any]] ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let value = block["text"] as? String ?? ""
                    if agent != nil {
                        if !value.isEmpty { events.append(.log(.info, CLIText.clip(value, lines: 8), agent: agent)) }
                        break
                    }
                    // The same message can be reported more than once, and its text may already have streamed.
                    guard !value.isEmpty, emittedText[messageID]?.contains(value) != true else { break }
                    emittedText[messageID, default: []].insert(value)
                    let streamed = (streamedText[messageID] ?? [:]).values
                        .filter { !$0.isEmpty && value.hasPrefix($0) }
                        .max { $0.count < $1.count }
                    if let streamed {
                        let rest = String(value.dropFirst(streamed.count))
                        if !rest.isEmpty { events.append(.text(rest)) }
                    } else {
                        events += text(value)
                    }
                case "thinking":
                    if let value = block["thinking"] as? String, !value.isEmpty {
                        events.append(.log(.info, "thinking: " + CLIText.clip(value, lines: 6), agent: agent))
                    }
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    if name == "Task" || name == "Agent" {
                        subagentIDs.insert(id)
                        let task = input["description"] as? String ?? String((input["prompt"] as? String ?? "").prefix(80))
                        let subagent = Subagent(id: id, type: input["subagent_type"] as? String ?? "Agent", task: task)
                        events.append(.subagentStarted(subagent))
                        events.append(.log(.info, "\(subagent.type) subagent started: \(task)", agent: id))
                        break
                    }
                    if name == "Bash", let command = input["command"] as? String, command.hasPrefix("codex exec ") {
                        // Work handed to Codex shows as a lane, like Claude's own subagents.
                        subagentIDs.insert(id)
                        let task = command.split(separator: "\"", maxSplits: 1).dropFirst().first.map { String($0.prefix(80)) } ?? "side task"
                        events.append(.subagentStarted(Subagent(id: id, type: "Codex", task: task)))
                        events.append(.log(.command, "$ " + CLIText.clip(command, lines: 3), agent: id))
                        break
                    }
                    if name == "AskUserQuestion" { break } // shown as a decision card
                    if name == "TodoWrite", agent == nil, let todos = input["todos"] as? [[String: Any]] {
                        let plan = todos.compactMap { todo -> RunPlanStep? in
                            guard let text = todo["content"] as? String, !text.isEmpty else { return nil }
                            let status: RunPlanStep.Status
                            switch todo["status"] as? String {
                            case "completed": status = .done
                            case "in_progress": status = .active
                            default: status = .pending
                            }
                            return RunPlanStep(text: text, status: status)
                        }
                        events.append(.plan(plan))
                    }
                    var step = claudeStep(id: id, name: name, input: input)
                    step.agentID = agent
                    events.append(.step(step))
                    if let agent { events.append(.subagentActivity(id: agent, current: "\(step.label) \(step.detail)")) }
                    events.append(.log(.tool, "\(name) \(CLIText.describe(input))", agent: agent))
                    if step.kind == .edit {
                        let path = input["file_path"] as? String
                        pendingEdits[id] = (name, input, name == "Write" ? path.flatMap(EditPreview.read) : nil)
                    }
                default:
                    break
                }
            }
        case "user":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                let failed = block["is_error"] as? Bool ?? false
                let id = block["tool_use_id"] as? String ?? ""
                let output = CLIText.resultText(block["content"])
                if subagentIDs.contains(id) {
                    events.append(.subagentFinished(id: id, failed: failed))
                    events.append(.log(failed ? .error : .result, failed ? "subagent failed" : "subagent done", agent: id))
                    continue
                }
                if !id.isEmpty { events.append(.stepFinished(id: id, failed: failed)) }
                if let edit = pendingEdits.removeValue(forKey: id), !failed,
                   let change = Self.fileChange(id: id, tool: edit.tool, input: edit.input, before: edit.before) {
                    events.append(.fileChange(change))
                }
                if !output.isEmpty { events.append(.log(failed ? .error : .output, CLIText.clip(output, lines: 14), agent: agent)) }
            }
        case "result":
            finished = true
            if let id = o["session_id"] as? String { events.append(.session(id)) }
            let usage = o["usage"] as? [String: Any] ?? [:]
            let input = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            events.append(.runInfo(TerminalRunPatch(turns: o["num_turns"] as? Int, costUSD: o["total_cost_usd"] as? Double,
                                                    inputTokens: input > 0 ? input : nil, outputTokens: usage["output_tokens"] as? Int)))
            let seconds = Double(o["duration_ms"] as? Int ?? 0) / 1000
            let isError = o["is_error"] as? Bool == true
            events.append(.log(.result, String(format: "%@ in %.1fs · %d turn(s)", isError ? "failed" : "done",
                                               seconds, o["num_turns"] as? Int ?? 0)))
            // Read-only chats, and what auto mode's safety check refused: a card the user can act on.
            var seen: Set<String> = []
            for denial in o["permission_denials"] as? [[String: Any]] ?? [] {
                let tool = denial["tool_name"] as? String ?? ""
                let input = denial["tool_input"] as? [String: Any] ?? [:]
                events.append(.log(.info, "refused: \(tool) \(CLIText.describe(input))"))
                guard level == .readOnly || level == .auto, !tool.isEmpty, tool != "AskUserQuestion" else { continue }
                let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
                let request = permissionRequest(id: denial["tool_use_id"] as? String ?? UUID().uuidString,
                                                tool: tool, input: input, data: data, live: false)
                guard !askedLive.contains(request.tool + request.summary),
                      seen.insert(request.tool + request.summary).inserted else { continue }
                events.append(.permissionRequest(request))
            }
            let subtype = o["subtype"] as? String ?? "success"
            if isError, !sawText, let result = o["result"] as? String {
                failure = result
            } else if subtype != "success" {
                events.append(.warning(Self.resultWarning(subtype)))
            }
        default:
            break
        }
        return events
    }

    private static func resultWarning(_ subtype: String) -> String {
        switch subtype {
        case "error_max_turns": "Stopped early: the agent reached its turn limit. Ask it to continue."
        case "error_max_budget_usd": "Stopped early: the spending limit was reached."
        case "error_during_execution": "The agent hit an error and stopped before finishing."
        default: "The agent stopped before finishing (\(subtype.replacingOccurrences(of: "_", with: " ")))."
        }
    }

    private func permissionRequest(id: String, tool: String, input: [String: Any], data: Data, live: Bool) -> PermissionRequest {
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String
        var request = PermissionRequest(id: id, tool: tool, summary: "", filePath: path, live: live, input: data)
        if request.isEdit, let path {
            request.summary = relative(path)
            if let texts = EditPreview.texts(tool: tool, input: input, current: EditPreview.read(path)) {
                request.hunks = LineDiff.hunks(old: texts.before, new: texts.after)
                let counts = LineDiff.counts(request.hunks)
                request.added = counts.added
                request.removed = counts.removed
            }
        } else {
            request.summary = CLIText.describe(input)
        }
        return request
    }

    private static func question(id: String, input: [String: Any], data: Data) -> AgentQuestion? {
        let items = (input["questions"] as? [[String: Any]] ?? []).compactMap { q -> AgentQuestion.Item? in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentQuestion.Option? in
                guard let label = option["label"] as? String else { return nil }
                return AgentQuestion.Option(label: label, detail: option["description"] as? String ?? "")
            }
            return AgentQuestion.Item(question: text, header: q["header"] as? String ?? "", options: options,
                                      multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        return items.isEmpty ? nil : AgentQuestion(id: id, items: items, input: data)
    }

    /// The change an edit tool just made, worked out from the file as it is now.
    private static func fileChange(id: String, tool: String, input: [String: Any], before: String?) -> FileChange? {
        guard let path = input["file_path"] as? String ?? input["notebook_path"] as? String else { return nil }
        var change = FileChange(id: id, path: path)
        let now = EditPreview.read(path)
        if tool == "Write" {
            change.kind = before == nil ? .created : .modified
            change.hunks = LineDiff.hunks(old: before ?? "", new: now ?? (input["content"] as? String ?? ""))
        } else if let texts = EditPreview.reversed(tool: tool, input: input, current: now) {
            change.hunks = LineDiff.hunks(old: texts.before, new: texts.after)
        }
        let counts = LineDiff.counts(change.hunks)
        change.added = counts.added
        change.removed = counts.removed
        return change
    }

    private func claudeStep(id: String, name: String, input: [String: Any]) -> ToolStep {
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String
        switch name {
        case "Read":
            return ToolStep(id: id, kind: .read, label: "Read", detail: relative(path ?? ""), done: false, filePath: path)
        case "Grep", "Glob":
            let pattern = input["pattern"] as? String ?? ""
            return ToolStep(id: id, kind: .search, label: "Searched", detail: pattern, done: false)
        case "Bash":
            let command = input["command"] as? String ?? ""
            return ToolStep(id: id, kind: .command, label: "Ran", detail: String(command.prefix(120)), done: false)
        case _ where PermissionRequest.editTools.contains(name):
            return ToolStep(id: id, kind: .edit, label: "Edit", detail: relative(path ?? ""), done: false, filePath: path)
        case "LS":
            return ToolStep(id: id, kind: .read, label: "Listed", detail: relative(input["path"] as? String ?? "."), done: false)
        default:
            return ToolStep(id: id, kind: .other, label: name, detail: "", done: false)
        }
    }
}
