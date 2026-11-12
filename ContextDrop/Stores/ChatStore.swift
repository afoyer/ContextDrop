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
    var notices: NoticeCenter { peers.notices }
    let folders = FolderShortcutStore()
    /// Auto mode for new chats (see `askAuto`). Picking a provider by hand turns it off.
    var autoRoute = AppDefaults.autoRoute {
        didSet { AppDefaults.autoRoute = autoRoute }
    }

    private(set) var conversations: [Conversation] = []
    private(set) var received: [ReceivedShare] = []
    var defaultProvider: ProviderKind = AppDefaults.provider
    private(set) var providerStatus: [ProviderKind: ProviderStatus] = [:]
    private(set) var runningConversationIDs: Set<UUID> = []
    /// Deep-chat terminal pane per conversation (CLI telemetry, never part of the answer).
    private(set) var terminals: [UUID: TerminalState] = [:]
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Chats whose answer finished while nobody was looking at them (green dot).
    private(set) var finishedUnseen: Set<UUID> = []
    /// Chats on screen right now (panel or selected tab); they never count as unseen.
    @ObservationIgnored var visibleConversations: () -> Set<UUID> = { [] }
    /// A chat started waiting for the user (permission or question). Used for the menu bar and notifications.
    @ObservationIgnored var onNeedsYou: ((UUID, String) -> Void)?
    /// Anything the menu bar shows changed (runs, requests, shares).
    @ObservationIgnored var onActivityChanged: (() -> Void)?

    /// Empty chats that must survive (they are open as tabs).
    @ObservationIgnored var keepEmptyConversations: () -> Set<UUID> = { [] }
    @ObservationIgnored private var runningTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var handles: [UUID: RunHandle] = [:]
    @ObservationIgnored private var routingTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var retryApprovals: [UUID: PermissionRequest] = [:]

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

    /// What a tab's dot shows: orange beats spinning, spinning beats green.
    func tabState(_ id: UUID) -> TabState {
        if conversation(id)?.needsUser == true { return .needsYou }
        if isRunning(id) { return .running }
        return finishedUnseen.contains(id) ? .finishedUnseen : .idle
    }

    func markSeen(_ id: UUID) {
        if finishedUnseen.remove(id) != nil { onActivityChanged?() }
    }

    var conversationsNeedingYou: [Conversation] { conversations.filter(\.needsUser) }
    var runningConversations: [Conversation] { conversations.filter { isRunning($0.id) && !$0.needsUser } }

    func removeConversation(_ id: UUID) {
        stop(id)
        conversations.removeAll { $0.id == id }
        terminals[id] = nil
        finishedUnseen.remove(id)
        onActivityChanged?()
    }

    func setPermissionLevel(_ level: PermissionLevel, for id: UUID) {
        mutate(id) { $0.permissionLevel = level }
    }

    func setPinnedSkills(_ skills: [String], for id: UUID) {
        mutate(id) { $0.pinnedSkills = skills }
    }

    /// Stops every running agent (the app is quitting).
    func stopAll() {
        for handle in handles.values { handle.interrupt() }
        for task in runningTasks.values { task.cancel() }
        for id in Array(routingTokens.keys) { stop(id) }
    }

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
        // Drop untouched empty chats instead of piling them up (open tabs are kept).
        let kept = keepEmptyConversations()
        conversations.removeAll { $0.isEmpty && $0.pickedUp == nil && !kept.contains($0.id) }
        var conversation = Conversation(provider: provider ?? defaultProvider, pickedUp: pickedUp)
        if let pickedUp { conversation.title = pickedUp.title }
        conversations.append(conversation)
        return conversation.id
    }

    /// Changes this chat's provider. `asDefault` also makes it the provider new chats start with
    /// (picked from the menu); slash commands leave the default alone.
    func setProvider(_ provider: ProviderKind, for id: UUID, asDefault: Bool = false) {
        if asDefault { defaultProvider = provider }
        mutate(id) { conversation in
            guard conversation.provider != provider else { return }
            conversation.provider = provider
            conversation.cliSessionID = nil // sessions don't carry across tools
        }
    }

    func setFolder(_ url: URL, for id: UUID) {
        mutate(id) { conversation in
            if conversation.folder != url { conversation.cliSessionID = nil }
            conversation.folder = url
        }
        AppDefaults.lastFolder = url
        answerPendingQuestion(id)
    }

    /// `levelCap` limits this one answer to at most that permission level, whatever the chat is set to
    /// (a room follow-up from someone else). The chat's own setting is left as it is.
    func ask(_ rawText: String, attachments: [Attachment] = [], skills: [String] = [], levelCap: PermissionLevel? = nil, in id: UUID) {
        guard let text = appendQuestion(rawText, attachments: attachments, skills: skills, in: id), let conversation = conversation(id) else { return }
        if conversation.provider.isDeep && conversation.folder == nil { return } // answered once a folder is chosen
        startAnswer(in: id, prompt: text, images: attachments, provider: conversation.provider,
                    level: levelCap.map { conversation.permissionLevel.capped(at: $0) })
    }

    /// Adds the user's message (titling a new chat). Returns the text actually asked, or nil if there is nothing to ask.
    @discardableResult
    func appendQuestion(_ rawText: String, attachments: [Attachment], skills: [String] = [], in id: UUID) -> String? {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, conversation(id) != nil, !isRunning(id) else { return nil }
        if text.isEmpty {
            if attachments.isEmpty { return nil }
            let images = attachments.filter(\.isImage).count
            let noun = attachments.allSatisfy { $0.link != nil } ? "link" : attachments.allSatisfy { $0.isPastedText == true } ? "pasted text" : "attached file"
            text = images == 0 ? "Take a look at \(attachments.count == 1 ? "this \(noun)" : "these \(noun)s")."
                : (attachments.count == 1 ? "What does this screenshot show?" : "What do these screenshots show?")
        }
        let question = text
        mutate(id) { conversation in
            if conversation.messages.isEmpty && conversation.pickedUp == nil {
                conversation.title = Conversation.title(from: question)
            }
            var message = Message(role: .user, author: "You", text: question, attachments: attachments)
            var all = conversation.pinnedSkills
            for skill in skills where !all.contains(skill) { all.append(skill) }
            message.skills = all
            conversation.messages.append(message)
        }
        return text
    }

    /// Retries the last failed answer: the user's question was kept.
    func retry(in id: UUID) {
        guard let conversation = conversation(id), !isRunning(id),
              let last = conversation.messages.last, last.role == .assistant, last.error != nil,
              let question = conversation.messages.last(where: { $0.role == .user }) else { return }
        mutate(id) { $0.messages.removeLast() }
        startAnswer(in: id, prompt: question.text, images: question.attachments, provider: conversation.provider)
    }

    func stop(_ id: UUID) {
        if routingTokens.removeValue(forKey: id) != nil {
            mutate(id) { conversation in
                conversation.isRouting = false
                conversation.messages.append(Message(role: .assistant, author: "Auto", text: "Stopped."))
            }
            runningConversationIDs.remove(id)
            onActivityChanged?()
        }
        retryApprovals[id] = nil
        handles[id]?.interrupt()
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

    // MARK: Auto routing

    /// Auto needs OpenAI (it makes the decision call).
    var autoAvailable: Bool { status(.openAI).isUsable }
    var autoActive: Bool { autoRoute && autoAvailable }

    /// The separately configured coding CLI, falling back to another ready CLI.
    func preferredDeepProvider() -> ProviderKind? {
        let preferred = AppDefaults.preferredCLI
        if preferred.isDeep, status(preferred).isReady { return preferred }
        return ProviderKind.deep.first { status($0).isReady }
    }

    /// Asks `AutoRouter` where the first question should go, then answers there.
    /// Returns true if a deep chat still needs a folder (the question waits and is answered once one is chosen).
    func askAuto(_ rawText: String, attachments: [Attachment], in id: UUID) async -> Bool {
        guard let text = appendQuestion(rawText, attachments: attachments, in: id) else { return false }
        let token = UUID()
        routingTokens[id] = token
        mutate(id) { $0.isRouting = true }
        runningConversationIDs.insert(id)

        await OpenAISettings.preload()
        refreshProviderStatus()

        let availableCLIs = ProviderKind.deep.filter { status($0).isReady }
        let question = text + (attachments.isEmpty ? "" : "\n[Attached: \(attachments.map(\.name).joined(separator: ", "))]")
        var decision = await AutoRouter(apiKey: OpenAISettings.apiKey() ?? "").decide(
            question: question, availableCLIs: availableCLIs, preferredCLI: AppDefaults.preferredCLI,
            shortcuts: folders.shortcuts,
            defaultFolder: (AppDefaults.folder ?? AppDefaults.lastFolder).map(FolderDrop.display),
            selectedFolder: conversation(id)?.folder.map(FolderDrop.display),
            workPreferences: AppDefaults.routeCLIByTask ? AppDefaults.cliWorkPreferences : nil)
        guard routingTokens[id] == token, conversation(id) != nil else { return false }
        routingTokens[id] = nil

        var folder: URL?
        let deep = status(decision.provider).isReady && decision.provider.isDeep ? decision.provider : preferredDeepProvider()
        if decision.route == .code, let deep {
            decision.provider = deep
            // An explicitly selected folder wins. A missing named folder must not silently use a different project.
            let namedFolder = decision.folder.flatMap { folders.shortcut(named: $0) }
            folder = conversation(id)?.folder
                ?? namedFolder.flatMap { $0.exists ? $0.url : nil }
                ?? (namedFolder == nil ? (AppDefaults.folder ?? AppDefaults.lastFolder) : nil)
        } else {
            decision.route = .quick
            decision.provider = .openAI
        }
        mutate(id) { conversation in
            conversation.isRouting = false
            conversation.routedBy = decision
            if conversation.provider != decision.provider { conversation.provider = decision.provider; conversation.cliSessionID = nil }
            if let folder { conversation.folder = folder }
        }
        runningConversationIDs.remove(id)

        if decision.provider.isDeep && conversation(id)?.folder == nil { return true }
        if let folder { AppDefaults.lastFolder = folder }
        startAnswer(in: id, prompt: text, images: attachments, provider: decision.provider)
        return false
    }

    /// "Use OpenAI instead": re-answer the routed question as a quick answer.
    func useQuickAnswer(in id: UUID) {
        guard let conversation = conversation(id) else { return }
        stop(id)
        Task { @MainActor in
            // Let a stopped run unwind before replacing its answer.
            while isRunning(id) { try? await Task.sleep(for: .milliseconds(50)) }
            guard let question = conversation.messages.last(where: { $0.role == .user }) else { return }
            mutate(id) { c in
                if let last = c.messages.last, last.role == .assistant { c.messages.removeLast() }
                c.provider = .openAI
                c.cliSessionID = nil
                c.routedBy?.provider = .openAI
                c.routedBy?.route = .quick
                c.routedBy?.reason = "switched by you"
            }
            startAnswer(in: id, prompt: question.text, images: question.attachments, provider: .openAI)
        }
    }

    /// A deep chat whose last question has no answer yet (it was waiting for a folder): answer it now.
    private func answerPendingQuestion(_ id: UUID) {
        guard let conversation = conversation(id), conversation.provider.isDeep, conversation.folder != nil, !isRunning(id),
              let last = conversation.messages.last, last.role == .user else { return }
        startAnswer(in: id, prompt: last.text, images: last.attachments, provider: conversation.provider)
    }

    // MARK: Answering

    private func startAnswer(in id: UUID, prompt: String, images: [Attachment] = [], provider: ProviderKind, level: PermissionLevel? = nil) {
        let answer = Message(role: .assistant, author: provider.displayName, text: "", isStreaming: true)
        let skills = conversation(id)?.messages.last(where: { $0.role == .user })?.skills ?? []
        mutate(id) { $0.messages.append(answer) }
        runningConversationIDs.insert(id)
        finishedUnseen.remove(id)
        onActivityChanged?()

        runningTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(provider, in: id, answerID: answer.id, prompt: prompt, attachments: images, skills: skills, level: level)
                self.mutateMessage(id, answer.id) { message in
                    message.isStreaming = false
                    if message.text.isEmpty && message.steps.isEmpty && message.permissions.isEmpty && message.changes.isEmpty {
                        message.text = Task.isCancelled ? "Stopped." : "(No answer.)"
                    }
                }
                self.terminals[id]?.finishRun(Task.isCancelled ? .stopped : .finished)
            } catch {
                let cancelled = error.isCancellation
                self.terminals[id]?.finishRun(cancelled ? .stopped : .failed)
                if !cancelled, provider.isDeep {
                    self.terminals[id, default: TerminalState()].append(.error, error.userMessage)
                }
                self.mutateMessage(id, answer.id) { message in
                    message.isStreaming = false
                    if cancelled {
                        if message.text.isEmpty { message.text = "Stopped." }
                    } else {
                        message.error = error.userMessage
                        message.failure = (error as? ProviderError)?.failure ?? (provider.isDeep ? .agentStopped : .noResponse)
                    }
                }
            }
            self.mutateMessage(id, answer.id) { $0.settle() }
            self.runningConversationIDs.remove(id)
            self.runningTasks[id] = nil
            self.handles[id] = nil
            self.retryApprovals[id] = nil
            if !self.visibleConversations().contains(id) { self.finishedUnseen.insert(id) }
            self.onActivityChanged?()
        }
    }

    /// Runs one answer with the chat's provider and applies what it streams back.
    private func run(_ kind: ProviderKind, in id: UUID, answerID: UUID, prompt: String, attachments: [Attachment], skills: [String],
                     level override: PermissionLevel?) async throws {
        guard let conversation = conversation(id) else { return }
        if kind.isDeep, conversation.folder == nil { throw ProviderError.noFolder }
        if !status(kind).isReady { refreshProviderStatus() }
        let level = override ?? conversation.permissionLevel
        let handle = RunHandle()
        handles[id] = handle
        // Delegation needs the setting and the other CLI ready.
        let delegate = AppDefaults.delegateAgents && kind.delegatePartner.map { status($0).isReady } == true
        let request = ProviderRequest(conversation: conversation, prompt: prompt, attachments: attachments, skills: skills,
                                      level: level, delegate: delegate)
        if kind.isDeep { terminals[id, default: TerminalState()].beginRun(level: level) }

        var text = TextBatcher()
        for try await event in Providers[kind].run(request, handle: handle) {
            if case .text(let delta) = event {
                if let chunk = text.add(delta) { apply(.text(chunk), conversationID: id, answerID: answerID) }
                continue
            }
            if let rest = text.flush() { apply(.text(rest), conversationID: id, answerID: answerID) }
            apply(event, conversationID: id, answerID: answerID)
        }
        if let rest = text.flush() { apply(.text(rest), conversationID: id, answerID: answerID) }
    }

    private func apply(_ event: ProviderEvent, conversationID id: UUID, answerID: UUID) {
        if case .permissionRequest(let request) = event, answerOnUsersBehalf(request, in: id) { return }
        if !event.isTelemetry {
            var effect = ReducerEffect()
            mutate(id) { effect = $0.apply(event, answerID: answerID) }
            if let title = effect.needsYou { onNeedsYou?(id, title) }
            if effect.activityChanged { onActivityChanged?() }
        }
        if event.concernsTerminal { terminals[id, default: TerminalState()].apply(event) }
    }

    /// A live request the user already answered: the edit they approved for this retry, or a rule they always allow in this chat.
    private func answerOnUsersBehalf(_ request: PermissionRequest, in id: UUID) -> Bool {
        guard request.live else { return false }
        let note: String
        if let approved = retryApprovals[id], approved.tool == request.tool, Self.sameInput(approved.input, request.input) {
            retryApprovals[id] = nil
            note = "allowed approved retry: \(request.tool) \(request.summary.prefix(120))"
        } else if conversation(id)?.alwaysAllowed.contains(request.rule) == true {
            note = "allowed automatically (\(request.ruleLabel) are always allowed in this chat)"
        } else {
            return false
        }
        handles[id]?.respond(requestID: request.id, allow: true, input: request.input)
        terminals[id, default: TerminalState()].append(.info, note)
        return true
    }

    func clearTerminal(_ id: UUID) {
        guard var terminal = terminals[id] else { return }
        terminal.lines.removeAll()
        terminal.rawLines.removeAll()
        terminals[id] = terminal
    }

    // MARK: Permissions and questions

    private func locate(_ requestID: String, in id: UUID) -> (message: Message, request: PermissionRequest)? {
        guard let conversation = conversation(id) else { return nil }
        for message in conversation.messages.reversed() {
            if let request = message.permissions.first(where: { $0.id == requestID }) { return (message, request) }
        }
        return nil
    }

    private static func sameInput(_ a: Data, _ b: Data) -> Bool {
        guard let left = (try? JSONSerialization.jsonObject(with: a)) as? NSDictionary,
              let right = (try? JSONSerialization.jsonObject(with: b)) as? NSDictionary else { return false }
        return left.isEqual(right)
    }

    /// Allow what the agent asked for. `always` also allows the same kind of request for the rest of this chat.
    func allow(_ requestID: String, in id: UUID, always: Bool = false) {
        guard let (message, request) = locate(requestID, in: id), request.status == .pending else { return }
        if request.live {
            guard let handle = handles[id] else { return }
            if always { mutate(id) { $0.alwaysAllowed.insert(request.rule) } }
            handle.respond(requestID: request.id, allow: true, input: request.input)
            mutateMessage(id, message.id) { message in
                if let i = message.permissions.firstIndex(where: { $0.id == requestID }) { message.permissions[i].status = .allowed }
                // Also answer other waiting requests the new rule covers.
                guard always else { return }
                for i in message.permissions.indices where message.permissions[i].status == .pending
                    && message.permissions[i].live && message.permissions[i].rule == request.rule {
                    handle.respond(requestID: message.permissions[i].id, allow: true, input: message.permissions[i].input)
                    message.permissions[i].status = .allowed
                }
            }
            terminals[id, default: TerminalState()].append(.result, "allowed: \(request.tool) \(request.summary.prefix(120))")
            onActivityChanged?()
            return
        }
        // The call was refused during a run that couldn't ask: run again, this time able to ask or edit.
        let what = request.isEdit ? (request.fileName.isEmpty ? request.summary : request.fileName) : "\(request.tool) \(request.summary)"
        guard let conversation = conversation(id), !isRunning(id),
              let retry = Providers[conversation.provider].retry(afterApproving: what) else { return }
        if always { mutate(id) { $0.alwaysAllowed.insert(request.rule) } }
        mutateMessage(id, message.id) { message in
            if let i = message.permissions.firstIndex(where: { $0.id == requestID }) { message.permissions[i].status = .allowed }
        }
        mutate(id) { $0.messages.append(Message(role: .user, author: "You", text: "Allow: \(what)")) }
        if retry.asksAgain && !always { retryApprovals[id] = request }
        startAnswer(in: id, prompt: retry.prompt, provider: conversation.provider, level: retry.level)
    }

    func deny(_ requestID: String, in id: UUID, reason: String? = nil) {
        guard let (message, request) = locate(requestID, in: id), request.status == .pending else { return }
        if request.live {
            handles[id]?.respond(requestID: request.id, allow: false,
                                    message: reason ?? "The user said no to this. Don't retry it; continue another way or explain what you need.")
            terminals[id, default: TerminalState()].append(.info, "denied: \(request.tool) \(request.summary.prefix(120))")
        }
        mutateMessage(id, message.id) { message in
            if let i = message.permissions.firstIndex(where: { $0.id == requestID }) { message.permissions[i].status = .denied }
        }
        onActivityChanged?()
    }

    /// Answers the current question of a decision card; the agent continues once every question has an answer.
    func answer(_ questionID: String, with answer: String, in id: UUID) {
        guard let conversation = conversation(id),
              let message = conversation.messages.last(where: { $0.questions.contains { $0.id == questionID } }),
              var question = message.questions.first(where: { $0.id == questionID }), question.status == .pending,
              let index = question.items.firstIndex(where: { $0.answer == nil }) else { return }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question.items[index].answer = text
        if question.current == nil {
            var input = (try? JSONSerialization.jsonObject(with: question.input)) as? [String: Any] ?? [:]
            input["answers"] = Dictionary(question.items.map { ($0.question, $0.answer ?? "") }, uniquingKeysWith: { first, _ in first })
            let data = (try? JSONSerialization.data(withJSONObject: input)) ?? question.input
            handles[id]?.respond(requestID: question.id, allow: true, input: data)
            question.status = .answered
            terminals[id, default: TerminalState()].append(.result, "answered: \(question.items.compactMap(\.answer).joined(separator: " · "))")
        }
        let updated = question
        mutateMessage(id, message.id) { message in
            if let i = message.questions.firstIndex(where: { $0.id == questionID }) { message.questions[i] = updated }
        }
        onActivityChanged?()
    }

    // MARK: Providers

    func refreshProviderStatus() {
        for provider in Providers.all {
            let kind = provider.kind
            if providerStatus[kind] == nil { providerStatus[kind] = .checking }
            Task { [weak self] in
                let status = await provider.status()
                self?.providerStatus[kind] = status
            }
        }
    }

    func status(_ kind: ProviderKind) -> ProviderStatus { providerStatus[kind] ?? .checking }

    // MARK: Received shares

    func receive(_ share: ShareSummary) {
        guard !received.contains(where: { $0.id == share.id }) else { return }
        received.insert(ReceivedShare(share: share, receivedAt: Date()), at: 0)
        onActivityChanged?()
    }

    /// Opens a new private chat seeded with the share (Continue). Returns the new conversation id.
    @discardableResult
    func continueFrom(_ share: ShareSummary) -> UUID {
        if let existing = conversations.first(where: { $0.pickedUp?.id == share.id }) {
            markRead(share.id)
            return existing.id
        }
        markRead(share.id)
        let id = newConversation(provider: .openAI, pickedUp: share)
        let saved = share.sharedImages.compactMap { Attachments.save(jpeg: $0.jpeg, name: $0.name) }
        if !saved.isEmpty { mutate(id) { $0.pickedUpAttachments = saved } }
        return id
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
            notices.text = "That .contextdrop file couldn't be read."
            return nil
        }
        receive(share)
        return share
    }
}
