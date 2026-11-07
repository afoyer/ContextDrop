import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let peers = PeerService()
    lazy var store = ChatStore(peers: peers)
    lazy var panelModel = PanelModel(store: store)
    private lazy var quickChat = QuickChatPanelController(model: panelModel)
    private lazy var notifications = NotificationPanelController(model: panelModel)
    private lazy var chatWindows = ChatWindowController(model: panelModel)
    private var statusItem: NSStatusItem?
    private(set) lazy var shortcuts = ShortcutSettings(hotKey: HotKey { [weak self] in self?.quickChat.toggle() })
    private var openItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var pendingFiles: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        setUpStatusItem()
        shortcuts.onChange = { [weak self] _ in self?.updateOpenItemTitle() }
        updateOpenItemTitle()

        panelModel.onExpand = { [weak self] id in self?.chatWindows.open(id) }
        panelModel.onOpenSettings = { [weak self] in self?.openSettings() }
        panelModel.onChooseFolder = { [weak self] id in self?.chooseFolder(for: id) }

        peers.onOfferArrived = { [weak self] offer in
            guard let self else { return }
            self.notifications.show(offer)
            self.updateStatusIcon()
        }
        peers.onShareReceived = { [weak self] share, open in
            guard let self else { return }
            self.store.receive(share)
            if open {
                self.panelModel.continueChat(share)
                self.quickChat.show()
            }
            self.updateStatusIcon()
        }
        peers.start()
        Task { [weak self] in
            await OpenRouterSettings.preload()
            self?.store.refreshProviderStatus()
        }

        for url in pendingFiles { openShareFile(url) }
        pendingFiles.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
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

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "drop", accessibilityDescription: "ContextDrop")
        item.button?.toolTip = "ContextDrop (\(peers.localDisplayName))"
        let menu = NSMenu()
        openItem = menu.addItem(withTitle: "Open Quick Chat", action: #selector(openQuickChat), keyEquivalent: "")
        menu.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ContextDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    private func updateOpenItemTitle() {
        openItem?.title = "Open Quick Chat    \(shortcuts.shortcut.display)"
    }

    private func updateStatusIcon() {
        let unread = peers.offers.contains { $0.phase == .pending } || store.received.contains { !$0.read }
        statusItem?.button?.image = NSImage(systemSymbolName: unread ? "drop.fill" : "drop", accessibilityDescription: "ContextDrop")
    }

    @objc private func openQuickChat() { quickChat.show() }

    @objc private func newChat() {
        panelModel.mode = .home
        panelModel.draft = ""
        quickChat.show()
    }

    @objc private func openSettingsAction() { openSettings() }

    func openSettings() {
        quickChat.hide()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ContextDrop Settings"
            window.contentView = NSHostingView(rootView: SettingsView(store: store, shortcuts: shortcuts))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Deep chat folder

    private func chooseFolder(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the project folder the agent can read."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            store.setFolder(url, for: id)
        }
        quickChat.show()
    }
}
