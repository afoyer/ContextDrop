import Foundation
import Darwin

/// Runs a coding agent's CLI as a child process in a project folder and streams `ProviderEvent`s.
///
/// Everything here is the same for every CLI: finding the executable on the login-shell PATH, a clean
/// environment, the pipes, stopping the process tree, the start-up watchdog and exit handling.
/// What differs per CLI (arguments, stdin, the JSON it prints) is behind `CLIAgent` / `CLIParser`:
/// see `ClaudeCodeAgent` and `CodexAgent`.
enum CLIRunner {
    struct Request: Sendable {
        var folder: URL
        var prompt: String
        var sessionID: String?
        var systemAppend: String?
        var level: PermissionLevel
        /// Image files to show the agent with this prompt (screenshots). Must live in `Attachments.directory`.
        var images: [String] = []
        /// Some of the non-image files the prompt lists live in `Attachments.directory` (pasted text, files sent
        /// with a room follow-up), so the agent needs that folder too.
        var filesInAttachments = false
        /// The other coding CLI is installed and the user lets this agent hand side tasks to it.
        var delegate = false
    }

    /// A running answer: stop it, or answer what the agent asked.
    /// `respond` speaks Claude Code's control protocol, the only CLI so far that pauses for an answer.
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

    static func executable(named name: String) async -> String? {
        let path = await loginPATH()
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Installed and signed in?
    static func status(of agent: any CLIAgent) async -> ProviderStatus {
        let name = agent.executableName
        guard let exe = await executable(named: name) else { return .notFound("\(name) CLI not found on this Mac") }
        return await agent.signInStatus(executable: exe, environment: ["PATH": await loginPATH()])
    }

    // MARK: Running

    /// Starts the agent's CLI in `request.folder` and streams what its parser makes of each output line.
    static func run(_ agent: any CLIAgent, _ request: Request, handle: Handle) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    _ = ignoreSIGPIPE
                    let name = agent.kind.displayName
                    continuation.yield(.log(.info, "Locating \(name)…"))
                    guard let exe = await executable(named: agent.executableName) else {
                        throw ProviderError.notInstalled(name)
                    }
                    try Task.checkCancellation()
                    let process = handle.process
                    let args = agent.arguments(for: request)
                    process.executableURL = URL(fileURLWithPath: exe)
                    process.arguments = args
                    process.currentDirectoryURL = request.folder
                    var env = cliEnvironment()
                    env["PATH"] = await loginPATH()
                    agent.adjust(environment: &env)
                    try Task.checkCancellation()
                    process.environment = env
                    let opening = agent.openingInput(for: request)
                    let usesInput = opening != nil
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
                        throw ProviderError.process("Couldn’t start \(name): \(error.localizedDescription)")
                    }
                    guard handle.didLaunch(input: usesInput ? input.fileHandleForWriting : nil) else {
                        // Stop was pressed while we were still setting up.
                        handle.interrupt()
                        process.waitUntilExit()
                        continuation.finish()
                        return
                    }
                    if let opening { handle.write(opening) }

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

                    var parser = agent.makeParser(for: request)
                    let startup = StartupGate()
                    let watchdog = Task.detached {
                        try? await Task.sleep(for: .seconds(120))
                        guard !Task.isCancelled, handle.process.isRunning,
                              await startup.timeoutIfPending() else { return }
                        continuation.yield(.log(.error, "\(name) did not start a turn within 2 minutes. Check its CLI configuration and connected tools."))
                        handle.interrupt()
                    }
                    var lastActivity = Date.distantPast
                    for await line in outLines.stream {
                        if await startup.timedOut { break }
                        if Date().timeIntervalSince(lastActivity) >= 1 {
                            lastActivity = Date()
                            continuation.yield(.runInfo(TerminalRunPatch(lastEventAt: lastActivity)))
                        }
                        if !parser.isNoise(line) { continuation.yield(.raw(line)) }
                        let events = parser.parse(line)
                        if parser.turnStarted {
                            await startup.markStarted()
                            watchdog.cancel()
                        }
                        for event in events { continuation.yield(event) }
                        for id in parser.takeUnsupportedRequests() { handle.reject(requestID: id) }
                        for event in await parser.followUp(in: request.folder) { continuation.yield(event) }
                        // The answer is complete: let the CLI exit instead of waiting for more input.
                        if parser.finished { handle.closeInput() }
                    }
                    watchdog.cancel()
                    handle.closeInput()
                    process.waitUntilExit()
                    let stderr = await stderrTask.value
                    if await startup.timedOut { throw ProviderError.process("\(name) did not start a turn within 2 minutes. Check its CLI configuration and connected tools, then retry.") }
                    let interrupted = handle.isCancelled || process.terminationReason == .uncaughtSignal || process.terminationStatus == 130
                    continuation.yield(.runInfo(TerminalRunPatch(exitCode: process.terminationStatus, interrupted: interrupted)))
                    continuation.yield(.log(interrupted ? .info : (process.terminationStatus == 0 ? .result : .error),
                                            interrupted ? "stopped" : "exited with code \(process.terminationStatus)"))

                    for event in parser.afterExit(stderr: stderr) { continuation.yield(event) }
                    if interrupted {
                        continuation.finish() // stopped by the user (⌘.)
                        return
                    }
                    if process.terminationStatus != 0, !parser.producedOutput {
                        let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
                        throw ProviderError.process(tail.isEmpty ? "\(name) exited with code \(process.terminationStatus)." : tail)
                    }
                    if let failure = parser.failure { throw ProviderError.process(failure) }
                    if process.terminationStatus != 0 {
                        continuation.yield(.warning("\(name) exited with code \(process.terminationStatus) before finishing."))
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
