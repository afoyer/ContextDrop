import AppKit
import Observation
import SwiftUI

/// Rows of the collapsed Quick Chat list (board 1): drops first, then recent chats, then actions.
enum HomeItem: Identifiable, Equatable {
    case offer(IncomingOffer)
    case received(ReceivedShare)
    case chat(Conversation)
    case clipboard

    var id: String {
        switch self {
        case .offer(let o): "offer-\(o.id)"
        case .received(let r): "received-\(r.id)"
        case .chat(let c): "chat-\(c.id)"
        case .clipboard: "clipboard"
        }
    }
}

/// What the panel asks the rest of the app to do.
struct PanelActions {
    var hide: () -> Void = {}
    var show: () -> Void = {}
    /// Opens a chat as a tab in the workspace window.
    var expand: (UUID) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var chooseFolder: (UUID) -> Void = { _ in }
    var captureScreenshot: () -> Void = {}
    var pickImages: () -> Void = {}
    var addFolderShortcut: () -> Void = {}
    var openRoom: () -> Void = {}
    /// "To room": puts an answer on the table of the room you're in.
    var sendToRoom: (Message, Conversation) -> Void = { _, _ in }
    /// "To room" on an OpenAI tab: the chat becomes a chat tile. (A run tab has the room chip instead.)
    var sendTabToRoom: (Conversation) -> Void = { _ in }
    /// The room chip: put a run in the room at a level, take it out, or change its level (by conversation id).
    var shareRun: (Conversation, RunShareLevel) -> Void = { _, _ in }
    var unshareRun: (UUID) -> Void = { _ in }
    var setShareLevel: (UUID, RunShareLevel) -> Void = { _, _ in }
}

/// What the floating panel is showing, and the keyboard logic behind it.
/// Attachments and drops, slash commands and the share flow are in the `PanelModel+…` files.
@MainActor
@Observable
final class PanelModel {
    enum Mode: Equatable {
        case home
        case chat(UUID)
        case share(UUID)
        case shareTabs          // several tabs ticked for one drop (R3 board 4)
        case send(conversationID: UUID, share: ShareSummary)
        case offer(UUID)        // preview of a pending offer from someone nearby
        case received(UUID)     // preview of a share already on this Mac (saved for later / file)
    }

    let store: ChatStore
    /// Tabs of the workspace window.
    let workspace = WorkspaceModel()
    var mode: Mode = .home {
        // Every chat shown in Quick Chat is a tab too, so the panel and the window share one set of tabs.
        didSet { if case .chat(let id) = mode, workspace.selected != id || !workspace.tabs.contains(id) { workspace.open(id) } }
    }
    /// How far the page is dragged sideways by a tab swipe, in Quick Chat and in the window.
    var panelSwipe: CGFloat = 0
    var windowSwipe: CGFloat = 0
    /// Reduce Motion: the tab a swipe would switch to once it is far enough.
    var swipeHint: UUID?
    /// The home input's draft, attachments and "/" state.
    let homeSession: ChatSession
    /// One input state per conversation, so the panel and each tab keep their own draft.
    @ObservationIgnored private var sessions: [UUID: ChatSession] = [:]
    /// The composer that last had focus (nil = home). Screenshots and picked images go there.
    var activeComposerID: UUID?
    /// True when that composer is in the workspace window rather than the panel.
    var activeComposerInWindow = false

    var draft: String {
        get { homeSession.draft }
        set { homeSession.draft = newValue }
    }
    var pendingAttachments: [Attachment] {
        get { homeSession.pendingAttachments }
        set { homeSession.pendingAttachments = newValue }
    }
    var slashSelection: Int {
        get { homeSession.slashSelection }
        set { homeSession.slashSelection = newValue }
    }
    var selection = 0
    var showProviderMenu = false
    /// Activity log filter per chat: nil = all, "main", or a subagent id.
    var activityFilter: [UUID: String] = [:]
    var prep: SharePrep?
    @ObservationIgnored var summaryTask: Task<Void, Never>?
    @ObservationIgnored var summaryToken: UUID?
    /// Several tabs being shared together. (The share flow is in PanelModel+Share.swift.)
    var multiShare: MultiSharePrep?
    /// Tabs travelling with the share in `.send` (the first one is the mode's share).
    @ObservationIgnored var extraShares: [(conversationID: UUID, share: ShareSummary)] = []
    /// Bumped to ask the active input to take focus.
    var focusToken = 0
    var copiedMessageID: UUID?
    @ObservationIgnored private var clipboardCache: (changeCount: Int, hasText: Bool) = (-1, false)
    /// Height available below the panel's top on the current screen (set when it's positioned).
    var maxPanelHeight: CGFloat = 900
    /// Fixed height of the wide layouts (share checklist, chat + terminal), capped to the screen.
    var tallLayoutHeight: CGFloat { min(720, maxPanelHeight) }

    /// Folder chosen with "/name" on home before typing the question.
    var homeFolder: FolderShortcut?
    /// What the next coding-agent chat from home may do without asking (chip / ⇧Tab). Kept until quit;
    /// each launch starts from the Settings default.
    var homeLevel = AppDefaults.permissionLevel
    /// True while the system screenshot UI is up (the panel is hidden meanwhile).
    var isCapturing = false
    /// Deep chats show the agent's terminal in a pane to the right of the chat (⌘T).
    var showTerminal = AppDefaults.showTerminal {
        didSet { AppDefaults.showTerminal = showTerminal }
    }

    /// What the panel asks the app to do (wired by the AppDelegate and the panel's controller).
    @ObservationIgnored var actions = PanelActions()
    /// The room you're in, for "To room" and the room chip. Nil when you aren't in one.
    var room: PanelRoom?
    var roomActive: Bool { room != nil }
    /// The level a run was last put in the room at; ⌘⇧R shares the next one the same way.
    var lastShareLevel: RunShareLevel = .steps

    init(store: ChatStore) {
        self.store = store
        homeSession = ChatSession(conversationID: nil, folders: store.folders)
    }

    /// The input state of a conversation (created on first use).
    func session(_ id: UUID?) -> ChatSession {
        guard let id else { return homeSession }
        if let existing = sessions[id] { return existing }
        let created = ChatSession(conversationID: id, folders: store.folders)
        sessions[id] = created
        return created
    }

    var activeSession: ChatSession { session(activeComposerID) }

    /// Remembers where the user is typing.
    func composerFocused(_ id: UUID?, inWindow: Bool) {
        activeComposerID = id
        activeComposerInWindow = inWindow
    }

    var peers: PeerService { store.peers }
    var notices: NoticeCenter { store.notices }
    var reduceMotion: Bool { store.reduceMotion }

    static let chatWidth: CGFloat = 640
    static let terminalWidth: CGFloat = 460
    static let tabStripHeight: CGFloat = 39

    var isWide: Bool { if case .share = mode { true } else { false } }
    /// Tabs going out with the share being sent.
    var extraShareCount: Int { extraShares.count }
    var width: CGFloat { isWide ? 1040 : Self.chatWidth + (terminalVisible ? Self.terminalWidth : 0) }

    /// The terminal pane is shown for deep chats (Claude Code / Codex) in chat mode.
    var terminalVisible: Bool {
        guard showTerminal, case .chat(let id) = mode, let conversation = store.conversation(id) else { return false }
        return conversation.provider.capabilities.requiresFolder
    }

    /// The conversation shown in the panel, if any.
    var panelConversationID: UUID? { if case .chat(let id) = mode { id } else { nil } }

    func toggleTerminal() {
        withAnimation(Motion.shareMode(reduceMotion)) { showTerminal.toggle() }
    }

    /// Panel auto-hides when it loses focus, except during flows that open system UI (AirDrop, folder picker).
    var keepsOpenOnResign: Bool {
        switch mode {
        case .share, .send, .shareTabs: true
        default: isCapturing
        }
    }

    var activeConversationID: UUID? {
        switch mode {
        case .chat(let id), .share(let id): id
        case .send(let id, _): id
        default: nil
        }
    }

    // MARK: Home list

    var homeItems: [HomeItem] {
        var items: [HomeItem] = []
        let offers = peers.offers.filter { $0.phase == .pending }.sorted { !$0.seen && $1.seen }
        items += offers.map { .offer($0) }
        let received = store.received.sorted { !$0.read && $1.read }
        items += received.prefix(4).map { .received($0) }
        items += store.recentConversations.prefix(4).map { .chat($0) }
        // Re-read the clipboard only when it changed (this runs on every render).
        let pasteboard = NSPasteboard.general
        if clipboardCache.changeCount != pasteboard.changeCount {
            let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            clipboardCache = (pasteboard.changeCount, !text.isEmpty)
        }
        if clipboardCache.hasText { items.append(.clipboard) }
        return items
    }

    // MARK: Lifecycle

    func summoned() {
        if case .home = mode { selection = 0 }
        composerFocused(panelConversationID, inWindow: false)
        SkillCatalog.shared.refresh(projectFolder: panelConversationID.flatMap { store.conversation($0)?.folder } ?? AppDefaults.lastFolder)
        focusToken += 1
    }

    /// esc: step back one level, or hide.
    func escape() {
        if showProviderMenu { showProviderMenu = false; return }
        switch mode {
        case .home, .chat:
            let current = session(panelConversationID)
            if current.slashQuery != nil { current.draft = ""; return } // close the / list first
            actions.hide()
            mode = .home
            homeSession.resetComposer()
            homeFolder = nil
            selection = 0
        case .share(let id):
            prep = nil
            withAnimation(Motion.shareMode(reduceMotion)) { mode = .chat(id) }
        case .shareTabs:
            multiShare?.task?.cancel()
            multiShare = nil
            mode = .home
            actions.hide()
        case .send(let id, _):
            if let outgoing = peers.outgoing, outgoing.phase == .waiting || outgoing.phase == .sending {
                actions.hide() // sending continues in the background
            } else if multiShare != nil {
                peers.clearOutgoing()
                extraShares = []
                multiShare?.phase = .choosing
                withAnimation(Motion.shareMode(reduceMotion)) { mode = .shareTabs }
            } else {
                peers.clearOutgoing()
                withAnimation(Motion.shareMode(reduceMotion)) { mode = .share(id) }
            }
        case .offer, .received:
            withAnimation(Motion.summon(reduceMotion)) { mode = .home }
        }
        focusToken += 1
    }

    // MARK: Home actions

    /// ⌘N: back to the empty home input, ready to type a new question.
    func newChat() {
        showProviderMenu = false
        if case .share = mode { prep = nil }
        if case .shareTabs = mode { multiShare?.task?.cancel(); multiShare = nil }
        if case .send = mode, peers.outgoing.map({ $0.phase != .waiting && $0.phase != .sending }) ?? false { peers.clearOutgoing() }
        withAnimation(Motion.summon(reduceMotion)) { mode = .home }
        homeSession.resetComposer()
        selection = 0
        focusToken += 1
    }

    // MARK: Tabs in Quick Chat

    func selectPanelTab(_ id: UUID) {
        guard store.conversation(id) != nil else { return }
        showProviderMenu = false
        mode = .chat(id)
        composerFocused(id, inWindow: false)
        session(id).requestFocus()
        focusToken += 1
    }

    /// ⌃Tab: the next tab waiting for you, else the next tab (wraps).
    func cyclePanelTab(backwards: Bool) {
        guard case .chat(let id) = mode else { return }
        if !backwards, let waiting = workspace.nextNeedingYou({ store.conversation($0)?.needsUser == true }), waiting != id {
            selectPanelTab(waiting)
        } else {
            stepPanelTab(backwards ? -1 : 1, wraps: true)
        }
    }

    func stepPanelTab(_ delta: Int, wraps: Bool = false) {
        let tabs = workspace.tabs
        guard case .chat(let id) = mode, let index = tabs.firstIndex(of: id), tabs.count > 1 else { return }
        var next = index + delta
        if wraps { next = (next + tabs.count) % tabs.count }
        if tabs.indices.contains(next) { selectPanelTab(tabs[next]) }
    }

    /// ⌘W in Quick Chat. A chat that is still working keeps going (menu bar › Brewing).
    func closePanelTab(_ id: UUID) {
        let wasCurrent = panelConversationID == id
        workspace.close(id)
        if let conversation = store.conversation(id), conversation.isEmpty, conversation.pickedUp == nil { store.removeConversation(id) }
        guard wasCurrent else { return }
        if let next = workspace.selected { selectPanelTab(next) } else {
            withAnimation(Motion.summon(reduceMotion)) { mode = .home }
            focusToken += 1
        }
    }

    /// Opens a conversation as a tab in the workspace window.
    func openInWorkspace(_ id: UUID) {
        actions.expand(id)
    }

    func moveSelection(_ delta: Int) {
        let count = homeItems.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func openSelected() {
        let items = homeItems
        guard items.indices.contains(selection) else { return }
        open(items[selection])
    }

    func open(_ item: HomeItem) {
        switch item {
        case .offer(let offer):
            peers.markSeen(offer)
            withAnimation(Motion.summon(reduceMotion)) { mode = .offer(offer.id) }
        case .received(let received):
            store.markRead(received.id)
            withAnimation(Motion.summon(reduceMotion)) { mode = .received(received.id) }
        case .chat(let conversation):
            openChat(conversation.id)
        case .clipboard:
            if let clip = NSPasteboard.general.string(forType: .string) {
                draft = "About this:\n\(clip.prefix(4_000))\n\n"
                focusToken += 1
            }
        }
    }

    func openChat(_ id: UUID) {
        withAnimation(Motion.continueOpen(reduceMotion)) { mode = .chat(id) }
        session(id).focusedMessageID = nil
        composerFocused(id, inWindow: false)
        store.markSeen(id)
        focusToken += 1
    }

    // MARK: Chat actions

    func submitInChat(_ id: UUID) {
        guard applySlash(in: id) else { return }
        let input = session(id)
        let text = input.draft
        guard let conversation = store.conversation(id) else { return }
        // A typed reply answers a pending question ("or type your own answer").
        if let question = conversation.pendingQuestions.first, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.answer(question.id, with: text, in: id)
            input.draft = ""
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !input.pendingAttachments.isEmpty else { return }
        guard !store.isRunning(id) else { return }
        let attachments = input.pendingAttachments
        let skills = input.skills
        if conversation.provider.capabilities.requiresFolder && conversation.folder == nil {
            if conversation.messages.last?.role == .user {
                actions.chooseFolder(id)
                return
            }
            input.resetComposer()
            store.ask(text, attachments: attachments, skills: skills, in: id)
            actions.chooseFolder(id)
            return
        }
        input.resetComposer()
        store.ask(text, attachments: attachments, skills: skills, in: id)
        input.focusedMessageID = nil
    }

    /// ↑↓ between answers in a chat.
    func moveAnswerFocus(_ delta: Int, in id: UUID) {
        guard let conversation = store.conversation(id) else { return }
        let input = session(id)
        let answers = conversation.messages.filter { $0.role == .assistant && $0.error == nil }
        guard !answers.isEmpty else { return }
        if let current = input.focusedMessageID, let index = answers.firstIndex(where: { $0.id == current }) {
            input.focusedMessageID = answers[max(0, min(answers.count - 1, index + delta))].id
        } else {
            input.focusedMessageID = (delta < 0 ? answers.last : answers.first)?.id
        }
    }

    /// ⌘K keeps the focused answer, or the latest one.
    func keepFocused(in id: UUID) {
        guard let conversation = store.conversation(id) else { return }
        let input = session(id)
        let target = input.focusedMessageID ?? conversation.messages.last(where: { $0.role == .assistant && $0.error == nil })?.id
        guard let target else { return }
        withAnimation(Motion.keep(reduceMotion)) { store.toggleKeep(target, in: id) }
        input.focusedMessageID = target
    }

    /// ⌘⇧R: put the focused (or latest) answer in the room. For a Claude Code or Codex chat, the run itself goes in
    /// at the last level used; if it is already there, the room opens instead.
    func sendFocusedToRoom(in id: UUID) {
        guard roomActive, let conversation = store.conversation(id) else { return }
        if conversation.provider.roomShare == .liveRun {
            if room?.runs[id] != nil {
                actions.openRoom()
            } else {
                actions.shareRun(conversation, lastShareLevel)
            }
            return
        }
        let input = session(id)
        guard let message = conversation.messages.first(where: { $0.id == input.focusedMessageID })
                ?? conversation.messages.last(where: { $0.role == .assistant && $0.error == nil && !$0.text.isEmpty }) else { return }
        actions.sendToRoom(message, conversation)
    }

    func copy(_ message: Message) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copiedMessageID = message.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedMessageID == message.id { copiedMessageID = nil }
        }
    }

    func copyFocused(in id: UUID) {
        guard let conversation = store.conversation(id),
              let message = conversation.messages.first(where: { $0.id == session(id).focusedMessageID })
                ?? conversation.messages.last(where: { $0.role == .assistant && $0.error == nil }) else { return }
        copy(message)
    }

    func selectProvider(_ provider: ProviderKind, for id: UUID?) {
        showProviderMenu = false
        guard store.status(provider).isUsable else { return }
        if let id {
            store.setProvider(provider, for: id, asDefault: true)
            if provider.capabilities.requiresFolder, store.conversation(id)?.folder == nil { actions.chooseFolder(id) }
        } else {
            store.defaultProvider = provider
            store.autoRoute = false
            AppDefaults.provider = provider
            if !provider.capabilities.requiresFolder { homeFolder = nil }
        }
        focusToken += 1
    }

    /// ⇧Tab: the next permission level, on home (nil) or in a chat (from its next message).
    func cyclePermissionLevel(in id: UUID?) {
        if let id {
            guard let conversation = store.conversation(id), conversation.provider.capabilities.requiresFolder else { return }
            store.setPermissionLevel(conversation.permissionLevel.next, for: id)
        } else {
            homeLevel = homeLevel.next
        }
    }

    /// Auto: OpenAI picks quick answer vs. coding agent for each new chat.
    func selectAuto() {
        showProviderMenu = false
        guard store.autoAvailable else { return }
        store.autoRoute = true
        focusToken += 1
    }

    // MARK: Receiving

    func decline(_ offer: IncomingOffer) {
        peers.decline(offer)
        if case .offer(offer.id) = mode { withAnimation(Motion.summon(reduceMotion)) { mode = .home } }
    }

    /// Continue opens Quick Chat right away on "Receiving from …"; the chat replaces it when the share lands.
    func accept(_ offer: IncomingOffer, open: Bool) {
        peers.accept(offer, open: open)
        guard open else { return }
        peers.markSeen(offer)
        withAnimation(Motion.summon(reduceMotion)) { mode = .offer(offer.id) }
        actions.show()
    }

    /// A share arrived (Continue) or was opened from a file / the list: start the private continued chat.
    func continueChat(_ share: ShareSummary) {
        let id = store.continueFrom(share)
        draft = ""
        composerFocused(id, inWindow: false)
        withAnimation(Motion.continueOpen(reduceMotion)) { mode = .chat(id) }
        focusToken += 1
    }

    func askSuggested(_ question: String, in id: UUID) {
        session(id).draft = ""
        store.ask(question, in: id)
    }
}

/// What the panel shows of the room you're in.
struct PanelRoom: Equatable {
    var name: String
    var people: Int
    /// Which of your runs are in it (by conversation id), and how much of each is shown.
    var runs: [UUID: RunShareLevel]
}
