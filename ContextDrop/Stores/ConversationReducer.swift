import Foundation

/// What a provider event asks of the store besides the state change itself.
struct ReducerEffect: Equatable, Sendable {
    /// The chat started waiting for the user; this is the line to show (menu bar, notification).
    var needsYou: String?
    /// Something the menu bar shows changed.
    var activityChanged = false
}

// How a run's events change a chat and its activity pane. Pure: no store, no process, no clock but the one passed in.
// `ChatStore.apply` decides which of the two an event reaches, so answer text never redraws the pane
// and telemetry never redraws the chat.

extension ProviderEvent {
    /// Events the activity pane shows (telemetry, plus the few that appear in both places).
    var concernsTerminal: Bool {
        switch self {
        case .log(_, let text, _): !text.isEmpty
        case .raw, .runInfo, .plan, .subagentStarted, .subagentFinished, .fileChange, .warning: true
        default: false
        }
    }
}

extension Conversation {
    /// Applies one event to the answer being written. Telemetry is ignored here.
    @discardableResult
    mutating func apply(_ event: ProviderEvent, answerID: UUID, now: Date = Date()) -> ReducerEffect {
        if case .session(let sessionID) = event {
            cliSessionID = sessionID
            return ReducerEffect()
        }
        guard let index = messages.firstIndex(where: { $0.id == answerID }) else { return ReducerEffect() }
        return messages[index].apply(event, now: now)
    }
}

extension Message {
    @discardableResult
    mutating func apply(_ event: ProviderEvent, now: Date = Date()) -> ReducerEffect {
        switch event {
        case .text(let delta):
            text += delta
        case .textBlockBreak:
            if !text.isEmpty { text += "\n\n" }
        case .step(let step):
            if let i = steps.firstIndex(where: { $0.id == step.id }) {
                // Keep "Wants to edit" once a refused patch was relabelled.
                var updated = step
                if steps[i].label == Self.wantsToEdit { updated.label = Self.wantsToEdit; updated.failed = false }
                steps[i] = updated
            } else {
                steps.append(step)
            }
        case .stepFinished(let stepID, let failed):
            guard let i = steps.firstIndex(where: { $0.id == stepID }) else { break }
            steps[i].done = true
            steps[i].failed = failed
        case .permissionRequest(let request):
            if !permissions.contains(where: { $0.id == request.id }) { permissions.append(request) }
            // A refused edit is shown as a card, not as a failed step.
            if !request.live, request.isEdit {
                for i in steps.indices where steps[i].kind == .edit && steps[i].failed {
                    steps[i].failed = false
                    steps[i].label = Self.wantsToEdit
                }
            }
            guard request.live else { return ReducerEffect(activityChanged: true) }
            let title = request.isEdit ? "Allow an edit to \(request.fileName)?" : "Allow \(request.tool): \(request.summary.prefix(80))?"
            return ReducerEffect(needsYou: title, activityChanged: true)
        case .question(let question):
            if !questions.contains(where: { $0.id == question.id }) { questions.append(question) }
            return ReducerEffect(needsYou: question.title, activityChanged: true)
        case .requestCancelled(let requestID):
            if let i = permissions.firstIndex(where: { $0.id == requestID && $0.status == .pending }) { permissions[i].status = .expired }
            if let i = questions.firstIndex(where: { $0.id == requestID && $0.status == .pending }) { questions[i].status = .expired }
            return ReducerEffect(activityChanged: true)
        case .subagentStarted(let subagent):
            if !subagents.contains(where: { $0.id == subagent.id }) { subagents.append(subagent) }
        case .subagentActivity(let subagentID, let current):
            if let i = subagents.firstIndex(where: { $0.id == subagentID }) { subagents[i].current = current }
        case .subagentFinished(let subagentID, let failed):
            guard let i = subagents.firstIndex(where: { $0.id == subagentID }) else { break }
            subagents[i].status = failed ? .failed : .done
            subagents[i].endedAt = now
        case .fileChange(let change):
            // Several edits to one file are shown as separate entries, newest last; the same edit is never listed twice.
            changes.upsert(change)
        case .warning(let text):
            warning = text
        case .session, .log, .raw, .runInfo, .plan:
            break
        }
        return ReducerEffect()
    }

    /// The run is over: nothing can answer a paused request once the process is gone, and no helper is still working.
    mutating func settle(now: Date = Date()) {
        for i in permissions.indices where permissions[i].status == .pending && permissions[i].live { permissions[i].status = .expired }
        for i in questions.indices where questions[i].status == .pending { questions[i].status = .expired }
        for i in subagents.indices where subagents[i].status == .running {
            subagents[i].status = .done
            subagents[i].endedAt = now
        }
    }

    private static let wantsToEdit = "Wants to edit"
}

extension TerminalState {
    /// Applies one event to the activity pane. Answer text and requests are ignored here.
    mutating func apply(_ event: ProviderEvent, now: Date = Date()) {
        switch event {
        case .log(let kind, let text, let agent):
            if !text.isEmpty { append(kind, text, agent: agent) }
        case .raw(let line):
            appendRaw(line)
        case .runInfo(let patch):
            run.apply(patch)
        case .plan(let steps):
            plan = steps
        case .subagentStarted(let subagent):
            subagents.append(subagent)
        case .subagentFinished(let subagentID, let failed):
            guard let i = subagents.firstIndex(where: { $0.id == subagentID }) else { break }
            subagents[i].status = failed ? .failed : .done
            subagents[i].endedAt = now
        case .fileChange(let change):
            changes.upsert(change)
        case .warning(let text):
            append(.error, text)
        default:
            break
        }
    }

    /// A fresh run: the log is kept, everything about the previous run is cleared.
    mutating func beginRun(level: PermissionLevel, now: Date = Date()) {
        if !lines.isEmpty { append(.info, "") }
        let cliVersion = run.cliVersion
        run = TerminalRun(phase: .starting, startedAt: now, level: level)
        run.cliVersion = cliVersion
        changes = []
        plan = []
        subagents = []
    }

    mutating func finishRun(_ phase: TerminalRun.Phase, now: Date = Date()) {
        guard run.isActive else { return }
        run.phase = phase
        run.endedAt = now
    }
}

private extension Array where Element == FileChange {
    mutating func upsert(_ change: FileChange) {
        if let i = firstIndex(where: { $0.id == change.id }) { self[i] = change } else { append(change) }
    }
}

extension Conversation {
    /// A chat's title from its first question: the first six words.
    static func title(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: "?.!,:;"))
        return trimmed.isEmpty ? "New chat" : trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}
