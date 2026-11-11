import SwiftUI

/// Root of the floating panel: switches between the board-1..4 states.
struct QuickChatView: View {
    @Bindable var model: PanelModel

    private var acceptsDrops: Bool {
        switch model.mode {
        case .home, .chat: true
        default: false
        }
    }

    var body: some View {
        content
            .frame(width: model.width)
            .fileDropTargets(model: model, conversationID: { [model] in model.panelConversationID }, enabled: acceptsDrops)
            .background(MaterialBackground(material: .hudWindow))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .animation(Motion.shareMode(model.reduceMotion), value: model.isWide)
            .animation(Motion.shareMode(model.reduceMotion), value: model.terminalVisible)
            .background {
                // Panel-wide shortcuts that must work regardless of which control has focus.
                Group {
                    Button("Settings") { model.onOpenSettings?() }.keyboardShortcut(",", modifiers: .command)
                    Button("New chat") { model.newChat() }.keyboardShortcut("n", modifiers: .command)
                    Button("New tab") { model.newChat() }.keyboardShortcut("t", modifiers: .command)
                    Button("Close tab") { if let id = model.panelConversationID { model.closePanelTab(id) } else { model.escape() } }
                        .keyboardShortcut("w", modifiers: .command)
                    Button("Next tab") { model.stepPanelTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                    Button("Previous tab") { model.stepPanelTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                    Button("Activity") { if model.activeConversationID.flatMap({ model.store.conversation($0) })?.provider.isDeep == true { model.toggleTerminal() } }
                        .keyboardShortcut("a", modifiers: [.command, .option])
                    Button("Open a room") { model.onOpenRoom?() }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                }
                .opacity(0)
                .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .home:
            HomeView(model: model)
                .transition(Motion.pop(model.reduceMotion))
        case .chat(let id):
            VStack(spacing: 0) {
                // Tabs: the same ones the window shows. ⌘T new · ⌃Tab next · ⌘W close · swipe sideways.
                TabStrip(model: model, selected: id, compact: true,
                         onSelect: { model.selectPanelTab($0) }, onNew: { model.newChat() }, onClose: { model.closePanelTab($0) })
                    .frame(width: PanelModel.chatWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HairlineDivider()
                HStack(spacing: 0) {
                    ChatView(model: model, conversationID: id, style: .panel, fillsHeight: model.terminalVisible)
                        .frame(width: PanelModel.chatWidth)
                    if model.terminalVisible, let conversation = model.store.conversation(id) {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                        TerminalPane(model: model, conversation: conversation)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(model.reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(height: model.terminalVisible ? min(620, model.maxPanelHeight - PanelModel.tabStripHeight) : nil, alignment: .top)
                .id(id)
                .modifier(SwipeFeedback(model: model, offset: model.panelSwipe, current: id))
            }
            .clipped()
            .onChange(of: id) { model.slideIn(\.panelSwipe) }
            .transition(Motion.pop(model.reduceMotion))
        case .share:
            if let prep = model.prep {
                SharePrepareView(model: model, prep: prep)
                    .transition(.opacity)
            }
        case .shareTabs:
            if let multi = model.multiShare {
                ShareTabsView(model: model, multi: multi)
                    .transition(.opacity)
            }
        case .send(let id, let share):
            NearbySendView(model: model, conversationID: id, share: share)
                .transition(.opacity)
        case .offer(let offerID):
            if let offer = model.peers.offers.first(where: { $0.id == offerID }) {
                OfferPreviewView(model: model, offer: offer)
                    .transition(Motion.pop(model.reduceMotion))
            } else {
                // The offer expired or was handled elsewhere.
                HomeView(model: model)
            }
        case .received(let shareID):
            if let received = model.store.received.first(where: { $0.id == shareID }) {
                ReceivedPreviewView(model: model, share: received.share)
                    .transition(Motion.pop(model.reduceMotion))
            } else {
                HomeView(model: model)
            }
        }
    }
}

// MARK: - Collapsed state (board 1 · 01)

struct HomeView: View {
    @Bindable var model: PanelModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !model.workspace.tabs.isEmpty {
                HomeTabBubbles(model: model)
                HairlineDivider()
            }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "drop")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 28)
                // Wraps and grows (up to 6 lines, then scrolls) so long questions stay visible.
                TextField("Ask anything…", text: Bindable(model.homeSession).draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .light))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .accessibilityLabel("Ask ContextDrop")
                    .onKeyPress(phases: .down) { press in handleKey(press) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                ImageButtons(model: model)
                    .frame(height: 28)
                ProviderPill(model: model, conversationID: nil)
                    .frame(height: 28)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minHeight: 60)

            if !model.pendingAttachments.isEmpty {
                AttachmentStrip(attachments: model.pendingAttachments) { model.removeAttachment($0, from: model.homeSession) }
                    .padding(.leading, 52).padding(.trailing, 18).padding(.bottom, 12)
            }
            if !model.homeSession.skills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.homeSession.skills, id: \.self) { name in
                        SkillChip(name: name) { model.homeSession.skills.removeAll { $0 == name } }
                    }
                    Text("Runs with Claude Code").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 52).padding(.bottom, 12)
            }
            if let folder = model.homeFolder {
                HStack {
                    FolderTag(shortcut: folder) { model.homeFolder = nil }
                    Spacer()
                }
                .padding(.leading, 52).padding(.bottom, 12)
            }

            if model.slashQuery != nil {
                HairlineDivider()
                SlashMenu(model: model, session: model.homeSession)
            } else if model.draft.isEmpty && model.pendingAttachments.isEmpty && model.homeSession.skills.isEmpty {
                let items = model.homeItems
                if !items.isEmpty {
                    HairlineDivider()
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            HomeRow(item: item, selected: index == model.selection, model: model)
                                .onTapGesture { model.selection = index; model.open(item) }
                                .onHover { if $0 { model.selection = index } }
                        }
                    }
                    .padding(8)
                }
            } else {
                HairlineDivider()
                HStack(spacing: 8) {
                    Image(systemName: "return").foregroundStyle(.secondary)
                    Text(askHint).foregroundStyle(.secondary)
                    Spacer()
                    let chain = SlashCommand.parseChain(model.draft, folders: model.store.folders)
                    if !chain.commands.isEmpty && chain.rest.isEmpty {
                        Text("Type / for another choice").foregroundStyle(.tertiary)
                    } else if model.store.folders.shortcuts.isEmpty {
                        Text("Type / for folders and commands").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 18)
                .frame(height: 38)
            }

            if let notice = model.notices.text {
                HairlineDivider()
                NoticeRow(text: notice) { model.notices.text = nil }
            }

            HairlineDivider()
            HStack(spacing: 16) {
                HintItem(key: "↑↓", label: "Navigate")
                HintItem(key: "↵", label: "Open")
                HintItem(key: "⌘↵", label: "Window")
                Spacer()
                HintItem(key: "esc", label: "Close")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: 34)
        }
        .onAppear { inputFocused = true }
        .onChange(of: model.focusToken) { inputFocused = true }
        .onChange(of: model.homeSession.focusToken) { inputFocused = true }
        .onChange(of: inputFocused) { _, focused in if focused { model.composerFocused(nil, inWindow: false) } }
    }

    private var askHint: String {
        let parsed = SlashCommand.parseChain(model.draft, folders: model.store.folders)
        var provider: ProviderKind?
        var folder = model.homeFolder
        var auto = model.store.autoActive
        for command in parsed.commands {
            switch command {
            case .provider(let selected): provider = selected; auto = false
            case .folder(let selected): folder = selected
            case .auto: provider = nil; auto = true
            case .addFolder: return "Add a folder shortcut"
            case .skill: provider = .forSkills; auto = false
            case .action(.share): return "Share a chat"
            case .action(.room): return "Open a room for people nearby"
            case .action(.folder): return "Choose a working folder"
            }
        }
        if !model.homeSession.skills.isEmpty { provider = .forSkills; auto = false }
        if let provider {
            if provider.isDeep, let folder { return "Ask \(provider.displayName) in \(folder.display)" }
            return "Ask \(provider.displayName)"
        }
        if auto { return "Ask · OpenAI picks a quick answer or coding agent" }
        if let folder {
            let selected = model.store.defaultProvider.isDeep ? model.store.defaultProvider : model.store.preferredDeepProvider()
            return "Ask \(selected?.displayName ?? "a coding agent") in \(folder.display)"
        }
        return "Ask \(model.store.defaultProvider.displayName)"
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if let result = SlashMenu.handle(press, model: model, session: model.homeSession) { return result }
        switch press.key {
        case .delete where model.draft.isEmpty && !model.homeSession.skills.isEmpty:
            model.homeSession.skills.removeLast(); return .handled
        case .delete where model.draft.isEmpty && model.homeFolder != nil:
            model.homeFolder = nil; return .handled
        case .upArrow where model.draft.isEmpty:
            model.moveSelection(-1); return .handled
        case .downArrow where model.draft.isEmpty:
            model.moveSelection(1); return .handled
        case .return:
            if press.modifiers.contains(.command) {
                let items = model.homeItems
                if items.indices.contains(model.selection), case .chat(let c) = items[model.selection] { model.onExpand?(c.id) }
                return .handled
            }
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored } // newline
            model.submitFromHome(); return .handled
        case .escape:
            model.escape(); return .handled
        default:
            break
        }
        if press.modifiers.contains(.command), press.characters == "p" {
            model.showProviderMenu.toggle(); return .handled
        }
        if press.modifiers.contains(.command), press.characters == "v", model.pasteAsAttachment(into: model.homeSession) {
            return .handled
        }
        if press.modifiers.contains(.command), press.characters == "v", model.draft.isEmpty,
           let index = model.homeItems.firstIndex(of: .clipboard) {
            model.selection = index
            model.open(.clipboard)
            return .handled
        }
        if press.modifiers.contains(.command), press.characters == "0" {
            model.selectAuto(); return .handled
        }
        if press.modifiers.contains(.command), let digit = press.characters.first,
           let provider = ProviderKind.allCases.first(where: { $0.shortcutDigit == digit }) {
            model.selectProvider(provider, for: nil); return .handled
        }
        return .ignored
    }
}

/// Open conversations stay visible while the home composer is ready for a new question.
private struct HomeTabBubbles: View {
    let model: PanelModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(model.workspace.tabs, id: \.self) { id in
                    if let conversation = model.store.conversation(id) {
                        Button { model.selectPanelTab(id) } label: {
                            HStack(spacing: 6) {
                                StateDot(state: model.store.tabState(id), reduceMotion: model.reduceMotion)
                                Text(conversation.title.isEmpty ? "New chat" : conversation.title)
                                    .lineLimit(1)
                                    .frame(maxWidth: 150)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(conversation.title.isEmpty ? "New chat" : conversation.title)")
                        .accessibilityLabel("Open tab: \(conversation.title.isEmpty ? "New chat" : conversation.title)")
                    }
                }
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 42)
    }
}

struct HomeRow: View {
    let item: HomeItem
    let selected: Bool
    let model: PanelModel

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                title
                if let subtitle { Text(subtitle).font(.system(size: 11)).opacity(selected ? 0.9 : 0.7) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: subtitle == nil ? 40 : 44)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .offer(let offer):
            AvatarView(name: offer.senderName, size: 22)
                .overlay(alignment: .topTrailing) {
                    if !offer.seen { Circle().fill(Color.accentColor).frame(width: 8, height: 8).overlay(Circle().stroke(.white, lineWidth: 1.5)).offset(x: 3, y: -3) }
                }
        case .received(let r):
            AvatarView(name: r.share.senderName, size: 22)
                .overlay(alignment: .topTrailing) {
                    if !r.read { Circle().fill(Color.accentColor).frame(width: 8, height: 8).overlay(Circle().stroke(.white, lineWidth: 1.5)).offset(x: 3, y: -3) }
                }
        case .chat(let c):
            Image(systemName: c.pickedUp != nil ? "arrow.down.message" : (c.provider.isDeep ? "terminal" : "bubble.left"))
                .frame(width: 22)
        case .clipboard:
            Image(systemName: "doc.on.clipboard").frame(width: 22)
        }
    }

    @ViewBuilder private var title: some View {
        switch item {
        case .offer(let o):
            (Text(o.preview.title) + Text(" — from \(o.senderName)").foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary))
                .font(.system(size: 14)).lineLimit(1)
        case .received(let r):
            (Text(r.share.title) + Text(" — from \(r.share.senderName)").foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary))
                .font(.system(size: 14)).lineLimit(1)
        case .chat(let c):
            Text(c.title).font(.system(size: 14)).lineLimit(1)
        case .clipboard:
            Text("Ask about clipboard").font(.system(size: 14))
        }
    }

    private var subtitle: String? {
        switch item {
        case .offer(let o): "\(o.preview.countsLine) · waiting for you"
        case .received(let r): "\(r.share.countsLine) · \(r.receivedAt.formatted(.relative(presentation: .named)))"
        default: nil
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item {
        case .offer, .received:
            Text(selected ? "Open ↵" : "").font(.system(size: 12))
        case .chat(let c):
            Text([c.keptCount > 0 ? "\(c.keptCount) kept" : nil, c.updatedAt.formatted(.relative(presentation: .named))]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
        case .clipboard:
            Kbd("⌘V")
        }
    }
}

struct NoticeRow: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

// MARK: - Provider pill + menu (board 6 · 01)

struct ProviderPill: View {
    @Bindable var model: PanelModel
    let conversationID: UUID?

    private var provider: ProviderKind {
        model.store.conversation(conversationID)?.provider ?? model.store.defaultProvider
    }

    /// Home shows "Auto" while auto mode is on (a chat always shows its real provider).
    private var showsAuto: Bool { conversationID == nil && model.store.autoActive }

    var body: some View {
        Button {
            model.showProviderMenu.toggle()
        } label: {
            HStack(spacing: 6) {
                if showsAuto {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Text("Auto")
                } else {
                    Circle()
                        .fill(model.store.status(provider).isReady ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(provider.displayName)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Provider (⌘P)")
        .popover(isPresented: $model.showProviderMenu, arrowEdge: .bottom) {
            ProviderMenu(model: model, conversationID: conversationID, current: provider, autoSelected: showsAuto)
        }
    }
}

struct ProviderMenu: View {
    let model: PanelModel
    let conversationID: UUID?
    let current: ProviderKind
    var autoSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if conversationID == nil {
                autoRow
                HairlineDivider().padding(.horizontal, 10).padding(.vertical, 4)
            }
            section("Quick answers")
            ForEach(ProviderKind.allCases.filter { !$0.isDeep }) { row($0) }
            HairlineDivider().padding(.horizontal, 10).padding(.vertical, 4)
            section("Deep chats · runs on this Mac")
            ForEach(ProviderKind.deep) { row($0) }
            HairlineDivider().padding(.horizontal, 10).padding(.vertical, 4)
            Text("ContextDrop looks for each tool on your Mac and uses its own sign-in. It never stores those accounts.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .padding(6)
        .frame(width: 340)
        .onAppear { model.store.refreshProviderStatus() }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    private var autoRow: some View {
        let available = model.store.autoAvailable
        return Button { model.selectAuto() } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(autoSelected ? Color.white : Color.accentColor)
                    .frame(width: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(available ? AnyShapeStyle(autoSelected ? Color.white : Color.primary) : AnyShapeStyle(.secondary))
                    Text(available ? "OpenAI decides: quick answer, or Claude Code for your code" : "Needs an OpenAI key")
                        .font(.system(size: 11))
                        .foregroundStyle(autoSelected ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                }
                Spacer()
                if autoSelected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) } else { Kbd("⌘0") }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(autoSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    private func row(_ kind: ProviderKind) -> some View {
        let status = model.store.status(kind)
        let selected = kind == current && !autoSelected
        return Button {
            model.selectProvider(kind, for: conversationID)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(status.isReady ? Color.clear : Color.secondary, lineWidth: 1.5)
                    .background(Circle().fill(status.isReady ? (selected ? Color.white : Color.green) : Color.clear))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(status.isReady ? AnyShapeStyle(selected ? Color.white : Color.primary) : AnyShapeStyle(.secondary))
                    Text(status.detail).font(.system(size: 11))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                }
                Spacer()
                if case .missingKey = status {
                    Button("Settings…") { model.onOpenSettings?() }.controlSize(.small)
                } else if case .notFound = status, let url = kind.installURL {
                    Link("How to install", destination: url)
                        .font(.system(size: 11))
                } else if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                } else {
                    Kbd("⌘\(kind.shortcutDigit)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(status.isReady ? "" : status.detail)
    }
}
