import SwiftUI

/// Root of the floating panel: switches between the board-1..4 states.
struct QuickChatView: View {
    @Bindable var model: PanelModel

    var body: some View {
        content
            .frame(width: model.width)
            .background(MaterialBackground(material: .hudWindow))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .animation(Motion.shareMode(model.reduceMotion), value: model.isWide)
            .background {
                // Panel-wide shortcuts that must work regardless of which control has focus.
                Group {
                    Button("Settings") { model.onOpenSettings?() }.keyboardShortcut(",", modifiers: .command)
                    Button("New chat") { model.newChat() }.keyboardShortcut("n", modifiers: .command)
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
            ChatView(model: model, conversationID: id, style: .panel)
                .transition(Motion.pop(model.reduceMotion))
        case .share:
            if let prep = model.prep {
                SharePrepareView(model: model, prep: prep)
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
            HStack(spacing: 14) {
                Image(systemName: "drop")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                TextField("Ask anything…", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .light))
                    .focused($inputFocused)
                    .accessibilityLabel("Ask ContextDrop")
                    .onKeyPress(phases: .down) { press in handleKey(press) }
                ProviderPill(model: model, conversationID: nil)
            }
            .padding(.horizontal, 18)
            .frame(height: 60)

            if model.draft.isEmpty {
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
                    Text("Ask \(model.store.defaultProvider.displayName)")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 18)
                .frame(height: 38)
            }

            if let notice = model.peers.notice {
                HairlineDivider()
                NoticeRow(text: notice) { model.peers.notice = nil }
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
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            model.moveSelection(-1); return .handled
        case .downArrow:
            model.moveSelection(1); return .handled
        case .return:
            if press.modifiers.contains(.command) {
                let items = model.homeItems
                if items.indices.contains(model.selection), case .chat(let c) = items[model.selection] { model.onExpand?(c.id) }
                return .handled
            }
            model.submitFromHome(); return .handled
        case .escape:
            model.escape(); return .handled
        default:
            break
        }
        if press.modifiers.contains(.command), press.characters == "p" {
            model.showProviderMenu.toggle(); return .handled
        }
        if press.modifiers.contains(.command), press.characters == "v", model.draft.isEmpty,
           let index = model.homeItems.firstIndex(of: .clipboard) {
            model.selection = index
            model.open(.clipboard)
            return .handled
        }
        if press.modifiers.contains(.command), let digit = press.characters.first,
           let provider = ProviderKind.allCases.first(where: { $0.shortcutDigit == digit }) {
            model.selectProvider(provider, for: nil); return .handled
        }
        return .ignored
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

    var body: some View {
        Button {
            model.showProviderMenu.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.store.status(provider).isReady ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(provider.displayName)
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
            ProviderMenu(model: model, conversationID: conversationID, current: provider)
        }
    }
}

struct ProviderMenu: View {
    let model: PanelModel
    let conversationID: UUID?
    let current: ProviderKind

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            section("Quick answers")
            row(.openRouter)
            HairlineDivider().padding(.horizontal, 10).padding(.vertical, 4)
            section("Deep chats · runs on this Mac")
            row(.claudeCode)
            row(.codex)
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

    private func row(_ kind: ProviderKind) -> some View {
        let status = model.store.status(kind)
        let selected = kind == current
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
                } else if case .notFound = status {
                    Link("How to install", destination: URL(string: kind == .claudeCode ? "https://docs.anthropic.com/en/docs/claude-code/setup" : "https://github.com/openai/codex")!)
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
