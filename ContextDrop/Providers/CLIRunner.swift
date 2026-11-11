import Foundation
import Darwin

/// Runs `claude` / `codex` as child processes in a project folder and maps their JSON lines to ProviderEvents.
///
/// Verified against claude 2.1.322 and codex-cli 0.167:
/// - Claude: `-p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio`.
///   The prompt goes in on stdin as a JSON user message. When a tool needs a yes, the CLI pauses and writes a
///   `control_request` (`can_use_tool`) on stdout; we answer with a `control_response` on stdin (`Handle.respond`).
///   `AskUserQuestion` arrives the same way and is answered by returning the input with `answers` filled in.
///   Read-only chats use `--permission-mode dontAsk` instead: refused tools are listed in the final `permission_denials`.
/// - Codex: `exec --json -C <dir> --sandbox read-only|workspace-write`. `exec` never asks; a refused patch shows up as a
///   failed `file_change` item. Allow → `exec resume <thread> -c sandbox_mode="workspace-write"`.
enum CLIRunner {
    struct Request: Sendable {
        var kind: ProviderKind
        var folder: URL
        var prompt: String
        var sessionID: String?
        var systemAppend: String?
        var level: PermissionLevel
        /// Image files to show the agent with this prompt (screenshots). Must live in `Attachments.directory`.
        var images: [String] = []
        /// The other coding CLI is installed and the user lets this agent hand side tasks to it.
        var delegate = false
    }

    /// The only way Claude Code may start Codex without asking: read-only.
    static let codexDelegatePrefix = "codex exec --sandbox read-only --skip-git-repo-check"

    /// What the agent is told when delegation is on.
    static func delegateInstructions(for kind: ProviderKind, level: PermissionLevel) -> String? {
        switch kind {
        case .claudeCode:
            return """
            You can hand self-contained, read-only side tasks to Codex, another coding agent on this Mac, to save your own context:             broad code searches, reading and summarising many files, a second opinion on a diff. Run it with Bash, exactly in this form             (it is pre-approved; allow up to 10 minutes): \(codexDelegatePrefix) "<a complete, standalone task that says what to report back>"
            Codex starts with no knowledge of this conversation and cannot edit files. Use it only when it saves real work,             check what it reports before relying on it, and do the editing yourself.
            """
        case .codex:
            // Claude Code needs the network and its sign-in, which Codex's read-only sandbox blocks.
            guard level == .acceptEdits else { return nil }
            return """
            You can hand self-contained, read-only side tasks to Claude Code, another coding agent on this Mac, to save your own context:             broad code searches, reading and summarising many files, a second opinion on a diff. Run it from the shell, exactly in this form             (allow up to 10 minutes): claude -p "<a complete, standalone task that says what to report back>" --permission-mode dontAsk --allowedTools Read,Grep,Glob,LS
            Claude Code starts with no knowledge of this conversation and cannot edit files there. Use it only when it saves real work,             check what it reports before relying on it, and do the editing yourself.
            """
        case .openAI:
            return nil
        }
    }

    /// Read-only tools Claude may use without asking.
    static let claudeReadOnlyTools = ["Read", "Grep", "Glob", "LS", "Bash(git status:*)", "Bash(git log:*)", "Bash(git diff:*)", "Bash(ls:*)"]

    /// The running CLI: stop it, or answer what it asked.
    final class Handle: @unchecked Sendable {
        fileprivate let process = Process()
        private let lock = NSLock()
        private var input: FileHandle?
        private var cancelled = false
        private var launched = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        /// Called once the process is running. Returns false if Stop was pressed before launch.
        fileprivate func didLaunch(input: FileHandle?) -> Bool {
            lock.withLock {
                launched = true
                self.input = input
                return !cancelled
            }
        }

        fileprivate func write(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(10)
            lock.withLock { try? input?.write(contentsOf: data) }
        }

        fileprivate func closeInput() {
            lock.withLock {
                try? input?.close()
                input = nil
            }
        }

        /// Answers a paused permission request or question. `input` is the tool input to run with (JSON object).
        func respond(requestID: String, allow: Bool, input: Data = Data(), message: String? = nil) {
            var response: [String: Any]
            if allow {
                let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
                response = ["behavior": "allow", "updatedInput": object]
            } else {
                response = ["behavior": "deny", "message": message ?? "The user declined this."]
            }
            write(["type": "control_response",
                   "response": ["subtype": "success", "request_id": requestID, "response": response]])
        }

        fileprivate func reject(requestID: String) {
            write(["type": "control_response",
                   "response": ["subtype": "error", "request_id": requestID, "error": "Not supported by ContextDrop."]])
        }

        /// Stops the CLI and everything it started (shell commands, MCP servers).
        func interrupt() {
            let wasLaunched = lock.withLock { () -> Bool in
                cancelled = true
                return launched
            }
            guard wasLaunched, process.isRunning else { return }
            let pid = process.processIdentifier
            DispatchQueue.global().async { [self] in
                let children = CLIRunner.descendants(of: pid)
                closeInput()
                process.terminate()
                for child in children { _ = kill(child, SIGTERM) }
                Thread.sleep(forTimeInterval: 2)
                for target in children + [pid] where kill(target, 0) == 0 {
                    if target == pid && !process.isRunning { continue }
                    _ = kill(target, SIGKILL)
                }
            }
        }
    }

    /// Every process below `pid`, found from one `ps` listing.
    fileprivate static func descendants(of pid: Int32) -> [Int32] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        var childrenByParent: [Int32: [Int32]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, let child = Int32(parts[0]), let parent = Int32(parts[1]) else { continue }
            childrenByParent[parent, default: []].append(child)
        }
        var found: [Int32] = []
        var queue = [pid]
        while let next = queue.popLast(), found.count < 500 {
            for child in childrenByParent[next] ?? [] where child != ps.processIdentifier {
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }

    /// Writing to a CLI that already exited must not kill the app.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    // MARK: Discovery

    private static let pathCache = PathCache()

    /// The user's login-shell PATH: GUI apps don't inherit it, and both CLIs often live in ~/.local/bin.
    static func loginPATH() async -> String {
        await pathCache.get()
    }

    static func executable(for kind: ProviderKind) async -> String? {
        let name = kind == .claudeCode ? "claude" : "codex"
        let path = await loginPATH()
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func status(for kind: ProviderKind) async -> ProviderStatus {
        let name = kind == .claudeCode ? "claude" : "codex"
        guard let exe = await executable(for: kind) else { return .notFound("\(name) CLI not found on this Mac") }
        let env = ["PATH": await loginPATH()]
        if kind == .claudeCode {
            let result = await runCapture(exe, ["auth", "status"], env: env, timeout: 10)
            if let data = result.output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["loggedIn"] as? Bool == true {
                return .ready("claude CLI found · signed in")
            }
            return .notSignedIn("claude found · not signed in (run `claude auth login`)")
        } else {
            let result = await runCapture(exe, ["login", "status"], env: env, timeout: 10)
            let text = result.output + result.error
            if result.status == 0, text.localizedCaseInsensitiveContains("logged in") { return .ready("codex CLI found · signed in") }
            return .notSignedIn("codex found · not signed in (run `codex login`)")
        }
    }

    // MARK: Running

    static func run(_ request: Request, handle: Handle) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    _ = ignoreSIGPIPE
                    continuation.yield(.log(.info, "Locating \(request.kind.displayName)…"))
                    guard let exe = await executable(for: request.kind) else {
                        throw ProviderError.notInstalled(request.kind.displayName)
                    }
                    try Task.checkCancellation()
                    let process = handle.process
                    let args = arguments(for: request)
                    process.executableURL = URL(fileURLWithPath: exe)
                    process.arguments = args
                    process.currentDirectoryURL = request.folder
                    var env = cliEnvironment()
                    env["PATH"] = await loginPATH()
                    // Codex should use its own sign-in, not a key the app happened to inherit.
                    if request.kind == .codex { env["OPENAI_API_KEY"] = nil }
                    try Task.checkCancellation()
                    process.environment = env
                    let usesInput = request.kind == .claudeCode
                    let input = Pipe(), out = Pipe(), err = Pipe()
                    process.standardInput = usesInput ? input : FileHandle.nullDevice
                    process.standardOutput = out
                    process.standardError = err

                    continuation.yield(.log(.command, "$ " + commandLine(exe: exe, args: args)))
                    continuation.yield(.log(.info, "cwd \((request.folder.path as NSString).abbreviatingWithTildeInPath)"
                        + (request.images.isEmpty ? "" : " · \(request.images.count) image(s) attached")))

                    let outLines = LineStream(out.fileHandleForReading)
                    let errLines = LineStream(err.fileHandleForReading)
                    // If something the CLI started keeps the pipes open, don't wait on them forever.
                    process.terminationHandler = { _ in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                            outLines.finish()
                            errLines.finish()
                        }
                    }
                    do {
                        try process.run()
                    } catch {
                        outLines.finish()
                        errLines.finish()
                        throw ProviderError.process("Couldn’t start \(request.kind.displayName): \(error.localizedDescription)")
                    }
                    guard handle.didLaunch(input: usesInput ? input.fileHandleForWriting : nil) else {
                        // Stop was pressed while we were still setting up.
                        handle.interrupt()
                        process.waitUntilExit()
                        continuation.finish()
                        return
                    }
                    if usesInput {
                        handle.write(["type": "user", "message": ["role": "user", "content": claudePrompt(for: request)]])
                    }

                    // stderr is streamed to the activity pane and kept for error messages.
                    let stderrTask = Task.detached { () -> String in
                        var collected = ""
                        for await line in errLines.stream {
                            if collected.count < 20_000 { collected += line + "\n" }
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty, trimmed != "Reading additional input from stdin..." {
                                continuation.yield(.log(.stderr, String(trimmed.prefix(600))))
                            }
                        }
                        return collected
                    }
                    continuation.yield(.runInfo(TerminalRunPatch(pid: process.processIdentifier, permissionMode: request.level.chip)))
                    continuation.yield(.log(.info, "Process \(process.processIdentifier) started · waiting for agent output…"))

                    var parser = LineParser(kind: request.kind, folder: request.folder.path, level: request.level)
                    let startup = StartupGate()
                    let watchdog = Task.detached {
                        try? await Task.sleep(for: .seconds(120))
                        guard !Task.isCancelled, handle.process.isRunning,
                              await startup.timeoutIfPending() else { return }
                        continuation.yield(.log(.error, "\(request.kind.displayName) did not start a turn within 2 minutes. Check its CLI configuration and connected tools."))
                        handle.interrupt()
                    }
                    var lastActivity = Date.distantPast
                    for await line in outLines.stream {
                        if await startup.timedOut { break }
                        if Date().timeIntervalSince(lastActivity) >= 1 {
                            lastActivity = Date()
                            continuation.yield(.runInfo(TerminalRunPatch(lastEventAt: lastActivity)))
                        }
                        if !line.contains("\"type\":\"stream_event\"") { continuation.yield(.raw(line)) }
                        let events = parser.parse(line)
                        if parser.turnStarted {
                            await startup.markStarted()
                            watchdog.cancel()
                        }
                        for event in events { continuation.yield(event) }
                        for id in parser.takeUnsupportedRequests() { handle.reject(requestID: id) }
                        let changed = parser.takeCodexChanges()
                        if !changed.isEmpty {
                            for change in await codexChanges(changed, folder: request.folder) { continuation.yield(.fileChange(change)) }
                        }
                        // The answer is complete: let the CLI exit instead of waiting for more input.
                        if parser.finished { handle.closeInput() }
                    }
                    watchdog.cancel()
                    handle.closeInput()
                    process.waitUntilExit()
                    let stderr = await stderrTask.value
                    if await startup.timedOut { throw ProviderError.process("\(request.kind.displayName) did not start a turn within 2 minutes. Check its CLI configuration and connected tools, then retry.") }
                    let interrupted = handle.isCancelled || process.terminationReason == .uncaughtSignal || process.terminationStatus == 130
                    continuation.yield(.runInfo(TerminalRunPatch(exitCode: process.terminationStatus, interrupted: interrupted)))
                    continuation.yield(.log(interrupted ? .info : (process.terminationStatus == 0 ? .result : .error),
                                            interrupted ? "stopped" : "exited with code \(process.terminationStatus)"))

                    // Older Codex builds only report a refused patch on stderr.
                    if request.kind == .codex, !parser.reportedBlockedEdits,
                       stderr.contains("patch rejected") || stderr.contains("read-only sandbox") {
                        continuation.yield(.permissionRequest(LineParser.codexEditRequest))
                    }
                    if interrupted {
                        continuation.finish() // stopped by the user (⌘.)
                        return
                    }
                    if process.terminationStatus != 0, !parser.producedOutput {
                        let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
                        throw ProviderError.process(tail.isEmpty ? "\(request.kind.displayName) exited with code \(process.terminationStatus)." : tail)
                    }
                    if let failure = parser.failure { throw ProviderError.process(failure) }
                    if process.terminationStatus != 0 {
                        continuation.yield(.warning("\(request.kind.displayName) exited with code \(process.terminationStatus) before finishing."))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                handle.interrupt()
                task.cancel()
            }
        }
    }

    /// The text Claude is asked, with attached images listed for its Read tool.
    static func claudePrompt(for request: Request) -> String {
        guard !request.images.isEmpty else { return request.prompt }
        return request.prompt + "\n\nAttached image(s). Open each with the Read tool before answering:\n"
            + request.images.map { "- \($0)" }.joined(separator: "\n")
    }

    static func arguments(for request: Request) -> [String] {
        switch request.kind {
        case .claudeCode:
            // The prompt is sent on stdin, so it can start with "-", be long, and stays out of `ps`.
            var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--include-partial-messages", "--forward-subagent-text"]
            switch request.level {
            case .readOnly: args += ["--permission-mode", "dontAsk"]
            case .ask: args += ["--permission-prompt-tool", "stdio", "--permission-mode", "manual"]
            case .acceptEdits: args += ["--permission-prompt-tool", "stdio", "--permission-mode", "acceptEdits"]
            }
            args += ["--allowedTools"] + claudeReadOnlyTools + (request.delegate ? ["Bash(\(codexDelegatePrefix):*)"] : [])
            if !request.images.isEmpty { args += ["--add-dir", Attachments.directory.path] }
            if let id = request.sessionID { args += ["--resume", id] }
            if let system = request.systemAppend, !system.isEmpty { args += ["--append-system-prompt", system] }
            return args
        case .codex:
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
        case .openAI:
            return []
        }
    }

    /// Diffs for files Codex just patched, read from git (Codex reports paths only).
    private static func codexChanges(_ changed: [(path: String, kind: String)], folder: URL) async -> [FileChange] {
        let paths = changed.map(\.path)
        let result = await runCapture("/usr/bin/git", ["-C", folder.path, "diff", "--no-ext-diff", "--no-textconv", "--"] + paths, timeout: 8)
        let parsed = result.status == 0 ? LineDiff.parseUnified(result.output) : []
        return changed.map { item in
            let relative = item.path.hasPrefix(folder.path + "/") ? String(item.path.dropFirst(folder.path.count + 1)) : item.path
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

    /// Xcode and app hosts inject dynamic-loader and process-control variables that
    /// must not follow the GUI process into an unrelated CLI (or its tool children).
    private static func cliEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("DYLD_") && !key.hasPrefix("__XPC_") && !key.hasPrefix("__XCODE_")
                && !["XPC_FLAGS", "XPC_SERVICE_NAME", "__CFBundleIdentifier", "LLVM_PROFILE_FILE"].contains(key)
        }
    }

    /// Shell-like rendering of the command for the terminal pane (long arguments shortened).
    static func commandLine(exe: String, args: [String]) -> String {
        let name = (exe as NSString).lastPathComponent
        let parts = args.map { arg -> String in
            var a = arg.replacingOccurrences(of: "\n", with: " ")
            if a.count > 80 { a = String(a.prefix(77)) + "…" }
            return a.contains(where: { $0 == " " || $0 == "\"" || $0 == "(" }) ? "'\(a)'" : a
        }
        return ([name] + parts).joined(separator: " ")
    }

    // MARK: Parsing

    struct LineParser {
        let kind: ProviderKind
        let folder: String
        let level: PermissionLevel
        var producedOutput = false
        var failure: String?
        var turnStarted = false
        /// The final `result` arrived (Claude): nothing more will be asked.
        var finished = false
        var reportedBlockedEdits = false
        private var pendingCodexSessionID: String?
        private var sawText = false
        private var streamMessageID = ""
        private var streamedText: [String: [Int: String]] = [:]
        private var emittedText: [String: Set<String>] = [:]
        private var subagentIDs: Set<String> = []
        private var pendingEdits: [String: (tool: String, input: [String: Any], before: String?)] = [:]
        private var unsupportedRequests: [String] = []
        private var codexChanged: [(path: String, kind: String)] = []
        private var codexTextByItem: [String: String] = [:]
        private var codexReasoningByItem: [String: String] = [:]
        private var codexCommandOutputByItem: [String: String] = [:]

        static let codexEditRequest = PermissionRequest(id: "codex-edits", tool: "Edit", summary: "files in this folder", live: false)

        init(kind: ProviderKind, folder: String, level: PermissionLevel = .ask) {
            self.kind = kind
            self.folder = folder
            self.level = level
        }

        mutating func parse(_ line: String) -> [ProviderEvent] {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return [] }
            let events = kind == .claudeCode ? parseClaude(type, object) : parseCodex(type, object)
            if events.contains(where: { !$0.isTelemetry }) { producedOutput = true }
            return events
        }

        /// Control requests we don't handle: the runner answers them with an error so the CLI never waits.
        mutating func takeUnsupportedRequests() -> [String] {
            defer { unsupportedRequests = [] }
            return unsupportedRequests
        }

        /// Files Codex patched since the last call (the runner reads their diffs from git).
        mutating func takeCodexChanges() -> [(path: String, kind: String)] {
            defer { codexChanged = [] }
            return codexChanged
        }

        private func relative(_ path: String) -> String {
            path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
        }

        private mutating func text(_ value: String) -> [ProviderEvent] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            defer { sawText = true }
            return sawText ? [.textBlockBreak, .text(trimmed)] : [.text(trimmed)]
        }

        private mutating func parseClaude(_ type: String, _ o: [String: Any]) -> [ProviderEvent] {
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
                            if !value.isEmpty { events.append(.log(.info, Self.clip(value, lines: 8), agent: agent)) }
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
                            events.append(.log(.info, "thinking: " + Self.clip(value, lines: 6), agent: agent))
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
                            events.append(.log(.command, "$ " + Self.clip(command, lines: 3), agent: id))
                            break
                        }
                        if name == "AskUserQuestion" { break } // shown as a decision card
                        var step = claudeStep(id: id, name: name, input: input)
                        step.agentID = agent
                        events.append(.step(step))
                        if let agent { events.append(.subagentActivity(id: agent, current: "\(step.label) \(step.detail)")) }
                        events.append(.log(.tool, "\(name) \(Self.describe(input))", agent: agent))
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
                    let output = Self.resultText(block["content"])
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
                    if !output.isEmpty { events.append(.log(failed ? .error : .output, Self.clip(output, lines: 14), agent: agent)) }
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
                // Read-only chats: what was refused becomes a card the user can act on.
                var seen: Set<String> = []
                for denial in o["permission_denials"] as? [[String: Any]] ?? [] {
                    let tool = denial["tool_name"] as? String ?? ""
                    let input = denial["tool_input"] as? [String: Any] ?? [:]
                    events.append(.log(.info, "refused: \(tool) \(Self.describe(input))"))
                    guard level == .readOnly, !tool.isEmpty, tool != "AskUserQuestion" else { continue }
                    let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
                    let request = permissionRequest(id: denial["tool_use_id"] as? String ?? UUID().uuidString,
                                                    tool: tool, input: input, data: data, live: false)
                    guard seen.insert(request.tool + request.summary).inserted else { continue }
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
                request.summary = Self.describe(input)
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
            case "Edit", "Write", "MultiEdit", "NotebookEdit":
                return ToolStep(id: id, kind: .edit, label: "Edit", detail: relative(path ?? ""), done: false, filePath: path)
            case "LS":
                return ToolStep(id: id, kind: .read, label: "Listed", detail: relative(input["path"] as? String ?? "."), done: false)
            default:
                return ToolStep(id: id, kind: .other, label: name, detail: "", done: false)
            }
        }

        private mutating func parseCodex(_ type: String, _ o: [String: Any]) -> [ProviderEvent] {
            switch type {
            case "thread.started":
                if let id = o["thread_id"] as? String {
                    pendingCodexSessionID = id
                    return [.log(.info, "thread \(id.prefix(8))")]
                }
            case "turn.started":
                turnStarted = true
                var events: [ProviderEvent] = []
                if let id = pendingCodexSessionID { events.append(.session(id)) }
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
                    let previous = codexReasoningByItem[id] ?? ""
                    let delta = value.hasPrefix(previous) ? String(value.dropFirst(previous.count)) : value
                    codexReasoningByItem[id] = value
                    if completed { codexReasoningByItem.removeValue(forKey: id) }
                    return delta.isEmpty ? [] : [.log(.info, "thinking: " + Self.clip(delta, lines: 6))]
                case "agent_message":
                    if type == "item.started" { return [.log(.info, "Writing response…")] }
                    let value = item["text"] as? String ?? ""
                    let previous = codexTextByItem[id] ?? ""
                    let delta = value.hasPrefix(previous) ? String(value.dropFirst(previous.count)) : value
                    codexTextByItem[id] = value
                    if completed { codexTextByItem.removeValue(forKey: id) }
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
                    let previous = codexCommandOutputByItem[id] ?? ""
                    let delta = output.hasPrefix(previous) ? String(output.dropFirst(previous.count)) : output
                    codexCommandOutputByItem[id] = output
                    if !delta.isEmpty { events.append(.log(completed && exit != 0 ? .error : .output, Self.clip(delta, lines: 14))) }
                    if completed {
                        codexCommandOutputByItem.removeValue(forKey: id)
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
                            if !reportedBlockedEdits { events.append(.permissionRequest(Self.codexEditRequest)) }
                            reportedBlockedEdits = true
                        } else {
                            codexChanged += changes.compactMap { change in
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

        // MARK: Terminal text helpers

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

    // MARK: Helpers

    struct Captured: Sendable { var output: String; var error: String; var status: Int32 }

    static func runCapture(_ exe: String, _ args: [String], env: [String: String]? = nil, timeout: TimeInterval) async -> Captured {
        await withCheckedContinuation { (continuation: CheckedContinuation<Captured, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = args
                var merged = cliEnvironment()
                if let env { merged.merge(env) { _, new in new } }
                process.environment = merged
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    continuation.resume(returning: Captured(output: "", error: error.localizedDescription, status: -1))
                    return
                }
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if process.isRunning && process.processIdentifier == pid { _ = kill(pid, SIGKILL) }
                    }
                }
                // Drain both pipes at once: a full stderr pipe must not block stdout.
                let errorBox = DataBox()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) { errorBox.set(err.fileHandleForReading.readDataToEndOfFile()) }
                let output = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Captured(output: String(decoding: output, as: UTF8.self),
                                                        error: String(decoding: errorBox.get(), as: UTF8.self),
                                                        status: process.terminationStatus))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}

/// Lines from a pipe as they arrive. Reading happens on the file handle's own queue, never on a Swift-concurrency thread.
private final class LineStream: @unchecked Sendable {
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let handle: FileHandle
    private let lock = NSLock()
    private var pending = Data()
    private var finished = false

    init(_ handle: FileHandle) {
        self.handle = handle
        (stream, continuation) = AsyncStream.makeStream(of: String.self)
        handle.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { finish() } else { feed(data) }
        }
    }

    private func feed(_ data: Data) {
        lock.withLock {
            guard !finished else { return }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[pending.startIndex..<end])
                pending.removeSubrange(pending.startIndex...end)
                continuation.yield(String(decoding: line, as: UTF8.self))
            }
        }
    }

    /// End of output (or we stopped waiting for it). Safe to call more than once.
    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            handle.readabilityHandler = nil
            if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
            pending = Data()
            continuation.finish()
        }
    }
}

/// Works out what an edit tool will change (before it runs) or did change (after).
enum EditPreview {
    static let maxBytes = 600_000

    static func read(_ path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= maxBytes else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func edits(tool: String, input: [String: Any]) -> [(old: String, new: String, all: Bool)] {
        if let list = input["edits"] as? [[String: Any]] {
            return list.map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "", $0["replace_all"] as? Bool ?? false) }
        }
        return [(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "", input["replace_all"] as? Bool ?? false)]
    }

    private static func replace(_ text: String, _ old: String, _ new: String, all: Bool) -> String? {
        guard !old.isEmpty, let range = text.range(of: old) else { return nil }
        return all ? text.replacingOccurrences(of: old, with: new) : text.replacingCharacters(in: range, with: new)
    }

    /// Before/after of an edit that hasn't run yet. `current` is the file as it is now.
    static func texts(tool: String, input: [String: Any], current: String?) -> (before: String, after: String)? {
        if tool == "Write" { return (current ?? "", input["content"] as? String ?? "") }
        let list = edits(tool: tool, input: input)
        if let current {
            var after = current
            var applied = true
            for edit in list {
                if let next = replace(after, edit.old, edit.new, all: edit.all) { after = next } else { applied = false; break }
            }
            if applied { return (current, after) }
        }
        // The file couldn't be read or didn't match: show just the snippets.
        return (list.map(\.old).joined(separator: "\n"), list.map(\.new).joined(separator: "\n"))
    }

    /// Before/after of an edit that already ran, by undoing it on the file as it is now.
    static func reversed(tool: String, input: [String: Any], current: String?) -> (before: String, after: String)? {
        let list = edits(tool: tool, input: input)
        if let current {
            var before = current
            var undone = true
            for edit in list.reversed() {
                if let previous = replace(before, edit.new, edit.old, all: edit.all) { before = previous } else { undone = false; break }
            }
            if undone { return (before, current) }
        }
        return (list.map(\.old).joined(separator: "\n"), list.map(\.new).joined(separator: "\n"))
    }
}

private actor PathCache {
    var path: String?
    private var lookup: Task<String?, Never>?

    func get() async -> String {
        if let path { return path }
        if lookup == nil {
            lookup = Task {
                // An interactive login shell also reads .zshrc (nvm, asdf…). Markers skip anything the profile prints.
                for flags in ["-ilc", "-lc"] {
                    let output = await CLIRunner.runCapture("/bin/zsh", [flags, "printf '\\n__CDPATH__%s__CDEND__\\n' \"$PATH\""], timeout: 6).output
                    if let start = output.range(of: "__CDPATH__", options: .backwards),
                       let end = output.range(of: "__CDEND__", options: .backwards), start.upperBound <= end.lowerBound {
                        let found = String(output[start.upperBound..<end.lowerBound])
                        if !found.isEmpty { return found }
                    }
                }
                return nil
            }
        }
        let found = await lookup!.value
        lookup = nil
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parts = (found ?? "").split(separator: ":").map(String.init)
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !parts.contains(extra) {
            parts.append(extra)
        }
        let result = parts.joined(separator: ":")
        if found != nil { path = result } // a failed lookup is retried next time
        return result
    }
}

private actor StartupGate {
    private var started = false
    private(set) var timedOut = false

    func markStarted() { started = true }

    func timeoutIfPending() -> Bool {
        guard !started else { return false }
        timedOut = true
        return true
    }
}
