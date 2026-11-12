import Foundation

/// Codex (`codex`). Verified against codex-cli 0.167.
///
/// `exec --json -C <dir> --sandbox read-only|workspace-write`. `exec` never asks; a refused patch shows up as a
/// failed `file_change` item. Allow → `exec resume <thread> -c sandbox_mode="workspace-write"`.
struct CodexAgent: CLIAgent {
    let kind = ProviderKind.codex
    let executableName = "codex"

    func signInStatus(executable exe: String, environment env: [String: String]) async -> ProviderStatus {
        let result = await CLIRunner.runCapture(exe, ["login", "status"], env: env, timeout: 10)
        let text = result.output + result.error
        if result.status == 0, text.localizedCaseInsensitiveContains("logged in") { return .ready("codex CLI found · signed in") }
        return .notSignedIn("codex found · not signed in (run `codex login`)")
    }

    func arguments(for request: CLIRunner.Request) -> [String] {
        var prompt = request.prompt
        if request.sessionID == nil, let system = request.systemAppend, !system.isEmpty {
            prompt = "\(system)\n\n---\n\n\(request.prompt)"
        }
        let mode = request.level == .acceptEdits ? "workspace-write" : "read-only"
        // `-i` takes several values, so the prompt goes after `--`.
        let images = request.images.flatMap { ["-i", $0] }
        // Reaching Claude Code from inside Codex's sandbox needs the network; only with edits allowed.
        let network = request.delegate && request.level == .acceptEdits ? ["-c", "sandbox_workspace_write.network_access=true"] : []
        if let id = request.sessionID {
            let args = ["exec", "resume", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"\(mode)\""] + network
            return args + images + ["--", id, prompt]
        }
        return ["exec", "--json", "-C", request.folder.path, "--skip-git-repo-check", "--sandbox", mode] + network + images + ["--", prompt]
    }

    /// Codex should use its own sign-in, not a key the app happened to inherit.
    func adjust(environment: inout [String: String]) {
        environment["OPENAI_API_KEY"] = nil
    }

    func makeParser(for request: CLIRunner.Request) -> any CLIParser {
        CodexParser(folder: request.folder.path)
    }

    func delegateInstructions(level: PermissionLevel) -> String? {
        // Claude Code needs the network and its sign-in, which Codex's read-only sandbox blocks.
        guard level == .acceptEdits else { return nil }
        return """
        You can hand self-contained, read-only side tasks to Claude Code, another coding agent on this Mac, to save your own context: broad code searches, reading and summarising many files, a second opinion on a diff. Run it from the shell, exactly in this form (allow up to 10 minutes): claude -p "<a complete, standalone task that says what to report back>" --permission-mode dontAsk --allowedTools Read,Grep,Glob,LS
        Claude Code starts with no knowledge of this conversation and cannot edit files there. Use it only when it saves real work, check what it reports before relying on it, and do the editing yourself.
        """
    }

    /// Codex has no live prompt, so the retry runs with a writable sandbox.
    func retry(afterApproving what: String) -> ApprovedRetry {
        ApprovedRetry(prompt: "The user allowed edits in this folder for this retry. Apply the proposed change (\(what)) and confirm in one sentence. Make no other changes.",
                      level: .acceptEdits, asksAgain: false)
    }
}

/// Reads `codex exec --json` output.
struct CodexParser: CLIParser {
    let folder: String
    private(set) var producedOutput = false
    private(set) var failure: String?
    private(set) var turnStarted = false
    /// A refused patch was already offered as a card.
    private(set) var reportedBlockedEdits = false
    private var pendingSessionID: String?
    private var sawText = false
    private var changedFiles: [(path: String, kind: String)] = []
    private var textByItem: [String: String] = [:]
    private var reasoningByItem: [String: String] = [:]
    private var commandOutputByItem: [String: String] = [:]

    init(folder: String) {
        self.folder = folder
    }

    mutating func parse(_ line: String) -> [ProviderEvent] {
        guard let (type, object) = CLIText.typed(line) else { return [] }
        let events = events(type, object)
        if events.contains(where: { !$0.isTelemetry }) { producedOutput = true }
        return events
    }

    /// Files patched since the last call. Codex reports paths only; their diffs are read from git in `followUp`.
    mutating func takeChangedFiles() -> [(path: String, kind: String)] {
        defer { changedFiles = [] }
        return changedFiles
    }

    mutating func followUp(in folder: URL) async -> [ProviderEvent] {
        let changed = takeChangedFiles()
        guard !changed.isEmpty else { return [] }
        return await Self.changes(changed, folder: folder).map { .fileChange($0) }
    }

    /// Older Codex builds only report a refused patch on stderr.
    func afterExit(stderr: String) -> [ProviderEvent] {
        guard !reportedBlockedEdits, stderr.contains("patch rejected") || stderr.contains("read-only sandbox") else { return [] }
        return [.permissionRequest(.folderEdits)]
    }

    private func relative(_ path: String) -> String {
        FolderDrop.relative(path, to: folder) ?? path
    }

    private mutating func events(_ type: String, _ o: [String: Any]) -> [ProviderEvent] {
        switch type {
        case "thread.started":
            if let id = o["thread_id"] as? String {
                pendingSessionID = id
                return [.log(.info, "thread \(id.prefix(8))")]
            }
        case "turn.started":
            turnStarted = true
            var events: [ProviderEvent] = []
            if let id = pendingSessionID { events.append(.session(id)) }
            events += [.runInfo(TerminalRunPatch(turnStarted: true)), .log(.info, "Agent is working…")]
            return events
        case "turn.completed":
            let usage = o["usage"] as? [String: Any] ?? [:]
            return [.runInfo(TerminalRunPatch(inputTokens: usage["input_tokens"] as? Int, outputTokens: usage["output_tokens"] as? Int)),
                    .log(.result, "turn done · \(usage["input_tokens"] as? Int ?? 0) in / \(usage["output_tokens"] as? Int ?? 0) out tokens")]
        case "turn.failed":
            failure = ((o["error"] as? [String: Any])?["message"] as? String) ?? "Codex turn failed."
            return [.log(.error, failure ?? "")]
        case "error":
            if let message = o["message"] as? String {
                if failure == nil { failure = message }
                return [.log(.error, message)]
            }
        case "item.started", "item.updated", "item.completed":
            guard let item = o["item"] as? [String: Any], let itemType = item["type"] as? String else { return [] }
            let id = item["id"] as? String ?? UUID().uuidString
            let completed = type == "item.completed"
            switch itemType {
            case "reasoning":
                if type == "item.started" { return [.log(.info, "Thinking…")] }
                let value = item["text"] as? String ?? ""
                let previous = reasoningByItem[id] ?? ""
                let delta = value.hasPrefix(previous) ? String(value.dropFirst(previous.count)) : value
                reasoningByItem[id] = value
                if completed { reasoningByItem.removeValue(forKey: id) }
                return delta.isEmpty ? [] : [.log(.info, "thinking: " + CLIText.clip(delta, lines: 6))]
            case "agent_message":
                if type == "item.started" { return [.log(.info, "Writing response…")] }
                let value = item["text"] as? String ?? ""
                let previous = textByItem[id] ?? ""
                let delta = value.hasPrefix(previous) ? String(value.dropFirst(previous.count)) : value
                textByItem[id] = value
                if completed { textByItem.removeValue(forKey: id) }
                if delta.isEmpty { return [] }
                var events: [ProviderEvent] = []
                if previous.isEmpty, sawText { events.append(.textBlockBreak) }
                sawText = true
                events.append(.text(delta))
                return events
            case "command_execution":
                var command = item["command"] as? String ?? ""
                if command.hasPrefix("/bin/zsh -lc ") {
                    command = String(command.dropFirst(13)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                let exit = item["exit_code"] as? Int ?? 0
                let step = ToolStep(id: id, kind: command.hasPrefix("rg") || command.hasPrefix("grep") ? .search : .command,
                                    label: "Ran", detail: String(command.prefix(120)), done: completed,
                                    failed: completed && exit != 0)
                var events: [ProviderEvent] = type == "item.updated" ? [] : [.step(step)]
                let output = item["aggregated_output"] as? String ?? item["output"] as? String ?? ""
                let previous = commandOutputByItem[id] ?? ""
                let delta = output.hasPrefix(previous) ? String(output.dropFirst(previous.count)) : output
                commandOutputByItem[id] = output
                if !delta.isEmpty { events.append(.log(completed && exit != 0 ? .error : .output, CLIText.clip(delta, lines: 14))) }
                if completed {
                    commandOutputByItem.removeValue(forKey: id)
                    if exit != 0 { events.append(.log(.error, "exit \(exit)")) }
                } else if type == "item.started" {
                    events.append(.log(.tool, "$ " + command))
                }
                return events
            case "file_change":
                if type == "item.updated" { return [] }
                let changes = item["changes"] as? [[String: Any]] ?? []
                let paths = changes.compactMap { $0["path"] as? String }
                let failed = (item["status"] as? String) == "failed"
                let step = ToolStep(id: id, kind: .edit, label: failed ? "Wants to edit" : "Edited",
                                    detail: paths.map(relative).joined(separator: ", "),
                                    done: completed, filePath: paths.first)
                var events: [ProviderEvent] = [.step(step)]
                if completed {
                    let kinds = changes.map { "\($0["kind"] as? String ?? "update") \(relative($0["path"] as? String ?? ""))" }
                    events.append(.log(failed ? .error : .tool, (failed ? "patch refused: " : "patch: ") + kinds.joined(separator: ", ")))
                    if failed {
                        // The read-only sandbox refused the patch: offer to allow edits.
                        if !reportedBlockedEdits { events.append(.permissionRequest(PermissionRequest.folderEdits)) }
                        reportedBlockedEdits = true
                    } else {
                        changedFiles += changes.compactMap { change in
                            (change["path"] as? String).map { ($0, change["kind"] as? String ?? "update") }
                        }
                    }
                }
                return events
            case "mcp_tool_call":
                guard type != "item.updated" else { return [] }
                let server = item["server"] as? String ?? "MCP"
                let tool = item["tool"] as? String ?? "tool"
                if let error = (item["error"] as? [String: Any])?["message"] as? String, completed {
                    return [.log(.error, "\(server).\(tool): \(error)")]
                }
                return [.log(.tool, "\(server).\(tool) \(completed ? "finished" : "started")")]
            case "web_search":
                guard type == "item.started" else { return [] }
                let query = item["query"] as? String ?? ""
                return [.log(.tool, "Web search: \(query)")]
            default:
                return []
            }
        default:
            break
        }
        return []
    }

    /// Diffs for files Codex just patched, read from git (Codex reports paths only).
    private static func changes(_ changed: [(path: String, kind: String)], folder: URL) async -> [FileChange] {
        let paths = changed.map(\.path)
        let result = await CLIRunner.runCapture("/usr/bin/git", ["-C", folder.path, "diff", "--no-ext-diff", "--no-textconv", "--"] + paths, timeout: 8)
        let parsed = result.status == 0 ? LineDiff.parseUnified(result.output) : []
        return changed.map { item in
            let relative = FolderDrop.relative(item.path, to: folder.path) ?? item.path
            var change = FileChange(id: "codex-" + item.path, path: item.path,
                                    kind: item.kind == "add" ? .created : (item.kind == "delete" ? .deleted : .modified))
            if let match = parsed.first(where: { $0.path == relative || item.path.hasSuffix("/" + $0.path) }) {
                change.hunks = match.hunks
            } else if item.kind == "add", let text = EditPreview.read(item.path) {
                change.hunks = LineDiff.hunks(old: "", new: text) // new files aren't in `git diff`
            }
            let counts = LineDiff.counts(change.hunks)
            change.added = counts.added
            change.removed = counts.removed
            return change
        }
    }
}
