import Foundation

/// The owner's side of run tiles: summarises this Mac's Claude Code runs for the room, about twice a second.
///
/// The run itself never leaves this Mac and nobody else can steer it; the room only gets the plan, the current
/// state, subagents, changed files (names and line counts) and recent log lines, all passed through `SecretMasker`.
@MainActor
final class RoomRunBroadcaster {
    private unowned let store: RoomStore

    private struct Tracked {
        var conversationID: UUID
        var last: RoomRunTile?
        /// Log lines already numbered for the room, newest last.
        var log: [RunLogLine] = []
        var nextSeq = 0
        var lastLineID: UUID?
        /// The previous command read a .env file, so its output is all values.
        var envOutput = false
    }

    private var tracked: [UUID: Tracked] = [:]
    private var loop: Task<Void, Never>?

    private static let interval: Duration = .milliseconds(500)

    init(store: RoomStore) {
        self.store = store
    }

    func tileID(for conversationID: UUID) -> UUID? {
        tracked.first { $0.value.conversationID == conversationID }?.key
    }

    func conversationID(for tileID: UUID) -> UUID? { tracked[tileID]?.conversationID }

    func track(_ conversationID: UUID, as tileID: UUID) {
        tracked[tileID] = Tracked(conversationID: conversationID)
        tick()
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func tileRemoved(_ id: UUID) {
        tracked[id] = nil
        if tracked.isEmpty { stop() }
    }

    func reset() {
        tracked = [:]
        stop()
    }

    private func stop() {
        loop?.cancel()
        loop = nil
    }

    private func tick() {
        guard store.isActive else { return }
        for tileID in Array(tracked.keys) {
            guard var entry = tracked[tileID] else { continue }
            guard let run = build(&entry) else { continue }
            if run != entry.last {
                entry.last = run
                store.post(.runUpdate(tileID, run))
            }
            tracked[tileID] = entry
        }
    }

    /// The first summary of a run, before it has a tile.
    func snapshot(of conversationID: UUID) -> RoomRunTile? {
        var entry = Tracked(conversationID: conversationID)
        return build(&entry)
    }

    // MARK: Summary

    private func build(_ entry: inout Tracked) -> RoomRunTile? {
        guard let chats = store.chats, let conversation = chats.conversation(entry.conversationID) else { return nil }
        let terminal = chats.terminals[conversation.id] ?? TerminalState()
        let me = store.localName
        let answer = conversation.messages.last { $0.role == .assistant }
        let root = conversation.folder?.standardizedFileURL.path

        /// The first line only. Secrets are hidden once, for every field, in `masked()` below.
        func line(_ text: String) -> String { String(text.prefix(while: { !$0.isNewline })) }
        func relative(_ path: String) -> String {
            if let root, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
            return (path as NSString).abbreviatingWithTildeInPath
        }

        var run = RoomRunTile(ownerName: me,
                              title: line(conversation.title),
                              folder: conversation.folder.map { FolderDrop.display($0) } ?? "")
        run.startedAt = terminal.run.startedAt
        run.endedAt = terminal.run.endedAt

        // State: running, waiting on me (with the reason), or over.
        if chats.isRunning(conversation.id) {
            if let request = conversation.pendingPermissions.first {
                let what = request.isEdit ? "an edit to \(request.fileName)" : String(line("\(request.tool) \(request.summary)").prefix(80))
                run.state = .waiting("Waiting for \(me) to approve \(what)")
            } else if conversation.pendingQuestions.first != nil {
                run.state = .waiting("Waiting for \(me) to answer a question")
            } else {
                run.state = .running
            }
        } else {
            run.state = terminal.run.phase == .failed || answer?.error != nil ? .failed : .done
            if let text = answer?.text, !text.isEmpty { run.summary = String(text.prefix(2_000)) }
        }

        // The plan: Claude Code's own to-do list when it keeps one, otherwise the steps seen so far.
        if !terminal.plan.isEmpty {
            run.plan = terminal.plan.map { RunPlanStep(text: line($0.text), status: $0.status) }
        } else if let steps = answer?.steps.filter({ $0.agentID == nil }), !steps.isEmpty {
            run.plan = steps.suffix(8).map { step in
                RunPlanStep(text: line("\(step.label) \(step.filePath.map(relative) ?? step.detail)"),
                            status: step.done ? .done : .active)
            }
        }
        if !run.isLive {
            // Nothing is in progress in a run that is over.
            for i in run.plan.indices where run.plan[i].status == .active { run.plan[i].status = run.state == .done ? .done : .pending }
        }

        run.subagents = (answer?.subagents ?? []).suffix(RoomLimits.maxSubagents).map {
            RunSubagentInfo(type: line($0.type), task: line($0.task), running: $0.status == .running)
        }

        // One row per file, with the line counts of all its edits.
        var changes: [RunChangeInfo] = []
        for change in answer?.changes ?? [] {
            let path = relative(change.path)
            if let i = changes.firstIndex(where: { $0.path == path }) {
                changes[i].added += change.added
                changes[i].removed += change.removed
            } else {
                changes.append(RunChangeInfo(path: path, added: change.added, removed: change.removed))
            }
        }
        run.changes = changes

        // New log lines since the last look, masked before they are numbered.
        let lines = terminal.lines
        var start = 0
        if let last = entry.lastLineID, let i = lines.lastIndex(where: { $0.id == last }) { start = i + 1 }
        for line in lines[start...] {
            guard let text = logText(line, envOutput: &entry.envOutput) else { continue }
            entry.log.append(RunLogLine(seq: entry.nextSeq, text: text))
            entry.nextSeq += 1
        }
        entry.lastLineID = lines.last?.id ?? entry.lastLineID
        if entry.log.count > RoomLimits.maxLogLines { entry.log.removeFirst(entry.log.count - RoomLimits.maxLogLines) }
        run.log = entry.log

        return run.masked().sanitized()
    }

    /// One short, masked line for the room, or nil for lines that stay here (thinking, raw output noise).
    private func logText(_ line: TerminalLine, envOutput: inout Bool) -> String? {
        let first = String(line.text.prefix(while: { !$0.isNewline }))
        guard !first.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let prefix: String
        switch line.kind {
        case .tool, .command:
            prefix = "› "
            envOutput = SecretMasker.looksLikeEnv(line.text)
        case .output, .stderr, .result:
            prefix = "  "
        case .info:
            // The agent's private reasoning is not for the room.
            if first.hasPrefix("thinking:") { return nil }
            prefix = "  "
            envOutput = false
        case .text:
            return nil // the answer itself; it arrives as the summary when the run ends
        case .error:
            prefix = "! "
        }
        let isOutput = line.kind == .output || line.kind == .result || line.kind == .stderr
        let masked = SecretMasker.mask(first, envFile: isOutput && envOutput)
        return String((prefix + masked).prefix(RoomLimits.maxLogLineLength))
    }
}

extension RoomRunTile {
    /// Every piece of text a run summary carries, with anything that looks like a secret hidden.
    /// This is the one place a run's text passes on its way out, so a new field can't skip it.
    /// (Log lines are masked as they are read, because whether a line is `.env` output depends on the one before.)
    func masked() -> RoomRunTile {
        let mask: (String) -> String = { SecretMasker.mask($0) }
        var run = self
        run.title = mask(title)
        run.folder = mask(folder)
        if case .waiting(let reason) = state { run.state = .waiting(mask(reason)) }
        run.plan = plan.map { RunPlanStep(text: mask($0.text), status: $0.status) }
        run.subagents = subagents.map { RunSubagentInfo(type: mask($0.type), task: mask($0.task), running: $0.running) }
        run.changes = changes.map { RunChangeInfo(path: mask($0.path), added: $0.added, removed: $0.removed) }
        run.summary = summary.map(mask)
        return run
    }
}
