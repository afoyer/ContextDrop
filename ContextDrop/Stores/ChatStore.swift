import AppKit
import Foundation
import Observation

/// A share that arrived (via Multipeer or a .contextdrop file) and hasn't been continued yet.
struct ReceivedShare: Identifiable, Equatable {
    let share: ShareSummary
    let receivedAt: Date
    var read = false
    var id: UUID { share.id }
}

/// App state: conversations, providers, received shares. Networking lives in PeerService.
@MainActor
@Observable
final class ChatStore {
    let peers: PeerService

    private(set) var conversations: [Conversation] = []
    private(set) var received: [ReceivedShare] = []
    var defaultProvider: ProviderKind = .openRouter
    private(set) var providerStatus: [ProviderKind: ProviderStatus] = [:]
    private(set) var runningConversationIDs: Set<UUID> = []
    /// Deep-chat terminal pane per conversation (CLI telemetry, never part of the answer).
    private(set) var terminals: [UUID: TerminalState] = [:]
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    @ObservationIgnored private var runningTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cliHandles: [UUID: CLIRunner.Handle] = [:]

    init(peers: PeerService) {
        self.peers = peers
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        }
        refreshProviderStatus()
    }

    // MARK: Lookup

    func conversation(_ id: UUID?) -> Conversation? {
        guard let id else { return nil }
        return conversations.first { $0.id == id }
    }

    func isRunning(_ id: UUID) -> Bool { runningConversationIDs.contains(id) }

    var recentConversations: [Conversation] {
        conversations.filter { !$0.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func mutate(_ id: UUID, _ body: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        body(&conversations[index])
        conversations[index].updatedAt = Date()
    }

    private func mutateMessage(_ conversationID: UUID, _ messageID: UUID, _ body: (inout Message) -> Void) {
        mutate(conversationID) { conversation in
            if let i = conversation.messages.firstIndex(where: { $0.id == messageID }) { body(&conversation.messages[i]) }
        }
    }

    // MARK: Chats

    @discardableResult
    func newConversation(provider: ProviderKind? = nil, pickedUp: ShareSummary? = nil) -> UUID {
        // Reuse an untouched empty chat instead of piling them up.
        conversations.removeAll { $0.isEmpty && $0.pickedUp == nil }
        var conversation = Conversation(provider: provider ?? defaultProvider, pickedUp: pickedUp)
        if let pickedUp { conversation.title = pickedUp.title }
        conversations.append(conversation)
        return conversation.id
    }

    func setProvider(_ provider: ProviderKind, for id: UUID) {
        defaultProvider = provider
        mutate(id) { conversation in
            guard conversation.provider != provider else { return }
            conversation.provider = provider
            conversation.cliSessionID = nil // sessions don't carry across tools
        }
    }

    func setFolder(_ url: URL, for id: UUID) {
        mutate(id) { conversation in
            conversation.folder = url
            conversation.cliSessionID = nil
        }
    }

    func ask(_ rawText: String, in id: UUID) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = conversation(id), !isRunning(id) else { return }
        mutate(id) { conversation in
            if conversation.messages.isEmpty && conversation.pickedUp == nil {
                conversation.title = Self.title(from: text)
            }
            conversation.messages.append(Message(role: .user, author: "You", text: text))
        }
        startAnswer(in: id, prompt: text, provider: conversation.provider, allowEdits: false)
    }

    /// Retries the last failed answer: the user's question was kept.
    func retry(in id: UUID) {
        guard let conversation = conversation(id), !isRunning(id),
              let last = conversation.messages.last, last.role == .assistant, last.error != nil,
              let question = conversation.messages.last(where: { $0.role == .user }) else { return }
        mutate(id) { $0.messages.removeLast() }
        startAnswer(in: id, prompt: question.text, provider: conversation.provider, allowEdits: false)
    }

    func stop(_ id: UUID) {
        cliHandles[id]?.interrupt()
        runningTasks[id]?.cancel()
    }

    func toggleKeep(_ messageID: UUID, in id: UUID) {
        mutateMessage(id, messageID) { message in
            guard message.role == .assistant, message.error == nil, !message.text.isEmpty else { return }
            message.kept.toggle()
        }
    }

    func markShared(_ id: UUID, with name: String) {
        mutate(id) { if !$0.sharedWith.contains(name) { $0.sharedWith.append(name) } }
    }

    // MARK: Answering

    private func startAnswer(in id: UUID, prompt: String, provider: ProviderKind, allowEdits: Bool) {
        let answer = Message(role: .assistant, author: provider.displayName, text: "", isStreaming: true)
        mutate(id) { $0.messages.append(answer) }
        runningConversationIDs.insert(id)

        runningTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                switch provider {
                case .openRouter:
                    try await self.runOpenRouter(id, answerID: answer.id)
                case .claudeCode, .codex:
                    try await self.runCLI(id, answerID: answer.id, prompt: prompt, provider: provider, allowEdits: allowEdits)
                }
                self.mutateMessage(id, answer.id) { message in
                    message.isStreaming = false
                    if message.text.isEmpty && message.steps.isEmpty && message.editRequests.isEmpty {
                        message.text = Task.isCancelled ? "Stopped." : "(No answer.)"
                    }
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                self.mutateMessage(id, answer.id) { message in
                    message.isStreaming = false
                    if cancelled {
                        if message.text.isEmpty { message.text = "Stopped." }
                    } else {
                        message.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
            self.runningConversationIDs.remove(id)
            self.runningTasks[id] = nil
            self.cliHandles[id] = nil
        }
    }

    private static let baseSystemPrompt = """
    You are ContextDrop, a concise assistant summoned from a floating panel on a Mac. \
    Answer directly and briefly; use short paragraphs or lists. Plain text with light Markdown only.
    """

    private func runOpenRouter(_ id: UUID, answerID: UUID) async throws {
        let client = try OpenRouterClient.fromSettings()
        guard let conversation = conversation(id) else { return }
        var system = Self.baseSystemPrompt
        if let picked = conversation.pickedUp { system += "\n\n" + picked.contextPrompt() }
        var turns = [ChatTurn(role: "system", content: system)]
        for message in conversation.messages where message.id != answerID && message.error == nil && !message.text.isEmpty {
            turns.append(ChatTurn(role: message.role == .user ? "user" : "assistant", content: message.text))
        }
        // Batch deltas so SwiftUI re-renders ~20×/s, not per token.
        var buffer = ""
        var lastFlush = Date.distantPast
        for try await delta in client.stream(turns) {
            buffer += delta
            if Date().timeIntervalSince(lastFlush) > 0.05 {
                let chunk = buffer
                buffer = ""
                lastFlush = Date()
                mutateMessage(id, answerID) { $0.text += chunk }
            }
        }
        if !buffer.isEmpty { mutateMessage(id, answerID) { $0.text += buffer } }
    }

    private func runCLI(_ id: UUID, answerID: UUID, prompt: String, provider: ProviderKind, allowEdits: Bool) async throws {
        guard let conversation = conversation(id) else { return }
        guard let folder = conversation.folder else { throw ProviderError.noFolder }
        let handle = CLIRunner.Handle()
        cliHandles[id] = handle
        let request = CLIRunner.Request(
            kind: provider,
            folder: folder,
            prompt: prompt,
            sessionID: conversation.cliSessionID,
            systemAppend: conversation.pickedUp?.contextPrompt(),
            allowEdits: allowEdits
        )
        for try await event in CLIRunner.run(request, handle: handle) {
            apply(event, conversationID: id, answerID: answerID)
        }
    }

    private func apply(_ event: ProviderEvent, conversationID id: UUID, answerID: UUID) {
        switch event {
        case .session(let sessionID):
            mutate(id) { $0.cliSessionID = sessionID }
        case .text(let text):
            mutateMessage(id, answerID) { $0.text += text }
        case .textBlockBreak:
            mutateMessage(id, answerID) { if !$0.text.isEmpty { $0.text += "\n\n" } }
        case .step(let step):
            mutateMessage(id, answerID) { message in
                if let i = message.steps.firstIndex(where: { $0.id == step.id }) { message.steps[i] = step } else { message.steps.append(step) }
            }
        case .stepFinished(let stepID, let failed):
            mutateMessage(id, answerID) { message in
                guard let i = message.steps.firstIndex(where: { $0.id == stepID }) else { return }
                message.steps[i].done = true
                // A refused edit is shown as an Allow card, not as a failure.
                message.steps[i].failed = failed && message.steps[i].kind != .edit
                if failed && message.steps[i].kind == .edit { message.steps[i].label = "Wants to edit" }
            }
        case .editRequest(let request):
            mutateMessage(id, answerID) { message in
                if !message.editRequests.contains(where: { $0.id == request.id }) { message.editRequests.append(request) }
            }
        case .editsBlocked:
            mutateMessage(id, answerID) { message in
                guard !message.editRequests.contains(where: { $0.id == "codex-edits" }) else { return }
                message.editRequests.append(EditRequest(id: "codex-edits", filePath: "files in this folder", oldText: "", newText: ""))
            }
        case .log(let kind, let text):
            terminals[id, default: TerminalState()].append(kind, text)
        case .runInfo(let patch):
            terminals[id, default: TerminalState()].run.apply(patch)
        }
    }

    /// The user approved the agent's proposed edits: resume the same CLI session with edit permission.
    func allowEdits(messageID: UUID, in id: UUID) {
        guard let conversation = conversation(id), conversation.provider.isDeep, !isRunning(id),
              let message = conversation.messages.first(where: { $0.id == messageID }) else { return }
        let files = Set(message.editRequests.map(\.fileName)).sorted().joined(separator: ", ")
        mutateMessage(id, messageID) { message in
            for i in message.editRequests.indices { message.editRequests[i].status = .allowed }
        }
        let prompt = "The user approved your proposed edits (\(files)). Apply exactly those changes now, then confirm in one sentence."
        mutate(id) { $0.messages.append(Message(role: .user, author: "You", text: "Allow edits to \(files)")) }
        startAnswer(in: id, prompt: prompt, provider: conversation.provider, allowEdits: true)
    }

    // MARK: Providers

    func refreshProviderStatus() {
        providerStatus[.openRouter] = OpenRouterSettings.apiKey() == nil ? .missingKey : .ready("API key · fast, no file access")
        for kind in [ProviderKind.claudeCode, .codex] {
            if providerStatus[kind] == nil { providerStatus[kind] = .checking }
            Task { [weak self] in
                let status = await CLIRunner.status(for: kind)
                self?.providerStatus[kind] = status
            }
        }
    }

    func status(_ kind: ProviderKind) -> ProviderStatus { providerStatus[kind] ?? .checking }

    // MARK: Received shares

    func receive(_ share: ShareSummary) {
        guard !received.contains(where: { $0.id == share.id }) else { return }
        received.insert(ReceivedShare(share: share, receivedAt: Date()), at: 0)
    }

    /// Opens a new private chat seeded with the share (Continue). Returns the new conversation id.
    @discardableResult
    func continueFrom(_ share: ShareSummary) -> UUID {
        if let existing = conversations.first(where: { $0.pickedUp?.id == share.id }) {
            markRead(share.id)
            return existing.id
        }
        markRead(share.id)
        return newConversation(provider: .openRouter, pickedUp: share)
    }

    func markRead(_ shareID: UUID) {
        if let i = received.firstIndex(where: { $0.id == shareID }) { received[i].read = true }
    }

    func removeReceived(_ shareID: UUID) {
        received.removeAll { $0.id == shareID }
    }

    @discardableResult
    func ingestFile(_ url: URL) -> ShareSummary? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= WireCodec.maxPayloadBytes,
              let share = try? ShareSummary.fromFile(data) else {
            peers.notice = "That .contextdrop file couldn't be read."
            return nil
        }
        receive(share)
        return share
    }

    // MARK: Building a share

    func buildShare(from prep: SharePrep, conversation: Conversation) -> ShareSummary {
        ShareSummary(
            id: UUID(),
            title: prep.title.isEmpty ? conversation.title : prep.title,
            senderName: peers.localDisplayName,
            senderDevice: peers.localDevice,
            createdAt: Date(),
            summary: prep.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            kept: prep.kept,
            decisions: prep.decisions.filter(\.included).map(\.value),
            openQuestions: prep.questions.filter(\.included).map(\.value),
            notes: prep.notes.filter(\.included).map(\.value),
            fileNames: prep.includeFileNames ? conversation.referencedFileNames : [],
            transcript: prep.includeTranscript
                ? conversation.messages.filter { $0.error == nil && !$0.text.isEmpty }.map { TranscriptLine(author: $0.author, text: $0.text) }
                : nil
        )
    }

    static func title(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: "?.!,:;"))
        return trimmed.isEmpty ? "New chat" : trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}
