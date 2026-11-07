import Foundation

/// One line in a deep chat's terminal pane: what the CLI agent is doing, as it happens.
struct TerminalLine: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case command, info, tool, output, text, stderr, result, error }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
}

/// Partial update to a run's status, streamed from CLIRunner. Nil fields leave the current value alone.
struct TerminalRunPatch: Sendable {
    var pid: Int32?
    var model: String?
    var permissionMode: String?
    var cliVersion: String?
    var toolCount: Int?
    var turns: Int?
    var costUSD: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var exitCode: Int32?
    var interrupted: Bool?
}

/// Live status of the CLI process behind a deep chat (the latest run).
struct TerminalRun: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, starting, running, finished, stopped, failed }

    var phase: Phase = .idle
    var startedAt: Date?
    var endedAt: Date?
    var editsAllowed = false
    var pid: Int32?
    var model: String?
    var permissionMode: String?
    var cliVersion: String?
    var toolCount: Int?
    var turns: Int?
    var costUSD: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var exitCode: Int32?
    var interrupted = false

    var isActive: Bool { phase == .starting || phase == .running }

    mutating func apply(_ patch: TerminalRunPatch) {
        if let v = patch.pid { pid = v; if phase == .starting { phase = .running } }
        if let v = patch.model { model = v }
        if let v = patch.permissionMode { permissionMode = v }
        if let v = patch.cliVersion { cliVersion = v }
        if let v = patch.toolCount { toolCount = v }
        if let v = patch.turns { turns = v }
        if let v = patch.costUSD { costUSD = v }
        if let v = patch.inputTokens { inputTokens = v }
        if let v = patch.outputTokens { outputTokens = v }
        if let v = patch.exitCode { exitCode = v }
        if let v = patch.interrupted { interrupted = v }
    }
}

struct TerminalState: Sendable {
    static let maxLines = 800

    var run = TerminalRun()
    var lines: [TerminalLine] = []

    mutating func append(_ kind: TerminalLine.Kind, _ text: String) {
        lines.append(TerminalLine(kind: kind, text: text))
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }
}
