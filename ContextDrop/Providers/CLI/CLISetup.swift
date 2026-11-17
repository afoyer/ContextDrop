import Foundation
import Darwin

/// One way to install a coding CLI: a shell command and the tool it needs first (`curl`, `brew`, `npm`).
struct CLIInstallOption: Sendable, Equatable {
    var label: String
    /// Executable that must be on the login PATH for this option to run. Nil = always available.
    var requires: String?
    var command: String
}

extension ClaudeCodeAgent {
    var installOptions: [CLIInstallOption] {
        [CLIInstallOption(label: "Anthropic’s installer", requires: "curl",
                          command: "curl -fsSL https://claude.ai/install.sh | bash")]
    }

    var signInArguments: [String] { ["auth", "login"] }
}

extension CodexAgent {
    /// Homebrew first: a global npm install often needs sudo, which a background install can't answer.
    var installOptions: [CLIInstallOption] {
        [CLIInstallOption(label: "Homebrew", requires: "brew", command: "brew install --cask codex"),
         CLIInstallOption(label: "npm", requires: "npm", command: "npm install -g @openai/codex")]
    }

    var signInArguments: [String] { ["login"] }
}

/// Installs and signs in coding CLIs for the setup window, without Terminal. Only the commands written in
/// each agent run here; nothing from the network or another Mac decides what is executed.
enum CLISetup {
    enum Outcome: Sendable, Equatable {
        case done
        case cancelled
        /// It ran and failed: the last lines it printed.
        case failed(String)
        /// Nothing this Mac has can run any of the agent's install options (no Homebrew or npm for Codex).
        case unavailable
    }

    /// The coding CLI behind a provider, or nil for one that isn't a CLI.
    static func agent(for kind: ProviderKind) -> (any CLIAgent)? {
        Providers.all.lazy.compactMap { ($0 as? CLIProvider)?.agent }.first { $0.kind == kind }
    }

    /// The first install option whose required tool this Mac has.
    static func installOption(for agent: any CLIAgent) async -> CLIInstallOption? {
        for option in agent.installOptions {
            guard let tool = option.requires else { return option }
            if await CLIRunner.executable(named: tool) != nil { return option }
        }
        return nil
    }

    /// What a person would type in Terminal instead: every install option, then the sign-in.
    static func manualCommands(for agent: any CLIAgent) -> String {
        var lines: [String] = []
        let options = agent.installOptions
        for (index, option) in options.enumerated() {
            lines.append(options.count > 1 && index > 0 ? "# or, with \(option.label):\n\(option.command)" : option.command)
        }
        if !agent.signInArguments.isEmpty {
            lines.append(([agent.executableName] + agent.signInArguments).joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    static func install(_ agent: any CLIAgent, job: SetupJob) async -> Outcome {
        guard let option = await installOption(for: agent) else { return .unavailable }
        let env = ["PATH": await CLIRunner.loginPATH()]
        // Installers can take a few minutes on a slow connection.
        let result = await job.run("/bin/zsh", ["-lc", option.command], env: env, timeout: 900)
        await CLIRunner.resetLoginPATH()
        if job.isCancelled { return .cancelled }
        guard result.status == 0, await CLIRunner.executable(named: agent.executableName) != nil else {
            return .failed(tail(result) ?? "The installer stopped without saying why.")
        }
        return .done
    }

    /// Starts the CLI's own sign-in, which opens the browser, and waits for it to finish.
    static func signIn(_ agent: any CLIAgent, job: SetupJob) async -> Outcome {
        guard !agent.signInArguments.isEmpty else { return .unavailable }
        guard let exe = await CLIRunner.executable(named: agent.executableName) else {
            return .failed("\(agent.executableName) isn’t installed yet.")
        }
        let env = ["PATH": await CLIRunner.loginPATH()]
        let result = await job.run(exe, agent.signInArguments, env: env, timeout: 300)
        if job.isCancelled { return .cancelled }
        guard result.status == 0 else { return .failed(tail(result) ?? "Sign-in didn’t finish.") }
        return .done
    }

    /// The last few lines a process printed, for an error message. Stderr goes last: that's where the reason is.
    static func tail(_ result: CLIRunner.Captured, lines count: Int = 3) -> String? {
        let lines = (result.output + "\n" + result.error)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return String(lines.suffix(count).joined(separator: "\n").prefix(400))
    }
}

/// One setup process (an install or a sign-in) that can be stopped from the UI.
final class SetupJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Stops the process. A cancelled job never starts one.
    func cancel() {
        let running = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        guard let running, running.isRunning else { return }
        running.terminate()
    }

    func run(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval) async -> CLIRunner.Captured {
        await withCheckedContinuation { (continuation: CheckedContinuation<CLIRunner.Captured, Never>) in
            DispatchQueue.global().async { [self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = args
                var merged = CLIRunner.cliEnvironment()
                merged.merge(env) { _, new in new }
                process.environment = merged
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let started = lock.withLock { () -> Bool in
                    guard !cancelled else { return false }
                    self.process = process
                    return (try? process.run()) != nil
                }
                guard started else {
                    continuation.resume(returning: CLIRunner.Captured(output: "", error: isCancelled ? "" : "Couldn’t start \(exe).", status: -1))
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
                // Drain both pipes at once so a chatty installer can't block on a full pipe.
                let errorData = SetupBuffer()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) { errorData.set(err.fileHandleForReading.readDataToEndOfFile()) }
                let output = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                lock.withLock { self.process = nil }
                continuation.resume(returning: CLIRunner.Captured(output: String(decoding: output, as: UTF8.self),
                                                                  error: String(decoding: errorData.get(), as: UTF8.self),
                                                                  status: process.terminationStatus))
            }
        }
    }
}

private final class SetupBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
