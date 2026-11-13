import AppKit
import SwiftUI

/// R3 board 1: one window, one chat per tab. ⌘T new · ⌘1–9 jump · ⌃Tab next that needs you ·
/// ⌘W close · ⌘⇧T reopen · ⌥⌘A activity · two-finger swipe over the tab strip.
@MainActor
final class WorkspaceWindowController: NSObject, NSWindowDelegate {
    private let model: PanelModel
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var swipe: TabSwipeTracker?

    init(model: PanelModel) { self.model = model }

    private var workspace: WorkspaceModel { model.workspace }
    var isVisible: Bool { window?.isVisible == true }
    var isKey: Bool { window?.isKeyWindow == true }

    /// The chat showing in the window right now (for "seen" and notifications).
    var visibleConversation: UUID? { isVisible && window?.isMiniaturized == false ? workspace.selected : nil }

    func open(_ id: UUID) {
        workspace.open(id)
        show()
    }

    func show() {
        if workspace.tabs.isEmpty { newTab() }
        let window = self.window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.session(workspace.selected).requestFocus()
    }

    private func makeWindow() -> NSWindow {
        let view = WorkspaceView(model: model, controller: self)
            .frame(minWidth: 720, minHeight: 480)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "ContextDrop"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ContextDropWorkspace")
        if !window.setFrameUsingName("ContextDropWorkspace") { window.center() }
        window.delegate = self
        self.window = window
        installMonitors()
        return window
    }

    /// Out of the way for a screenshot or a system picker; `show()` brings it back.
    func hide() { window?.orderOut(nil) }

    // MARK: Tabs

    /// ⌘T: a new chat next to the current one, with the same provider and folder.
    func newTab() {
        let current = model.store.conversation(workspace.selected)
        let id = model.store.newConversation(provider: current?.provider)
        if let folder = current?.folder, current?.provider.capabilities.requiresFolder == true { model.store.setFolder(folder, for: id) }
        workspace.open(id)
        model.session(id).requestFocus()
    }

    /// ⌘W: closes a tab. A chat that is still working asks whether to keep it running.
    func closeTab(_ id: UUID) {
        let store = model.store
        if store.isRunning(id) {
            let alert = NSAlert()
            alert.messageText = "Keep “\(store.conversation(id)?.title ?? "this chat")” running in the background?"
            alert.informativeText = "You can find it in the menu bar under Brewing, and reopen it with ⌘⇧T."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Stop")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: store.stop(id)
            default: return
            }
        }
        workspace.close(id)
        if store.conversation(id)?.isEmpty == true, store.conversation(id)?.pickedUp == nil { store.removeConversation(id) }
        if workspace.tabs.isEmpty { window?.orderOut(nil) }
    }

    func reopenTab() {
        _ = workspace.reopen { [model] in model.store.conversation($0) != nil }
    }

    func nextNeedingYou(backwards: Bool) {
        if let id = workspace.nextNeedingYou({ [model] in model.store.conversation($0)?.needsUser == true }), id != workspace.selected {
            workspace.select(id)
        } else if let index = workspace.selectedIndex, !workspace.tabs.isEmpty {
            // Nothing waiting: plain next / previous tab, wrapping.
            let count = workspace.tabs.count
            workspace.select(index: (index + (backwards ? -1 : 1) + count) % count)
        }
    }

    // MARK: Keys and swipe

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
        swipe = TabSwipeTracker(model: model, offset: \.windowSwipe, window: { [weak self] in self?.window },
                                current: { [weak self] in self?.workspace.selected },
                                select: { [weak self] id in self?.workspace.select(id) })
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 48, flags.contains(.control) { // ⌃Tab / ⌃⇧Tab
            nextNeedingYou(backwards: flags.contains(.shift))
            return true
        }
        if flags == [.command, .option], key == "a" || event.keyCode == 0 {
            if model.store.conversation(workspace.selected)?.provider.capabilities.requiresFolder == true { model.toggleTerminal() }
            return true
        }
        if flags == [.command, .shift] {
            switch key {
            case "t": reopenTab(); return true
            case "]", "}": workspace.move(by: 1); return true
            case "[", "{": workspace.move(by: -1); return true
            default: return false
            }
        }
        guard flags == .command else { return false }
        switch key {
        case "v":
            // A link or a long text becomes a chip instead of filling the input.
            guard let id = workspace.selected else { return false }
            return model.pasteKey(in: window, session: model.session(id))
        case "t": newTab(); return true
        case "w":
            if let id = workspace.selected { closeTab(id) } else { window?.orderOut(nil) }
            return true
        case "1", "2", "3", "4", "5", "6", "7", "8":
            workspace.select(index: Int(key)! - 1); return true
        case "9":
            workspace.select(index: workspace.tabs.count - 1); return true
        default:
            return false
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The window just hides; tabs and anything running stay.
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = workspace.selected { model.store.markSeen(id) }
    }
}

// MARK: - Content

struct WorkspaceView: View {
    @Bindable var model: PanelModel
    let controller: WorkspaceWindowController

    private var workspace: WorkspaceModel { model.workspace }
    private var store: ChatStore { model.store }

    var body: some View {
        VStack(spacing: 0) {
            header
            TabStrip(model: model, selected: workspace.selected,
                     onSelect: { workspace.select($0) }, onNew: { controller.newTab() }, onClose: { controller.closeTab($0) })
            HairlineDivider()
            page
        }
        .background(MaterialBackground(material: .sidebar))
        .ignoresSafeArea(.container, edges: .top)
        .fileDropTargets(model: model, conversationID: { [workspace] in workspace.selected }, cornerRadius: 0)
        .onChange(of: workspace.selected) { _, id in
            if let id {
                store.markSeen(id)
                model.session(id).requestFocus()
                model.slideIn(\.windowSwipe)
            } else {
                model.windowSwipe = 0
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let conversation = store.conversation(workspace.selected) {
                Text(conversation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(minWidth: 60, alignment: .leading)
                    .layoutPriority(1)
                // Badges and faces give way before the title or the controls do.
                ViewThatFits(in: .horizontal) {
                    ChatBadges(conversation: conversation, reduceMotion: model.reduceMotion)
                    PrivateBadge()
                    Color.clear.frame(width: 0, height: 0)
                }
                Spacer(minLength: 8)
                if conversation.provider.capabilities.requiresFolder {
                    FolderChip(model: model, conversation: conversation)
                    PermissionLevelMenu(store: store, conversation: conversation)
                }
                providerMenu(conversation)
                faces
                if conversation.provider.capabilities.requiresFolder {
                    Button { model.toggleTerminal() } label: { Image(systemName: model.showTerminal ? "sidebar.right" : "terminal") }
                        .buttonStyle(.borderless)
                        .help(model.showTerminal ? "Hide activity (⌥⌘A)" : "Show activity (⌥⌘A)")
                        .accessibilityLabel(model.showTerminal ? "Hide activity" : "Show activity")
                }
                if conversation.provider.roomShare == .liveRun {
                    RoomShareChip(model: model, conversation: conversation)
                } else if model.roomActive, conversation.provider.roomShare == .chatCopy, !conversation.messages.isEmpty {
                    Button { model.actions.sendTabToRoom(conversation) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.grid.2x2")
                            Text("To room")
                        }
                    }
                    .controlSize(.small)
                    .help("Put this chat in the room. Anyone there can reply; it answers from your Mac.")
                }
                Button { share(conversation) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "drop")
                        Text(workspace.multiSelection.count > 1 ? "Drop \(workspace.multiSelection.count) tabs" : "Drop")
                    }
                }
                .controlSize(.small)
                .help("Share with someone nearby (⌘⇧S). ⌘-click tabs to share several.")
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(conversation.messages.isEmpty && workspace.multiSelection.count < 2)
            } else {
                Spacer()
            }
        }
        .padding(.leading, 84) // traffic lights
        .padding(.trailing, 14)
        .frame(height: 46)
    }

    private func providerMenu(_ conversation: Conversation) -> some View {
        Menu {
            ForEach(ProviderKind.allCases, id: \.self) { kind in
                Button {
                    model.selectProvider(kind, for: conversation.id)
                } label: {
                    Text(kind.displayName)
                    Text(store.status(kind).detail)
                    if conversation.provider == kind { Image(systemName: "checkmark") }
                }
                .disabled(!store.status(kind).isReady)
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(store.status(conversation.provider).isReady ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(conversation.provider.displayName)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9).frame(height: 22)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .help("Provider for this tab")
    }

    /// Who's nearby, as small faces.
    private var faces: some View {
        let nearby = model.peers.nearbyPeers
        return HStack(spacing: -6) {
            ForEach(nearby.prefix(4)) { peer in
                AvatarView(name: peer.name, size: 22)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .help(peer.name)
            }
            if nearby.count > 4 {
                Text("+\(nearby.count - 4)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nearby.isEmpty ? "Nobody nearby" : "\(nearby.count) nearby")
    }

    private func share(_ conversation: Conversation) {
        let ids = workspace.tabs.filter { workspace.multiSelection.contains($0) }
        if ids.count > 1 {
            model.beginMultiShare(ids)
        } else {
            model.beginShare(conversation.id)
        }
        model.actions.show()
    }

    // MARK: Page

    private var page: some View {
        ZStack {
            if let id = workspace.selected, let conversation = store.conversation(id) {
                HStack(spacing: 0) {
                    ChatView(model: model, conversationID: id, style: .window, fillsHeight: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.showTerminal, conversation.provider.capabilities.requiresFolder {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                        TerminalPane(model: model, conversation: conversation)
                            .frame(width: PanelModel.terminalWidth)
                            .transition(.opacity)
                    }
                }
                .id(id)
                .modifier(SwipeFeedback(model: model, offset: model.windowSwipe, current: id))
            } else {
                VStack(spacing: 8) {
                    Text("No chats open").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 4) { Text("New tab"); Kbd("⌘T") }.foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(Motion.shareMode(model.reduceMotion), value: model.showTerminal)
    }
}

// MARK: - Tab strip

struct TabStrip: View {
    let model: PanelModel
    /// The tab showing where this strip is (the window and Quick Chat each have one).
    let selected: UUID?
    var compact = false
    let onSelect: (UUID) -> Void
    let onNew: () -> Void
    let onClose: (UUID) -> Void
    @State private var hovered: UUID?

    private var workspace: WorkspaceModel { model.workspace }

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(workspace.tabs.enumerated()), id: \.element) { index, id in
                            if let conversation = model.store.conversation(id) {
                                tab(conversation, index: index).id(id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onChange(of: selected) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } }
                }
                .onAppear { if let selected { proxy.scrollTo(selected) } }
            }
            Button(action: onNew) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New tab (⌘T)")
                .accessibilityLabel("New tab")
            pageDots
                .padding(.trailing, 12)
        }
        .frame(height: compact ? 38 : 44)
    }

    private func tab(_ conversation: Conversation, index: Int) -> some View {
        let id = conversation.id
        let selected = self.selected == id
        let multi = workspace.multiSelection.contains(id)
        return HStack(spacing: 8) {
            StateDot(state: model.store.tabState(id), reduceMotion: model.reduceMotion)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title.isEmpty ? "New chat" : conversation.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if !compact {
                    Text(caption(conversation))
                        .font(.system(size: 10.5))
                        .foregroundStyle(model.store.tabState(id) == .needsYou ? NeedsYou.tint : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: compact ? 130 : 170, alignment: .leading)
            if hovered == id {
                Button { onClose(id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .help("Close tab (⌘W)")
                    .accessibilityLabel("Close tab")
            } else if index < 9, !compact {
                Text("⌘\(index + 1)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: compact ? 28 : 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.08) : (multi ? Color.accentColor.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(multi ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command), !compact { workspace.toggleMultiSelect(id) } else {
                workspace.multiSelection.removeAll()
                onSelect(id)
            }
        }
        .onHover { inside in if inside { hovered = id } else if hovered == id { hovered = nil } }
        // R5 board 6 B: in a room, drag the tab onto the room's canvas (or the menu bar icon) to put it there.
        .modifier(TabDragSource(conversation: conversation, enabled: model.roomActive))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(conversation.title), \(caption(conversation))")
    }

    private func caption(_ conversation: Conversation) -> String {
        switch model.store.tabState(conversation.id) {
        case .needsYou: return "needs you"
        case .running:
            let agents = conversation.runningSubagents
            return agents > 0 ? "\(agents) agent\(agents == 1 ? "" : "s") working" : "working…"
        case .finishedUnseen: return "answer ready"
        case .idle:
            if let picked = conversation.pickedUp { return "from \(picked.senderName)" }
            return conversation.provider.displayName
        }
    }

    /// One dot per tab in its state colour; the selected one is wider.
    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(workspace.tabs, id: \.self) { id in
                let selected = self.selected == id
                Capsule()
                    .fill(dotColor(model.store.tabState(id), selected: selected))
                    .frame(width: selected ? 14 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: selected)
        .accessibilityHidden(true)
        .opacity(workspace.tabs.count > 1 ? 1 : 0)
    }

    private func dotColor(_ state: TabState, selected: Bool) -> Color {
        switch state {
        case .needsYou: NeedsYou.tint
        case .running: .accentColor
        case .finishedUnseen: .green
        case .idle: selected ? Color.primary.opacity(0.6) : Color.primary.opacity(0.2)
        }
    }
}

/// Spinner (working) · orange (needs you) · green (answer you haven't seen) · hollow (idle).
struct StateDot: View {
    let state: TabState
    let reduceMotion: Bool

    var body: some View {
        Group {
            switch state {
            case .running:
                if reduceMotion {
                    Circle().fill(Color.accentColor)
                } else {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                }
            case .needsYou: Circle().fill(NeedsYou.tint)
            case .finishedUnseen: Circle().fill(Color.green)
            case .idle: Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.2)
            }
        }
        .frame(width: 8, height: 8)
        .frame(width: 12, height: 12)
    }
}
