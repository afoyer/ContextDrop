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

/// What the floating panel is showing, and the keyboard logic behind it.
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
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var summaryToken: UUID?
    /// Several tabs being shared together.
    var multiShare: MultiSharePrep?
    /// Tabs travelling with the share in `.send` (the first one is the mode's share).
    @ObservationIgnored private var extraShares: [(conversationID: UUID, share: ShareSummary)] = []
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
    /// True while the system screenshot UI is up (the panel is hidden meanwhile).
    var isCapturing = false
    /// Deep chats show the agent's terminal in a pane to the right of the chat (⌘T).
    var showTerminal = AppDefaults.showTerminal {
        didSet { AppDefaults.showTerminal = showTerminal }
    }

    // Wired by the AppDelegate.
    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored var onExpand: ((UUID) -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onChooseFolder: ((UUID) -> Void)?
    @ObservationIgnored var onCaptureScreenshot: (() -> Void)?
    @ObservationIgnored var onPickImages: (() -> Void)?
    @ObservationIgnored var onAddFolderShortcut: (() -> Void)?
    @ObservationIgnored var onShow: (() -> Void)?
    @ObservationIgnored var onOpenRoom: (() -> Void)?
    /// "To room": puts an answer on the table of the room you're in.
    @ObservationIgnored var onSendToRoom: ((Message, Conversation) -> Void)?
    /// "To room" on a whole tab: a Claude Code run becomes a run tile, an OpenAI chat a chat tile.
    @ObservationIgnored var onSendTabToRoom: ((Conversation) -> Void)?
    /// Whether "To room" is offered (you're in a live room).
    var roomActive = false

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
        return conversation.provider.isDeep
    }

    /// Extra width added on the right only (the chat column doesn't move when the terminal opens).
    var rightExtension: CGFloat { terminalVisible ? Self.terminalWidth : 0 }

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
            onHide?()
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
            onHide?()
        case .send(let id, _):
            if let outgoing = peers.outgoing, outgoing.phase == .waiting || outgoing.phase == .sending {
                onHide?() // sending continues in the background
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

    // MARK: Attachments

    func attach(_ items: [Attachment], to target: ChatSession? = nil) {
        let session = target ?? activeSession
        // The limit is for images and files. Pasted links and text are only text, so they don't count.
        let free = items.filter { !$0.countsTowardLimit }
        let limited = items.filter(\.countsTowardLimit)
        let room = Attachments.maxPerMessage - session.pendingAttachments.filter(\.countsTowardLimit).count
        if !limited.isEmpty, room <= 0 { notices.text = "Up to \(Attachments.maxPerMessage) images or files per message." }
        guard !free.isEmpty || room > 0 else { return }
        withAnimation(Motion.keep(reduceMotion)) { session.pendingAttachments += free + limited.prefix(max(room, 0)) }
        session.requestFocus()
        focusToken += 1
    }

    func removeAttachment(_ id: UUID, from target: ChatSession? = nil) {
        let session = target ?? activeSession
        withAnimation(Motion.keep(reduceMotion)) { session.pendingAttachments.removeAll { $0.id == id } }
    }

    /// ⌘V with something that should not fill the input: an image (or copied image files), a web link,
    /// or a long block of text. Each becomes a chip above the input. Returns false to let a normal text paste happen.
    func pasteAsAttachment(into target: ChatSession? = nil) -> Bool {
        pasteImageIfAny(into: target) || pasteLinkOrLongText(into: target)
    }

    /// ⌘V seen by a window's key monitor, before the text field pastes. Only acts while a text field is being typed in.
    func pasteKey(in window: NSWindow?, session: ChatSession) -> Bool {
        guard window?.firstResponder is NSTextView else { return false }
        return pasteAsAttachment(into: session)
    }

    private func pasteLinkOrLongText(into target: ChatSession?) -> Bool {
        let session = target ?? activeSession
        guard NSPasteboard.general.availableType(from: [.fileURL]) == nil,
              let text = NSPasteboard.general.string(forType: .string) else { return false }
        guard let item = Attachments.link(text) ?? (Attachments.isLongPaste(text) ? Attachments.pastedText(text) : nil) else { return false }
        // The same link twice is one chip.
        if let link = item.link, session.pendingAttachments.contains(where: { $0.link == link }) { return true }
        attach([item], to: target)
        return true
    }

    private func pasteImageIfAny(into target: ChatSession? = nil) -> Bool {
        guard Attachments.pasteboardHasImage() else { return false }
        // Text wins when the clipboard has both (e.g. copying from a web page).
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty,
           NSPasteboard.general.availableType(from: [.fileURL]) == nil { return false }
        let items = Attachments.fromPasteboard()
        guard !items.isEmpty else { return false }
        attach(items, to: target)
        return true
    }

    /// Images are copied in; other files are attached by reference (a coding agent reads them itself).
    func attachDropped(_ urls: [URL], to target: ChatSession? = nil) {
        let items = urls.compactMap { url in Attachments.isImage(url) ? Attachments.importFile(url) : Attachments.reference(url) }
        if items.isEmpty { notices.text = "Couldn’t attach that." } else { attach(items, to: target) }
    }

    /// What a drop does, for the three drop targets.
    enum DropAction { case attach, runSkill, newTab }

    /// Files dropped on the panel, a tab or the menu bar icon.
    func handleDrop(_ urls: [URL], action: DropAction, in conversationID: UUID?) {
        if let file = urls.first(where: { $0.pathExtension.lowercased() == "contextdrop" }) {
            if let share = store.ingestFile(file) { continueChat(share) }
            return
        }
        var isDir: ObjCBool = false
        let folders = urls.filter { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
            && !((try? $0.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false) }
        let files = urls.filter { !folders.contains($0) }
        if let folder = folders.first {
            if action == .newTab || conversationID == nil {
                // "New tab here" / home: a coding agent in that folder.
                let shortcut = store.folders.add(folder)
                if action == .newTab, let deep = store.preferredDeepProvider() {
                    let id = store.newConversation(provider: deep)
                    store.setFolder(folder, for: id)
                    openInWorkspace(id)
                } else {
                    homeFolder = shortcut
                    notices.text = "Using /\(shortcut.name) → \(shortcut.display)."
                }
            } else if let id = conversationID {
                // "Use as working folder".
                if store.conversation(id)?.provider.isDeep == false, let deep = store.preferredDeepProvider() {
                    store.setProvider(deep, for: id)
                }
                store.setFolder(folder, for: id)
                notices.text = "Working folder: \(FolderDrop.display(folder))."
            }
        }
        guard !files.isEmpty else { return }
        switch action {
        case .newTab:
            let provider = files.contains(where: { !Attachments.isImage($0) }) ? (store.preferredDeepProvider() ?? store.defaultProvider) : store.defaultProvider
            let id = store.newConversation(provider: provider)
            if provider.isDeep, let folder = AppDefaults.lastFolder ?? AppDefaults.folder { store.setFolder(folder, for: id) }
            attachDropped(files, to: session(id))
            openInWorkspace(id)
        case .attach, .runSkill:
            let target = session(conversationID)
            attachDropped(files, to: target)
            if action == .runSkill {
                target.draft = target.draft.isEmpty ? "/" : target.draft + " /"
                SkillCatalog.shared.refresh(projectFolder: conversationID.flatMap { store.conversation($0)?.folder })
            }
            target.requestFocus()
        }
    }

    /// Opens a conversation as a tab in the workspace window.
    func openInWorkspace(_ id: UUID) {
        onExpand?(id)
    }

    func submitFromHome() {
        let parsed = SlashCommand.parseChain(draft, folders: store.folders)
        let text = parsed.rest
        var explicitProvider: ProviderKind?
        var autoRequested = false
        var folder = homeFolder?.url
        var skills = homeSession.skills

        for command in parsed.commands {
            switch command {
            case .skill(let name):
                if !skills.contains(name) { skills.append(name) }
            case .action(let action):
                draft = text
                switch action {
                case .room: onOpenRoom?()
                case .share, .folder: notices.text = "Open a chat first, then use /\(action.rawValue)."
                }
                return
            case .addFolder:
                homeFolder = folder.flatMap { store.folders.shortcut(for: $0) }
                draft = text
                onAddFolderShortcut?()
                return
            case .auto:
                explicitProvider = nil
                autoRequested = true
            case .provider(let provider):
                explicitProvider = provider
                autoRequested = false
            case .folder(let shortcut):
                guard shortcut.exists else { notices.text = "/\(shortcut.name) points to a folder that no longer exists (\(shortcut.display))."; return }
                folder = shortcut.url
            }
        }
        if let explicitProvider, !store.status(explicitProvider).isUsable {
            notices.text = "\(explicitProvider.displayName): \(store.status(explicitProvider).detail)"
            return
        }
        if autoRequested && !store.autoAvailable {
            notices.text = "Auto is unavailable until OpenAI is ready."
            return
        }
        // Skills run in Claude Code.
        if !skills.isEmpty && explicitProvider?.supportsSkills != true {
            let provider = ProviderKind.forSkills
            guard store.status(provider).isUsable else {
                notices.text = "Skills need \(provider.displayName): \(store.status(provider).detail)"
                return
            }
            explicitProvider = provider
            autoRequested = false
        }
        if text.isEmpty && pendingAttachments.isEmpty && !parsed.commands.isEmpty {
            if !skills.isEmpty {
                homeSession.skills = skills
                draft = ""
                focusToken += 1
                return
            }
            homeFolder = folder.flatMap { store.folders.shortcut(for: $0) }
            if let explicitProvider {
                selectProvider(explicitProvider, for: nil)
            } else if folder != nil && !autoRequested && !store.autoActive {
                guard let deep = (store.defaultProvider.isDeep ? store.defaultProvider : nil)
                    ?? store.preferredDeepProvider() else {
                    notices.text = "Folder shortcuts need Claude Code or Codex on this Mac."
                    return
                }
                selectProvider(deep, for: nil)
            }
            if autoRequested { selectAuto() }
            draft = ""
            focusToken += 1
            return
        }

        if text.isEmpty && pendingAttachments.isEmpty {
            openSelected()
            return
        }
        // A folder picks a coding agent unless Auto or a provider was explicitly selected.
        if folder != nil && explicitProvider == nil && !autoRequested && !store.autoActive {
            guard let deep = (!store.autoRoute && store.defaultProvider.isDeep ? store.defaultProvider : nil)
                ?? store.preferredDeepProvider() else {
                notices.text = "Folder shortcuts need Claude Code or Codex on this Mac."
                return
            }
            explicitProvider = deep
        }

        let auto = autoRequested || (explicitProvider == nil && store.autoActive)
        let provider = explicitProvider ?? store.defaultProvider
        let id = store.newConversation(provider: provider)
        let attachments = pendingAttachments
        homeSession.resetComposer()
        homeFolder = nil
        withAnimation(Motion.resize(reduceMotion)) { mode = .chat(id) }
        composerFocused(id, inWindow: false)

        if auto {
            if let folder { store.setFolder(folder, for: id) }
            Task { @MainActor in
                if await store.askAuto(text, attachments: attachments, in: id) { onChooseFolder?(id) }
            }
            return
        }
        if provider.isDeep {
            if let target = folder ?? AppDefaults.folder ?? AppDefaults.lastFolder {
                store.setFolder(target, for: id)
            }
        }
        store.ask(text, attachments: attachments, skills: skills, in: id)
        // A deep chat without a folder keeps the question and answers it once one is chosen.
        if provider.isDeep && store.conversation(id)?.folder == nil { onChooseFolder?(id) }
    }

    // MARK: Slash commands

    /// The home input's "/" token (see `ChatSession.slashQuery`).
    var slashQuery: String? { homeSession.slashQuery }
    var slashMatches: [SlashItem] { slashMatches(in: homeSession) }

    func slashMatches(in session: ChatSession) -> [SlashItem] {
        session.slashMatches(autoAvailable: store.autoAvailable)
    }

    func moveSlash(_ delta: Int, in target: ChatSession? = nil) {
        let session = target ?? homeSession
        let count = slashMatches(in: session).count
        guard count > 0 else { return }
        session.slashSelection = (session.slashSelection + delta + count) % count
    }

    func selectedSlashItem(in session: ChatSession) -> SlashItem? {
        let matches = slashMatches(in: session)
        return matches.isEmpty ? nil : matches[min(session.slashSelection, matches.count - 1)]
    }

    /// Tab / ↵ on the list: complete only the active token. Skills become chips instead of text.
    func completeSlash(in target: ChatSession? = nil) {
        let session = target ?? homeSession
        guard let item = selectedSlashItem(in: session) else { return }
        session.slashSelection = 0
        if item.token == "add" {
            session.draft = ""
            onAddFolderShortcut?()
            return
        }
        guard let slash = session.draft.lastIndex(of: "/") else { return }
        if item.kind == .skill {
            session.draft = String(session.draft[..<slash])
            if !session.skills.contains(item.token) { session.skills.append(item.token) }
        } else {
            session.draft = String(session.draft[..<slash]) + "/\(item.token) "
        }
        session.requestFocus()
        focusToken += 1
    }

    /// ⌥↵ on a skill: use it with every message in this chat.
    @discardableResult
    func pinSelectedSkill(in session: ChatSession) -> Bool {
        guard let id = session.conversationID, let item = selectedSlashItem(in: session), item.kind == .skill,
              var pinned = store.conversation(id)?.pinnedSkills else { return false }
        if !pinned.contains(item.token) { pinned.append(item.token) }
        store.setPinnedSkills(pinned, for: id)
        if let slash = session.draft.lastIndex(of: "/") { session.draft = String(session.draft[..<slash]) }
        session.slashSelection = 0
        return true
    }

    func unpinSkill(_ name: String, in id: UUID) {
        guard let pinned = store.conversation(id)?.pinnedSkills else { return }
        store.setPinnedSkills(pinned.filter { $0 != name }, for: id)
    }

    /// ↵ from either kind of input.
    func submit(_ session: ChatSession) {
        if let id = session.conversationID { submitInChat(id) } else { submitFromHome() }
    }

    /// Applies a leading slash command typed in an existing chat. Returns true if there is still something to ask.
    private func applySlash(in id: UUID) -> Bool {
        let input = session(id)
        let parsed = SlashCommand.parseChain(input.draft, folders: store.folders)
        guard !parsed.commands.isEmpty else { return true }
        guard let conversation = store.conversation(id) else { return false }
        var provider = conversation.provider
        var folder: URL?
        for command in parsed.commands {
            switch command {
            case .addFolder:
                input.draft = parsed.rest
                onAddFolderShortcut?()
                return false
            case .skill(let name):
                if !input.skills.contains(name) { input.skills.append(name) }
            case .action(let action):
                input.draft = parsed.rest
                switch action {
                case .share: beginShare(id)
                case .room: onOpenRoom?()
                case .folder: onChooseFolder?(id)
                }
                return false
            case .auto:
                notices.text = "Auto picks the assistant for new chats. This chat keeps \(provider.displayName)."
            case .provider(let selected):
                guard store.status(selected).isUsable else {
                    notices.text = "\(selected.displayName): \(store.status(selected).detail)"; return false
                }
                provider = selected
            case .folder(let shortcut):
                guard shortcut.exists else { notices.text = "/\(shortcut.name) points to a folder that no longer exists."; return false }
                if !provider.isDeep {
                    guard let deep = store.preferredDeepProvider() else { notices.text = "Folder shortcuts need Claude Code or Codex on this Mac."; return false }
                    provider = deep
                }
                folder = shortcut.url
            }
        }
        if provider != conversation.provider { store.setProvider(provider, for: id) }
        if let folder { store.setFolder(folder, for: id) }
        input.draft = parsed.rest
        if !input.skills.isEmpty, store.conversation(id)?.provider.supportsSkills != true {
            notices.text = "Skills run in \(ProviderKind.forSkills.displayName). Switch this chat with /\(ProviderKind.forSkills.slashTokens[0]), or start a new one."
            input.skills = []
        }
        if store.conversation(id)?.provider.isDeep == true, store.conversation(id)?.folder == nil {
            if parsed.rest.isEmpty && input.pendingAttachments.isEmpty {
                onChooseFolder?(id)
                return false
            }
        }
        input.requestFocus()
        return !parsed.rest.isEmpty || !input.pendingAttachments.isEmpty
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
        if conversation.provider.isDeep && conversation.folder == nil {
            if conversation.messages.last?.role == .user {
                onChooseFolder?(id)
                return
            }
            input.resetComposer()
            store.ask(text, attachments: attachments, skills: skills, in: id)
            onChooseFolder?(id)
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

    /// ⌘⇧R: put the focused (or latest) answer in the room. For a Claude Code chat, the run itself goes in.
    func sendFocusedToRoom(in id: UUID) {
        guard roomActive, let conversation = store.conversation(id) else { return }
        if conversation.provider.roomShare == .liveRun {
            onSendTabToRoom?(conversation)
            return
        }
        let input = session(id)
        guard let message = conversation.messages.first(where: { $0.id == input.focusedMessageID })
                ?? conversation.messages.last(where: { $0.role == .assistant && $0.error == nil && !$0.text.isEmpty }) else { return }
        onSendToRoom?(message, conversation)
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
            if provider.isDeep, store.conversation(id)?.folder == nil { onChooseFolder?(id) }
        } else {
            store.defaultProvider = provider
            store.autoRoute = false
            AppDefaults.provider = provider
            if !provider.isDeep { homeFolder = nil }
        }
        focusToken += 1
    }

    /// Auto: OpenAI picks quick answer vs. coding agent for each new chat.
    func selectAuto() {
        showProviderMenu = false
        guard store.autoAvailable else { return }
        store.autoRoute = true
        focusToken += 1
    }

    // MARK: Share flow

    /// ⌘⇧S: widen to the checklist and ask OpenAI for the brief while the panel opens.
    // MARK: Sharing several tabs (R3 board 4)

    /// The given tabs arrive ticked; the other open tabs are listed unticked.
    func beginMultiShare(_ ids: [UUID]) {
        let candidates = workspace.tabs.filter { store.conversation($0)?.messages.isEmpty == false }
        guard !candidates.isEmpty else { return }
        multiShare = MultiSharePrep(items: candidates.map { .init(id: $0, included: ids.contains($0)) })
        prep = nil
        extraShares = []
        peers.clearOutgoing()
        withAnimation(Motion.shareMode(reduceMotion)) { mode = .shareTabs }
        focusToken += 1
    }

    /// Writes a summary for each ticked tab, then goes to Choose Person (or AirDrop).
    func prepareMultiShare(airDrop: Bool) {
        guard let multi = multiShare, multi.phase.canStart else { return }
        let chosen = multi.items.filter(\.included).compactMap { store.conversation($0.id) }
        guard !chosen.isEmpty else { return }
        multi.phase = .summarizing(done: 0, total: chosen.count)
        multi.task = Task { @MainActor in
            var built: [(conversationID: UUID, share: ShareSummary)] = []
            for (index, conversation) in chosen.enumerated() {
                let item = SharePrep(conversation: conversation)
                do {
                    item.apply(try await OpenAIClient.fromSettings().summarize(conversation, detail: item.detail))
                } catch {
                    if Task.isCancelled { return }
                    let reason = error.userMessage
                    multi.phase = .failed("Couldn’t summarize “\(conversation.title)”. \(reason)")
                    return
                }
                guard !Task.isCancelled, multiShare === multi else { return }
                built.append((conversation.id, store.buildShare(from: item, conversation: conversation)))
                multi.phase = .summarizing(done: index + 1, total: chosen.count)
            }
            guard let first = built.first else { return }
            if airDrop {
                do { try ShareFile.airDrop(built.map(\.share)) } catch { notices.text = "AirDrop isn’t available on this Mac." }
                multi.phase = .choosing
                return
            }
            extraShares = Array(built.dropFirst())
            peers.clearOutgoing()
            withAnimation(Motion.shareMode(reduceMotion)) { mode = .send(conversationID: first.conversationID, share: first.share) }
        }
    }

    func beginShare(_ id: UUID) {
        multiShare = nil
        extraShares = []
        guard let conversation = store.conversation(id), !conversation.messages.isEmpty else { return }
        let prep = SharePrep(conversation: conversation)
        self.prep = prep
        withAnimation(Motion.shareMode(reduceMotion)) { mode = .share(id) }
        summarize(prep, conversation: conversation)
    }

    /// Brief ↔ Detailed: remembered, and the brief is rewritten at the new level.
    func setShareDetail(_ detail: ShareDetail) {
        guard let prep, prep.detail != detail else { return }
        prep.detail = detail
        AppDefaults.shareDetail = detail
        regenerateSummary()
    }

    func regenerateSummary() {
        guard let prep, let conversation = store.conversation(prep.conversationID) else { return }
        summarize(prep, conversation: conversation)
    }

    private func summarize(_ prep: SharePrep, conversation: Conversation) {
        summaryTask?.cancel()
        let token = UUID()
        summaryToken = token
        let detail = prep.detail
        prep.phase = .summarizing
        summaryTask = Task { @MainActor in
            defer { if summaryToken == token { summaryTask = nil; summaryToken = nil } }
            do {
                let draft = try await OpenAIClient.fromSettings().summarize(conversation, detail: detail)
                guard !Task.isCancelled, summaryToken == token, self.prep === prep else { return }
                withAnimation(Motion.streaming(reduceMotion)) { prep.apply(draft) }
            } catch {
                guard !Task.isCancelled, summaryToken == token, self.prep === prep else { return }
                prep.phase = .failed(error.userMessage)
                // Still allow a hand-written summary.
                if prep.summary.isEmpty { prep.isEditingSummary = true }
            }
        }
    }

    func choosePerson() {
        guard let prep, let conversation = store.conversation(prep.conversationID) else { return }
        if case .failed = prep.phase, !prep.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prep.phase = .ready }
        guard prep.canContinue else { return }
        let share = store.buildShare(from: prep, conversation: conversation)
        peers.clearOutgoing()
        withAnimation(Motion.shareMode(reduceMotion)) { mode = .send(conversationID: conversation.id, share: share) }
    }

    func send(to peer: NearbyPeer) {
        guard case .send(_, let share) = mode else { return }
        withAnimation(Motion.drop(reduceMotion)) { peers.send(share, extras: extraShares.map(\.share), to: peer.peerID) }
    }

    /// Called when the transfer is acknowledged: check, haptic, then back to the chat with a badge.
    func deliveryConfirmed() {
        guard case .send(let id, _) = mode, let outgoing = peers.outgoing, outgoing.phase == .delivered else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        store.markShared(id, with: outgoing.peerName)
        for extra in extraShares { store.markShared(extra.conversationID, with: outgoing.peerName) }
        let wasMulti = multiShare != nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard case .send(let current, _) = mode, current == id else { return }
            peers.clearOutgoing()
            prep = nil
            extraShares = []
            if wasMulti {
                // Shared from the window: the tabs are still there, so the panel just goes away.
                multiShare = nil
                workspace.multiSelection.removeAll()
                mode = .home
                onHide?()
            } else {
                withAnimation(Motion.shareMode(reduceMotion)) { mode = .chat(id) }
            }
            focusToken += 1
        }
    }

    func chooseSomeoneElse() {
        peers.clearOutgoing()
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
        onShow?()
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
