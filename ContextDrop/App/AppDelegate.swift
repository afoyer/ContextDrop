import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let notices = NoticeCenter()
    private(set) lazy var peers = PeerService(notices: notices)
    lazy var store = ChatStore(peers: peers)
    lazy var panelModel = PanelModel(store: store)
    lazy var roomStore = RoomStore(peers: peers)
    private lazy var quickChat = QuickChatPanelController(model: panelModel)
    private lazy var notifications = NotificationPanelController(model: panelModel)
    private lazy var workspace = WorkspaceWindowController(model: panelModel)
    private lazy var roomWindow = RoomWindowController(store: roomStore, reduceMotion: { [weak self] in self?.store.reduceMotion ?? false })
    private lazy var menuBar = MenuBarController(model: panelModel, room: roomStore)
    private(set) lazy var shortcuts = ShortcutSettings(hotKey: HotKey { [weak self] in self?.quickChat.toggle() })
    private lazy var setup = SetupWindowController(model: SetupModel(store: store, shortcuts: shortcuts))
    private var settingsWindow: NSWindow?
    private var pendingFiles: [URL] = []
    private var launched = false
    private var notificationsAllowed: Bool?

    /// The app is only hosting the unit tests: no menu bar, no discovery, no Keychain.
    private static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        launched = true
        setUpMenuBar()
        shortcuts.onChange = { [weak self] shortcut in self?.menuBar.shortcut = shortcut.display }

        panelModel.actions.expand = { [weak self] id in self?.openInWorkspace(id) }
        panelModel.actions.openSettings = { [weak self] in self?.openSettings() }
        panelModel.actions.chooseFolder = { [weak self] id in self?.chooseFolder(for: id) }
        panelModel.actions.captureScreenshot = { [weak self] in self?.captureScreenshot() }
        panelModel.actions.pickImages = { [weak self] in self?.pickImages() }
        panelModel.actions.addFolderShortcut = { [weak self] in self?.addFolderShortcut() }
        panelModel.actions.show = { [weak self] in self?.quickChat.show() }
        panelModel.actions.openRoom = { [weak self] in self?.openRoom() }
        panelModel.actions.sendToRoom = { [weak self] message, conversation in self?.sendToRoom(message, from: conversation) }
        panelModel.actions.sendTabToRoom = { [weak self] conversation in self?.sendTabToRoom(conversation) }
        panelModel.actions.shareRun = { [weak self] conversation, level in self?.shareRun(conversation, level: level) }
        panelModel.actions.unshareRun = { [weak self] id in self?.unshareRun(id) }
        panelModel.actions.setShareLevel = { [weak self] id, level in self?.setShareLevel(level, for: id) }

        // What counts as "on screen" (never unseen), and which empty chats must survive.
        store.visibleConversations = { [weak self] in
            guard let self else { return [] }
            var ids: Set<UUID> = []
            if self.quickChat.isVisible, let id = self.panelModel.panelConversationID { ids.insert(id) }
            if let id = self.workspace.visibleConversation { ids.insert(id) }
            return ids
        }
        store.keepEmptyConversations = { [weak self] in
            guard let self else { return [] }
            var ids = Set(self.panelModel.workspace.tabs)
            if let id = self.panelModel.panelConversationID { ids.insert(id) }
            return ids
        }
        store.onActivityChanged = { [weak self] in self?.menuBar.refresh() }
        store.onNeedsYou = { [weak self] id, title in self?.needsYou(id, title) }

        peers.onOfferArrived = { [weak self] offer in
            guard let self else { return }
            self.notifications.show(offer)
            self.menuBar.refresh()
        }
        peers.onShareReceived = { [weak self] shares, open in
            guard let self else { return }
            shares.forEach(self.store.receive)
            if open, shares.count > 1 {
                // "Open as Tabs": one private chat per tab that was shared.
                self.quickChat.hide()
                self.panelModel.mode = .home
                let ids = shares.map { self.store.continueFrom($0) }
                ids.reversed().forEach { self.panelModel.workspace.open($0) }
                self.workspace.show()
            } else if open, let share = shares.first {
                self.panelModel.continueChat(share)
                self.quickChat.show()
            }
            self.menuBar.refresh()
        }
        // Until setup is done or put off, discovery waits for the Nearby Macs step, so macOS asks for
        // Local Network access when the screen explains why.
        if AppDefaults.didFinishSetup || AppDefaults.setupDeferred { peers.start() }
        setUpSetupWindow()

        // The room reads this Mac's Claude Code runs (to summarise the ones put in the room) and
        // opens what is taken home as a private chat. It never sends a private chat on its own.
        roomStore.chats = store
        roomStore.onChange = { [weak self] in
            guard let self else { return }
            self.refreshPanelRoom()
            self.roomWindow.roomChanged()
            self.menuBar.refresh()
        }
        roomWindow.onOpenOwnRun = { [weak self] tileID in
            guard let self, let id = self.roomStore.runs.conversationID(for: tileID), self.store.conversation(id) != nil else { return }
            self.openInWorkspace(id)
        }
        roomWindow.onTakeHome = { [weak self] share in
            guard let self else { return }
            self.openInWorkspace(self.store.continueFrom(share))
        }
        roomStore.onInvitation = { [weak self] invitation in
            guard let self else { return }
            self.notifications.show(invitation, store: self.roomStore) { [weak self] in self?.roomWindow.show() }
            self.menuBar.refresh()
        }

        #if DEBUG
        DebugRoomDemo.start(room: roomStore, openRoom: { [weak self] in self?.openRoom() }, showRoom: { [weak self] in self?.roomWindow.show() })
        #endif

        UNUserNotificationCenter.current().delegate = self
        Task { [weak self] in
            await OpenAISettings.preload()
            self?.store.refreshProviderStatus()
        }

        for url in pendingFiles { openShareFile(url) }
        pendingFiles.removeAll()

        if !AppDefaults.didFinishSetup && !AppDefaults.setupDeferred { showSetup() }
    }

    // MARK: Setup

    private func setUpSetupWindow() {
        let model = setup.model
        model.onStartDiscovery = { [weak self] in self?.peers.start() }
        model.onLater = { [weak self] in
            guard let self else { return }
            self.setup.close()
            self.peers.start()
            self.menuBar.refresh()
        }
        model.onFinish = { [weak self] in
            guard let self else { return }
            self.setup.close()
            self.peers.start()
            self.menuBar.refresh()
            self.quickChat.show()
        }
    }

    /// First launch, Settings › General › Run Setup Again…, or the menu bar's Finish Setup.
    func showSetup() {
        quickChat.hide()
        settingsWindow?.close()
        setup.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        store.stopAll() // no agent keeps running (or editing) after the app is gone
        roomStore.leave()
        peers.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: .contextdrop files (AirDrop, Finder, share menu)

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { $0.pathExtension.lowercased() == "contextdrop" }
        guard launched else { pendingFiles += files; return }
        files.forEach(openShareFile)
    }

    private func openShareFile(_ url: URL) {
        guard let share = store.ingestFile(url) else { quickChat.show(); return }
        panelModel.continueChat(share)
        quickChat.show()
    }

    // MARK: Workspace window

    /// ⌘↵: the chat moves from the panel into a tab.
    private func openInWorkspace(_ id: UUID) {
        if panelModel.panelConversationID == id { panelModel.mode = .home }
        quickChat.hide()
        workspace.open(id)
        menuBar.refresh()
    }

    // MARK: Menu bar

    private func setUpMenuBar() {
        menuBar.shortcut = shortcuts.shortcut.display
        var actions = MenuBarActions()
        actions.openChat = { [weak self] id in self?.openInWorkspace(id) }
        actions.openQuickChat = { [weak self] in self?.quickChat.show() }
        actions.openWindow = { [weak self] in
            self?.quickChat.hide()
            self?.workspace.show()
        }
        actions.newChat = { [weak self] in
            self?.panelModel.newChat()
            self?.quickChat.show()
        }
        actions.openSettings = { [weak self] in self?.openSettings() }
        actions.finishSetup = { [weak self] in self?.showSetup() }
        actions.openRoom = { [weak self] in self?.openRoom() }
        actions.dropCurrent = { [weak self] in
            guard let self else { return }
            let model = self.panelModel
            let id = model.workspace.selected ?? model.panelConversationID ?? self.store.recentConversations.first?.id
            guard let id, self.store.conversation(id)?.messages.isEmpty == false else { return }
            model.beginShare(id)
            self.quickChat.show()
        }
        menuBar.actions = actions
        // R3 board 5: drop a file on the icon to ask about it; ⌥ starts a new tab instead.
        menuBar.onDropFiles = { [weak self] urls, newTab in
            guard let self else { return }
            let model = self.panelModel
            if newTab {
                model.handleDrop(urls, action: .newTab, in: nil)
                return
            }
            switch model.mode {
            case .home, .chat: break
            default: model.newChat()
            }
            model.handleDrop(urls, action: .attach, in: model.panelConversationID)
            self.quickChat.show()
        }
        // R5 board 6 B: a tab dragged out of its window brings the room up to drop it on.
        TabDrag.onLeaveSourceWindow = { [weak self] in
            guard let self, self.roomStore.isActive else { return }
            self.roomWindow.bringForwardForDrop()
        }
        // R5 board 6 B: a tab dropped on the icon goes in the room, as the room chip would put it there.
        menuBar.onDropTab = { [weak self] id in
            guard let self, let conversation = self.store.conversation(id) else { return }
            switch conversation.provider.roomShare {
            case .liveRun: self.shareRun(conversation, level: self.panelModel.lastShareLevel)
            case .chatCopy: self.sendTabToRoom(conversation)
            case .none: break
            }
        }
    }

    // MARK: Needs you

    /// A chat is waiting on the user. The menu bar shows it; a notification only when the app isn't in front.
    private func needsYou(_ id: UUID, _ title: String) {
        menuBar.refresh()
        guard !NSApp.isActive else { return }
        let chat = store.conversation(id)?.title ?? "ContextDrop"
        Task { @MainActor [weak self] in
            guard let self, await self.canNotify() else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(chat) needs you"
            content.body = title
            content.userInfo = ["conversation": id.uuidString]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func canNotify() async -> Bool {
        if let notificationsAllowed { return notificationsAllowed }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        notificationsAllowed = granted
        return granted
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["conversation"] as? String
        await MainActor.run {
            guard let raw, let id = UUID(uuidString: raw), self.store.conversation(id) != nil else { return }
            self.openInWorkspace(id)
        }
    }

    // MARK: Room (R4)

    private func openRoom() {
        quickChat.hide()
        if !roomStore.isActive {
            roomStore.openRoom()
            roomStore.inviteAllNearby()
        }
        refreshPanelRoom()
        roomWindow.show()
    }

    private func refreshPanelRoom() {
        let room = roomStore.isActive
            ? PanelRoom(name: roomStore.room?.name ?? "Room", people: roomStore.presentCount, runs: roomStore.sharedRuns)
            : nil
        if panelModel.room != room { panelModel.room = room }
    }

    /// "To room" on an answer: only this answer goes in the room; the chat it came from stays private.
    private func sendToRoom(_ message: Message, from conversation: Conversation) {
        guard roomStore.isActive, !message.text.isEmpty else { return }
        guard roomStore.addCard(kind: .keptAnswer, text: message.text, caption: conversation.title) != nil else { return }
        notices.text = "Added to the room. The rest of this chat stays private."
    }

    /// "To room" on an OpenAI tab: the chat becomes a chat tile everyone can reply in. It keeps answering from
    /// this Mac. (Claude Code and Codex tabs go in through the room chip, `shareRun`.)
    private func sendTabToRoom(_ conversation: Conversation) {
        guard roomStore.isActive, conversation.provider.roomShare == .chatCopy,
              roomStore.shareChat(conversation) != nil else { return }
        notices.text = "This chat is in the room as a copy. Anyone there can reply; it answers from your Mac."
        roomWindow.show()
    }

    /// The room chip (and ⌘⇧R on a run tab): puts a run in the room at `level`. A run already there keeps its
    /// level. The room window stays shut, since this is used from Quick Chat.
    private func shareRun(_ conversation: Conversation, level: RunShareLevel) {
        guard roomStore.isActive, conversation.provider.roomShare == .liveRun else { return }
        if roomStore.sharedRuns[conversation.id] != nil {
            notices.text = "This run is already in the room."
            return
        }
        guard roomStore.shareRun(conversation, level: level) != nil else { return }
        panelModel.lastShareLevel = level
        notices.text = level == .withLog
            ? "This run is in the room with its log. Others can ask to continue it; nothing they send runs until you OK it. Secrets in the log are hidden."
            : "This run is in the room: its steps and changed files. Others can ask to continue it; nothing they send runs until you OK it."
    }

    /// "Take out of room" on the chip: the tile goes for everyone; the run carries on here.
    private func unshareRun(_ conversationID: UUID) {
        guard roomStore.sharedRuns[conversationID] != nil else { return }
        roomStore.unshareRun(conversationID: conversationID)
        notices.text = "This run is out of the room. It keeps going on your Mac."
    }

    /// "Show live log" on the chip.
    private func setShareLevel(_ level: RunShareLevel, for conversationID: UUID) {
        guard let current = roomStore.sharedRuns[conversationID], current != level else { return }
        roomStore.setShareLevel(level, for: conversationID)
        panelModel.lastShareLevel = level
        notices.text = Self.levelNotice(level)
    }

    private static func levelNotice(_ level: RunShareLevel) -> String {
        switch level {
        case .withLog: "The room now sees this run’s log too. Secrets in it are hidden."
        case .steps: "The room no longer gets this run’s log."
        }
    }

    // MARK: Settings

    func openSettings() {
        quickChat.hide()
        let width = SettingsView.width
        if let window = settingsWindow {
            // Reused window: the screen may have changed since it was last shown. Keep it on screen.
            let screen = window.screen ?? NSScreen.main
            window.contentMaxSize = NSSize(width: width, height: SettingsView.maxHeight(on: screen))
            if let visible = screen?.visibleFrame {
                var frame = window.frame
                frame.size.height = min(frame.height, visible.height)
                frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
                frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
                if frame != window.frame { window.setFrame(frame, display: true) }
            }
        } else {
            let maxHeight = SettingsView.maxHeight()
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = SettingsView.windowTitle
            let hosting = NSHostingView(rootView: SettingsView(store: store, shortcuts: shortcuts,
                                                             runSetup: { [weak self] in self?.showSetup() }))
            hosting.sizingOptions = [] // the window's own limits below are the single source of truth
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            // Fixed width, so it only resizes vertically, and never taller than the screen.
            window.contentMinSize = NSSize(width: width, height: SettingsView.minHeight)
            window.contentMaxSize = NSSize(width: width, height: maxHeight)
            window.setContentSize(NSSize(width: width, height: min(SettingsView.idealHeight, maxHeight)))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Images

    /// Where the user was typing when they asked for a screenshot or a picker, and how to get back there.
    private func leaveComposer() -> (session: ChatSession, comeBack: () -> Void) {
        let session = panelModel.activeSession
        if panelModel.activeComposerInWindow, workspace.isVisible {
            return (session, { [weak self] in self?.workspace.show() })
        }
        return (session, { [weak self] in self?.quickChat.show() })
    }

    /// Hides our windows, runs the system capture UI (drag an area, or space for a window), then comes back with it attached.
    private func captureScreenshot() {
        guard !panelModel.isCapturing else { return }
        let (session, comeBack) = leaveComposer()
        panelModel.isCapturing = true
        quickChat.hide()
        if panelModel.activeComposerInWindow { workspace.hide() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200)) // let our windows fade out of the shot
            let attachment = await Attachments.captureScreen()
            panelModel.isCapturing = false
            if let attachment {
                panelModel.attach([attachment], to: session)
            } else if !CGPreflightScreenCaptureAccess() {
                notices.text = "Screenshots need Screen Recording access: System Settings › Privacy & Security › Screen Recording › ContextDrop."
            }
            comeBack()
        }
    }

    /// Runs an open panel in front, keeping the Quick Chat panel from closing itself meanwhile.
    private func pick(_ panel: () -> [URL]) -> [URL] {
        panelModel.isCapturing = true
        defer { panelModel.isCapturing = false }
        NSApp.activate(ignoringOtherApps: true)
        return panel()
    }

    private func pickImages() {
        let (session, comeBack) = leaveComposer()
        let files = pick { FilePicker.files(prompt: "Attach", message: "Choose images to show the AI, or files for a coding agent to read.") }
        if !files.isEmpty { panelModel.attachDropped(files, to: session) }
        comeBack()
    }

    /// "/add": pick a folder, save it as a shortcut, and leave "/name " in the input ready to ask.
    private func addFolderShortcut() {
        let (session, comeBack) = leaveComposer()
        let chosen = pick { FilePicker.folders(prompt: "Add Shortcut", message: "Choose a project folder. You’ll reach it by typing /name.") }
        if let url = chosen.first {
            let shortcut = store.folders.add(url)
            session.draft = "/\(shortcut.name) " + session.draft
            notices.text = "Saved /\(shortcut.name) → \(shortcut.display). Rename it in Settings."
        }
        comeBack()
    }

    // MARK: Deep chat folder

    private func chooseFolder(for id: UUID) {
        let inWindow = workspace.isVisible && panelModel.workspace.selected == id && panelModel.panelConversationID != id
        let chosen = pick { FilePicker.folders(prompt: "Use Folder", message: "Choose the project folder the agent works in.") }
        if let url = chosen.first { store.setFolder(url, for: id) }
        if inWindow { workspace.show() } else { quickChat.show() }
    }
}
