import Foundation

/// Runs `claude` / `codex` as child processes in a project folder and maps their JSON lines to ProviderEvents.
///
/// Verified flags (claude 2.1.x, codex-cli 0.166):
/// - Claude: `-p … --output-format stream-json --verbose --permission-mode dontAsk --allowedTools …`.
///   Unapproved tools are refused, and the final `result` event lists `permission_denials` with the tool input.
///   Allow → `--resume <session> --permission-mode acceptEdits`.
/// - Codex: `exec --json -C <dir> --sandbox read-only --skip-git-repo-check`; a refused patch is only reported on stderr.
///   Allow → `exec resume <thread> --json -c sandbox_mode="workspace-write"`.
enum CLIRunner {
    struct Request: Sendable {
        var kind: ProviderKind
        var folder: URL
        var prompt: String
        var sessionID: String?
        var systemAppend: String?
        var allowEdits: Bool
    }

    /// Read-only tools Claude may use without asking.
    static let claudeReadOnlyTools = "Read Grep Glob LS Bash(git status:*) Bash(git log:*) Bash(git diff:*) Bash(ls:*) Bash(swift build:*)"

    final class Handle: @unchecked Sendable {
        fileprivate let process = Process()
        func interrupt() { if process.isRunning { process.interrupt() } }
    }

    // MARK: Discovery

    private static let pathCache = PathCache()

    /// The user's login-shell PATH: GUI apps don't inherit it, and both CLIs often live in ~/.local/bin.
    static func loginPATH() async -> String {
        if let cached = await pathCache.path { return cached }
        let output = await runCapture("/bin/zsh", ["-lc", "printf %s \"$PATH\""], timeout: 5).output
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var parts = output.split(separator: ":").map(String.init)
        for extra in extras where !parts.contains(extra) { parts.append(extra) }
        let path = parts.joined(separator: ":")
        await pathCache.set(path)
        return path
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
                    guard let exe = await executable(for: request.kind) else {
                        throw ProviderError.notInstalled(request.kind.displayName)
                    }
                    let process = handle.process
                    process.executableURL = URL(fileURLWithPath: exe)
                    process.arguments = arguments(for: request)
                    process.currentDirectoryURL = request.folder
                    var env = ProcessInfo.processInfo.environment
                    env["PATH"] = await loginPATH()
                    process.environment = env
                    process.standardInput = FileHandle.nullDevice
                    let out = Pipe(), err = Pipe()
                    process.standardOutput = out
                    process.standardError = err

                    let stderrTask = Task.detached { () -> String in
                        String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    }
                    try process.run()

                    var parser = LineParser(kind: request.kind, folder: request.folder.path)
                    for try await line in out.fileHandleForReading.bytes.lines {
                        for event in parser.parse(line) { continuation.yield(event) }
                    }
                    process.waitUntilExit()
                    let stderr = await stderrTask.value

                    if request.kind == .codex, stderr.contains("patch rejected") || stderr.contains("read-only sandbox") {
                        continuation.yield(.editsBlocked)
                    }
                    if process.terminationReason == .uncaughtSignal || process.terminationStatus == 130 {
                        continuation.finish() // stopped by the user (⌘.)
                        return
                    }
                    if process.terminationStatus != 0, !parser.producedOutput {
                        let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
                        throw ProviderError.process(tail.isEmpty ? "\(request.kind.displayName) exited with code \(process.terminationStatus)." : tail)
                    }
                    if let failure = parser.failure { throw ProviderError.process(failure) }
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

    static func arguments(for request: Request) -> [String] {
        switch request.kind {
        case .claudeCode:
            var args = ["-p", request.prompt, "--output-format", "stream-json", "--verbose",
                        "--permission-mode", request.allowEdits ? "acceptEdits" : "dontAsk",
                        "--allowedTools", claudeReadOnlyTools]
            if let id = request.sessionID { args += ["--resume", id] }
            if let system = request.systemAppend, !system.isEmpty { args += ["--append-system-prompt", system] }
            return args
        case .codex:
            var prompt = request.prompt
            if request.sessionID == nil, let system = request.systemAppend, !system.isEmpty {
                prompt = "\(system)\n\n---\n\n\(request.prompt)"
            }
            if let id = request.sessionID {
                var args = ["exec", "resume", id, "--json", "--skip-git-repo-check"]
                if request.allowEdits { args += ["-c", "sandbox_mode=\"workspace-write\""] }
                return args + [prompt]
            }
            return ["exec", "--json", "-C", request.folder.path, "--skip-git-repo-check",
                    "--sandbox", request.allowEdits ? "workspace-write" : "read-only", prompt]
        case .openRouter:
            return []
        }
    }

    // MARK: Parsing

    struct LineParser {
        let kind: ProviderKind
        let folder: String
        var producedOutput = false
        var failure: String?
        private var sawText = false

        init(kind: ProviderKind, folder: String) {
            self.kind = kind
            self.folder = folder
        }

        mutating func parse(_ line: String) -> [ProviderEvent] {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return [] }
            let events = kind == .claudeCode ? parseClaude(type, object) : parseCodex(type, object)
            if !events.isEmpty { producedOutput = true }
            return events
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
            switch type {
            case "system":
                if o["subtype"] as? String == "init", let id = o["session_id"] as? String { events.append(.session(id)) }
            case "assistant":
                let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content {
                    switch block["type"] as? String {
                    case "text":
                        events += text(block["text"] as? String ?? "")
                    case "tool_use":
                        let id = block["id"] as? String ?? UUID().uuidString
                        let name = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        events.append(.step(claudeStep(id: id, name: name, input: input)))
                    default:
                        break
                    }
                }
            case "user":
                let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content where block["type"] as? String == "tool_result" {
                    if let id = block["tool_use_id"] as? String {
                        events.append(.stepFinished(id: id, failed: block["is_error"] as? Bool ?? false))
                    }
                }
            case "result":
                if let id = o["session_id"] as? String { events.append(.session(id)) }
                for denial in o["permission_denials"] as? [[String: Any]] ?? [] {
                    let tool = denial["tool_name"] as? String ?? ""
                    guard ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool) else { continue }
                    let input = denial["tool_input"] as? [String: Any] ?? [:]
                    let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? "file"
                    var oldText = input["old_string"] as? String ?? ""
                    var newText = input["new_string"] as? String ?? input["content"] as? String ?? ""
                    if let edits = input["edits"] as? [[String: Any]] {
                        oldText = edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n…\n")
                        newText = edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n…\n")
                    }
                    events.append(.editRequest(EditRequest(id: denial["tool_use_id"] as? String ?? UUID().uuidString,
                                                           filePath: path, oldText: oldText, newText: newText)))
                }
                if o["is_error"] as? Bool == true, !sawText, let result = o["result"] as? String { failure = result }
            default:
                break
            }
            return events
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
                if let id = o["thread_id"] as? String { return [.session(id)] }
            case "turn.failed":
                failure = ((o["error"] as? [String: Any])?["message"] as? String) ?? "Codex turn failed."
            case "item.started", "item.completed":
                guard let item = o["item"] as? [String: Any], let itemType = item["type"] as? String else { return [] }
                let id = item["id"] as? String ?? UUID().uuidString
                let completed = type == "item.completed"
                switch itemType {
                case "agent_message":
                    return completed ? text(item["text"] as? String ?? "") : []
                case "command_execution":
                    var command = item["command"] as? String ?? ""
                    if command.hasPrefix("/bin/zsh -lc ") {
                        command = String(command.dropFirst(13)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                    let step = ToolStep(id: id, kind: command.hasPrefix("rg") || command.hasPrefix("grep") ? .search : .command,
                                        label: "Ran", detail: String(command.prefix(120)), done: completed,
                                        failed: completed && (item["exit_code"] as? Int ?? 0) != 0)
                    return [.step(step)]
                case "file_change":
                    let changes = item["changes"] as? [[String: Any]] ?? []
                    let paths = changes.compactMap { $0["path"] as? String }
                    let step = ToolStep(id: id, kind: .edit, label: "Edited", detail: paths.map(relative).joined(separator: ", "),
                                        done: completed, failed: (item["status"] as? String) == "failed", filePath: paths.first)
                    return [.step(step)]
                default:
                    return []
                }
            default:
                break
            }
            return []
        }
    }

    // MARK: Helpers

    struct Captured: Sendable { var output: String; var error: String; var status: Int32 }

    static func runCapture(_ exe: String, _ args: [String], env: [String: String]? = nil, timeout: TimeInterval) async -> Captured {
        await Task.detached { () -> Captured in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            if let env {
                var merged = ProcessInfo.processInfo.environment
                merged.merge(env) { _, new in new }
                process.environment = merged
            }
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return Captured(output: "", error: error.localizedDescription, status: -1) }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let error = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Captured(output: String(decoding: output, as: UTF8.self), error: String(decoding: error, as: UTF8.self),
                            status: process.terminationStatus)
        }.value
    }
}

private actor PathCache {
    var path: String?
    func set(_ value: String) { path = value }
}
