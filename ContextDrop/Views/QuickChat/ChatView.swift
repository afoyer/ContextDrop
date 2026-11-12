import SwiftUI

/// A conversation laid out like a document (board 1 · 03, board 4 · 03, R2 board 6 · 02, R3 board 1).
struct ChatView: View {
    enum Style { case panel, window }

    @Bindable var model: PanelModel
    let conversationID: UUID
    let style: Style
    /// Fill the height the parent gives (next to the activity pane, or in the window) instead of sizing to content.
    var fillsHeight = false
    @FocusState private var inputFocused: Bool
    @State private var hoveredMessageID: UUID?
    /// Height of everything except the transcript (header, notices, composer), measured.
    @State private var totalHeight: CGFloat = 0
    @State private var transcriptHeight: CGFloat = 0
    /// Auto-scroll only while the user is reading the end of the chat.
    @State private var atBottom = true

    private var session: ChatSession { model.session(conversationID) }

    /// The transcript gives up height so the composer always stays on screen, however much is typed.
    private var transcriptMax: CGFloat {
        guard style == .panel, !fillsHeight else { return .infinity }
        let chrome = max(100, totalHeight - transcriptHeight)
        return max(120, min(520, model.maxPanelHeight - PanelModel.tabStripHeight - chrome))
    }

    private var store: ChatStore { model.store }
    private var conversation: Conversation? { store.conversation(conversationID) }

    var body: some View {
        if let conversation {
            VStack(spacing: 0) {
                if style == .panel {
                    header(conversation)
                    HairlineDivider()
                }
                transcript(conversation)
                if let notice = model.notices.text {
                    HairlineDivider()
                    NoticeRow(text: notice) { model.notices.text = nil }
                }
                HairlineDivider()
                composer(conversation)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { totalHeight = $0 }
            .onAppear {
                inputFocused = true
                store.markSeen(conversationID)
            }
            .onChange(of: model.focusToken) { if style == .panel { inputFocused = true } }
            .onChange(of: session.focusToken) { inputFocused = true }
            .onChange(of: inputFocused) { _, focused in
                if focused { model.composerFocused(conversationID, inWindow: style == .window) }
            }
            .onChange(of: store.isRunning(conversationID)) { _, running in if !running { store.markSeen(conversationID) } }
        }
    }

    // MARK: Header (panel; the window has its own)

    private func header(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            // Row 1: what this chat is, who answers, and where it can go.
            HStack(spacing: 10) {
                Text(conversation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 80, alignment: .leading)
                    .layoutPriority(1)
                // Badges give way before the title or the buttons do.
                ViewThatFits(in: .horizontal) {
                    ChatBadges(conversation: conversation, reduceMotion: model.reduceMotion)
                    PrivateBadge()
                    Color.clear.frame(width: 0, height: 0)
                }
                Spacer(minLength: 4)
                ProviderPill(model: model, conversationID: conversation.id)
                    .fixedSize()
                Button { model.beginShare(conversation.id) } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                    .help(conversation.pickedUp != nil ? "Share back (⌘⇧S)" : "Share this chat (⌘⇧S)")
                    .accessibilityLabel("Share this chat")
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(conversation.messages.isEmpty)
                Button { model.actions.expand(conversation.id) } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless)
                    .help("Open in the window (⌘↵)")
                    .accessibilityLabel("Open in the window")
            }
            .frame(height: 42)
            // Row 2, coding agents only: where it works and what it may do.
            if conversation.provider.isDeep {
                HStack(spacing: 8) {
                    FolderChip(model: model, conversation: conversation)
                    PermissionLevelMenu(store: store, conversation: conversation)
                    RoomShareChip(model: model, conversation: conversation)
                    Spacer(minLength: 4)
                    if !model.showTerminal {
                        Button { model.toggleTerminal() } label: {
                            HStack(spacing: 4) { Image(systemName: "sidebar.right"); Text("Activity") }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .help("Show activity (⌥⌘A)")
                    }
                }
                .frame(height: 30)
                .padding(.bottom, 6)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .animation(Motion.keep(model.reduceMotion), value: conversation.sharedWith)
    }

    // MARK: Transcript

    private func transcript(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let picked = conversation.pickedUp {
                        PickedUpBlock(share: picked, attachments: conversation.pickedUpAttachments, reduceMotion: model.reduceMotion)
                        let asked = Set(conversation.messages.filter { $0.role == .user }.map(\.text))
                        ForEach(picked.openQuestions.filter { !asked.contains($0) }, id: \.self) { question in
                            AskThisRow(question: question) { model.askSuggested(question, in: conversation.id) }
                                .disabled(store.isRunning(conversation.id))
                        }
                    }
                    let firstQuestionID = conversation.messages.first(where: { $0.role == .user })?.id
                    ForEach(conversation.messages) { message in
                        MessageBlock(
                            message: message,
                            conversation: conversation,
                            model: model,
                            hovered: hoveredMessageID == message.id || session.focusedMessageID == message.id,
                            keysActive: session.draft.isEmpty && message.id == conversation.messages.last?.id
                        )
                        .id(message.id)
                        .onHover { inside in
                            if inside { hoveredMessageID = message.id } else if hoveredMessageID == message.id { hoveredMessageID = nil }
                        }
                        if message.id == firstQuestionID, let decision = conversation.routedBy {
                            RouteCaption(decision: decision, conversation: conversation, model: model)
                                .padding(.top, -8)
                        }
                    }
                    if conversation.isRouting {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                            Text("Choosing how to answer…").foregroundStyle(.secondary)
                            Spacer()
                            Text("Auto · OpenAI").foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 6)
                        .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("end")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: style == .window ? 820 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: style == .panel ? 120 : 200, maxHeight: transcriptMax)
            .fixedSize(horizontal: false, vertical: style == .panel && !fillsHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { transcriptHeight = $0 }
            .onChange(of: scrollSignature(conversation)) { followEnd(proxy) }
            .onChange(of: conversation.messages.count) { scrollToEnd(proxy) } // a new question always jumps to the end
            .onChange(of: session.focusedMessageID) { _, id in
                if let id { withAnimation(Motion.resize(model.reduceMotion)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    /// Anything that grows the last answer: text, steps, cards.
    private func scrollSignature(_ conversation: Conversation) -> [Int] {
        guard let last = conversation.messages.last else { return [] }
        return [last.text.count, last.steps.count, last.permissions.count, last.questions.count,
                last.subagents.count, last.changes.count, last.isStreaming ? 1 : 0]
    }

    private func followEnd(_ proxy: ScrollViewProxy) {
        if atBottom { proxy.scrollTo("end", anchor: .bottom) }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("end", anchor: .bottom)
        atBottom = true
    }

    // MARK: Composer

    private func composer(_ conversation: Conversation) -> some View {
        let running = store.isRunning(conversation.id)
        let input = session
        return VStack(alignment: .leading, spacing: 8) {
            if input.slashQuery != nil {
                SlashMenu(model: model, session: input)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !input.skills.isEmpty || !conversation.pinnedSkills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(input.skills, id: \.self) { name in
                        SkillChip(name: name) { input.skills.removeAll { $0 == name } }
                    }
                    Spacer(minLength: 4)
                    if !conversation.pinnedSkills.isEmpty {
                        Text("Pinned to this chat:").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(conversation.pinnedSkills, id: \.self) { name in
                            SkillChip(name: name, pinned: true) { model.unpinSkill(name, in: conversation.id) }
                        }
                    }
                }
            }
            if !input.pendingAttachments.isEmpty {
                AttachmentStrip(attachments: input.pendingAttachments) { model.removeAttachment($0, from: input) }
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField(placeholder(conversation), text: Bindable(input).draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .accessibilityLabel("Follow-up")
                    .onKeyPress(phases: .down) { press in handleKey(press, conversation) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                ImageButtons(model: model)
                if let question = conversation.pendingQuestions.first, let item = question.current, !item.multiSelect {
                    HStack(spacing: 3) { Kbd("1"); Text("–"); Kbd("\(min(9, item.options.count))"); Text("answer") }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if running {
                    Button { store.stop(conversation.id) } label: { HStack(spacing: 4) { Text("Stop"); Kbd("⌘.") } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    if conversation.keptCount > 0 {
                        Text("\(conversation.keptCount) kept").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.keptText)
                    } else {
                        HStack(spacing: 4) { Kbd("⌘K"); Text("Keep") }.font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if style == .panel {
                        Button { model.beginShare(conversation.id) } label: {
                            HStack(spacing: 4) { Text(conversation.pickedUp != nil ? "Share back…" : "Share…"); Kbd("⌘⇧S") }
                        }
                        .controlSize(.small)
                        .disabled(conversation.messages.isEmpty)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 54)
        .background {
            // ⌘⇧R: "To room" on the focused answer.
            Button("To room") { model.sendFocusedToRoom(in: conversation.id) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.roomActive)
                .opacity(0).allowsHitTesting(false)
        }
    }

    private func placeholder(_ conversation: Conversation) -> String {
        if !conversation.pendingQuestions.isEmpty { return "Type your own answer…" }
        if conversation.provider.isDeep { return "Reply to \(conversation.provider.displayName)…" }
        return conversation.messages.isEmpty ? "Ask anything…" : "Ask a follow-up…"
    }

    private func handleKey(_ press: KeyPress, _ conversation: Conversation) -> KeyPress.Result {
        let input = session
        if let result = SlashMenu.handle(press, model: model, session: input) { return result }
        if press.isBackTab {
            guard conversation.provider.isDeep else { return .ignored }
            model.cyclePermissionLevel(in: conversation.id); return .handled
        }
        let cmd = press.modifiers.contains(.command)
        // 1–9 answer a decision while nothing is typed.
        if !cmd, input.draft.isEmpty, let question = conversation.pendingQuestions.first,
           let digit = press.characters.first, digit.isNumber,
           DecisionCard.answer(digit: digit, question: question, conversationID: conversation.id, store: store) {
            return .handled
        }
        switch press.key {
        case .return:
            if cmd {
                if style == .panel { model.actions.expand(conversation.id) }
                return .handled
            }
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored } // newline
            if let last = conversation.messages.last, last.error != nil, input.draft.isEmpty {
                store.retry(in: conversation.id); return .handled
            }
            model.submitInChat(conversation.id); return .handled
        case .upArrow where input.draft.isEmpty:
            model.moveAnswerFocus(-1, in: conversation.id); return .handled
        case .downArrow where input.draft.isEmpty:
            model.moveAnswerFocus(1, in: conversation.id); return .handled
        case .escape:
            if style == .panel { model.escape() } else { input.draft = "" }
            return .handled
        default:
            break
        }
        guard cmd else { return .ignored }
        switch press.characters {
        case "v": return model.pasteAsAttachment(into: input) ? .handled : .ignored
        case "k": model.keepFocused(in: conversation.id); return .handled
        case "c" where input.draft.isEmpty: model.copyFocused(in: conversation.id); return .handled
        case "p" where style == .panel: model.showProviderMenu.toggle(); return .handled
        default:
            // ⌘1–3 pick the provider in the panel; in the window they switch tabs.
            if style == .panel, let digit = press.characters.first,
               let provider = ProviderKind.allCases.first(where: { $0.shortcutDigit == digit }) {
                model.selectProvider(provider, for: conversation.id); return .handled
            }
            return .ignored
        }
    }
}

/// "From Camille", "Private", "Shared with Jonas".
struct ChatBadges: View {
    let conversation: Conversation
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let picked = conversation.pickedUp {
                PersonBadge(name: picked.senderName, prefix: "From", tint: Palette.fromTint)
            }
            PrivateBadge()
            if let shared = conversation.sharedWith.last {
                PersonBadge(name: shared, prefix: "Shared with")
                    .transition(Motion.pop(reduceMotion))
            }
        }
    }
}

extension KeyPress {
    /// ⇧Tab. AppKit reports it as the backtab character (U+0019) rather than shift + "\t".
    var isBackTab: Bool { characters == "\u{19}" || (key == .tab && modifiers.contains(.shift)) }
}

/// How much the agent may do without asking: per chat, or for the next chat from the home input.
struct PermissionLevelMenu: View {
    let level: PermissionLevel
    /// Short label ("asks first") for tight rows like the home input.
    var compact = false
    var help = "What the agent may do without asking. Applies from the next message. ⇧Tab cycles."
    let select: (PermissionLevel) -> Void

    init(store: ChatStore, conversation: Conversation) {
        level = conversation.permissionLevel
        select = { store.setPermissionLevel($0, for: conversation.id) }
    }

    init(level: PermissionLevel, compact: Bool = false, help: String, select: @escaping (PermissionLevel) -> Void) {
        self.level = level
        self.compact = compact
        self.help = help
        self.select = select
    }

    var body: some View {
        Menu {
            ForEach(PermissionLevel.allCases) { option in
                Button {
                    select(option)
                } label: {
                    Text(option.label)
                    Text(option.detail)
                    if option == level { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: level.icon)
                Text(compact ? level.chip : level.label)
            }
            .font(.system(size: 12))
            .foregroundStyle(level == .auto ? Color.orange : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9).frame(height: 22)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help(help)
        .accessibilityLabel("Permissions: \(level.label)")
    }
}

// MARK: - One message

struct MessageBlock: View {
    let message: Message
    let conversation: Conversation
    let model: PanelModel
    let hovered: Bool
    var keysActive = false

    var body: some View {
        if message.role == .user {
            VStack(alignment: .leading, spacing: 4) {
                Text("You").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if !message.skills.isEmpty {
                    HStack(spacing: 6) { ForEach(message.skills, id: \.self) { SkillChip(name: $0) } }
                }
                Text(message.text)
                    .font(.system(size: 15, weight: .semibold))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.attachments.isEmpty {
                    AttachmentStrip(attachments: message.attachments, size: 64)
                }
            }
        } else if let error = message.error {
            ErrorCard(message: error, failure: message.failure ?? (conversation.provider.isDeep ? .agentStopped : .noResponse),
                      model: model, conversationID: conversation.id)
        } else {
            answer
        }
    }

    private func agentName(_ id: String?) -> String? {
        guard let id, let agent = message.subagents.first(where: { $0.id == id }) else { return nil }
        return "\(agent.type) subagent"
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(message.author).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if message.kept { KeptLabel().transition(Motion.pop(model.reduceMotion)) }
            }
            if !message.subagents.isEmpty {
                SubagentLanes(subagents: message.subagents, filtered: model.activityFilter[conversation.id]) { id in
                    model.activityFilter[conversation.id] = model.activityFilter[conversation.id] == id ? nil : id
                    if !model.showTerminal { model.toggleTerminal() }
                }
            }
            if !message.steps.isEmpty { StepsSummary(steps: message.steps, running: message.isStreaming, model: model) }
            if message.isStreaming && message.text.isEmpty && message.steps.isEmpty && message.subagents.isEmpty {
                ThinkingRow(provider: conversation.provider, reduceMotion: model.reduceMotion)
            } else if !message.text.isEmpty {
                MarkdownView(message.text, fontSize: 14, streaming: message.isStreaming)
            }
            ForEach(message.questions) { question in
                DecisionCard(question: question, conversationID: conversation.id, store: model.store,
                             askedBy: agentName(question.agentID), keysActive: keysActive)
            }
            ForEach(message.permissions) { request in
                PermissionCard(request: request, conversation: conversation, store: model.store, askedBy: agentName(request.agentID))
            }
            if !message.changes.isEmpty && !message.isStreaming {
                ChangesCard(changes: message.changes, folder: conversation.folder)
            }
            if let warning = message.warning { WarningRow(text: warning) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(message.kept ? Palette.keptTint : Palette.answerFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            if message.kept {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                    .fill(Palette.keptRule).frame(width: 3)
            }
        }
        .padding(.horizontal, -14)
        .overlay(alignment: .topTrailing) {
            if hovered && !message.isStreaming {
                AnswerToolbar(message: message, model: model, conversationID: conversation.id)
                    .offset(x: -4, y: -14)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(Motion.keep(model.reduceMotion), value: message.kept)
    }
}

struct AnswerToolbar: View {
    let message: Message
    let model: PanelModel
    let conversationID: UUID

    var body: some View {
        HStack(spacing: 2) {
            Button { model.copy(message) } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.copiedMessageID == message.id ? "checkmark" : "doc.on.doc")
                    Text(model.copiedMessageID == message.id ? "Copied" : "Copy"); Kbd("⌘C")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).frame(height: 24)
            if model.roomActive, let conversation = model.store.conversation(conversationID) {
                Button { model.actions.sendToRoom(message, conversation) } label: {
                    HStack(spacing: 5) { Image(systemName: "square.grid.2x2"); Text("To room"); Kbd("⌘⇧R") }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).frame(height: 24)
                .help("Put this answer on the room’s table. The rest of the chat stays private.")
            }
            Button {
                withAnimation(Motion.keep(model.reduceMotion)) { model.store.toggleKeep(message.id, in: conversationID) }
            } label: {
                HStack(spacing: 5) { Image(systemName: message.kept ? "star.slash" : "star"); Text(message.kept ? "Unkeep" : "Keep"); Kbd("⌘K") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8).frame(height: 24)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .font(.system(size: 12))
        .padding(3)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

struct ThinkingRow: View {
    let provider: ProviderKind
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThinkingLine(reduceMotion: reduceMotion)
            HStack(spacing: 10) {
                Text("Thinking…").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text(provider.thinkingLabel)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Board 1 · 04: the question is kept; one-key retry.
struct ErrorCard: View {
    let message: String
    let failure: ProviderFailure
    let model: PanelModel
    let conversationID: UUID


    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.headline).font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("Your question is still here.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if failure.settingsHelp { Button("Settings…") { model.actions.openSettings() }.controlSize(.small) }
            if failure == .noFolder {
                Button("Choose Folder…") { model.actions.chooseFolder(conversationID) }.controlSize(.small)
            }
            Button("Retry ↵") { model.store.retry(in: conversationID) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, -14)
    }
}

// MARK: - Deep chat pieces (board 6 · 02)

/// One line in the chat for the agent's work; the details live in the activity pane (⌥⌘A).
struct StepsSummary: View {
    let steps: [ToolStep]
    let running: Bool
    let model: PanelModel

    var body: some View {
        Button { if !model.showTerminal { model.toggleTerminal() } } label: {
            HStack(spacing: 8) {
                if running && steps.contains(where: { !$0.done }) {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else if steps.contains(where: \.failed) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
                Text(summary).foregroundStyle(.secondary)
                if let current = running ? steps.last(where: { !$0.done }) ?? steps.last : nil {
                    Text("· \(current.label) \(current.detail)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if !model.showTerminal {
                    HStack(spacing: 4) { Text("Activity"); Kbd("⌥⌘A") }.foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 28)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.showTerminal ? "Details are in the activity pane" : "Show the activity pane (⌥⌘A)")
    }

    private var summary: String {
        let main = steps.filter { $0.agentID == nil }
        let commands = main.filter { $0.kind == .command || $0.kind == .search }.count
        let reads = main.filter { $0.kind == .read }.count
        let edits = main.filter { $0.kind == .edit }.count
        var parts: [String] = []
        if reads > 0 { parts.append("read \(reads) file\(reads == 1 ? "" : "s")") }
        if commands > 0 { parts.append("ran \(commands) command\(commands == 1 ? "" : "s")") }
        if edits > 0 { parts.append("\(edits) edit\(edits == 1 ? "" : "s")") }
        let sub = steps.count - main.count
        if sub > 0 { parts.append("\(sub) by subagents") }
        let text = parts.isEmpty ? "\(steps.count) step\(steps.count == 1 ? "" : "s")" : parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Screenshot capture + image picker, used by the home input and the chat composer.
struct ImageButtons: View {
    let model: PanelModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.actions.captureScreenshot() } label: { Image(systemName: "camera.viewfinder") }
                .help("Attach a screenshot: drag over an area, or press space for a window")
                .accessibilityLabel("Attach a screenshot")
            Button { model.actions.pickImages() } label: { Image(systemName: "paperclip") }
                .help("Attach images (or paste with ⌘V, or drop them here)")
                .accessibilityLabel("Attach images")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .frame(height: 20)
    }
}

struct FolderChip: View {
    let model: PanelModel
    let conversation: Conversation

    private var folders: FolderShortcutStore { model.store.folders }

    var body: some View {
        Menu {
            ForEach(folders.shortcuts) { shortcut in
                Button {
                    model.store.setFolder(shortcut.url, for: conversation.id)
                } label: {
                    Text("/\(shortcut.name)  \(shortcut.display)")
                    if conversation.folder.map({ folders.shortcut(for: $0)?.id == shortcut.id }) == true { Image(systemName: "checkmark") }
                }
                .disabled(!shortcut.exists)
            }
            if !folders.shortcuts.isEmpty { Divider() }
            Button("Choose Folder…") { model.actions.chooseFolder(conversation.id) }
            if let folder = conversation.folder, folders.shortcut(for: folder) == nil {
                Button("Save as Shortcut /\(FolderShortcutStore.slug(folder.lastPathComponent))") {
                    let shortcut = folders.add(folder)
                    model.notices.text = "Saved. Type /\(shortcut.name) to use \(shortcut.display)."
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(label).lineLimit(1).truncationMode(.head).frame(maxWidth: 180)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9).frame(height: 22)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help("Project folder the agent works in")
    }

    private var label: String {
        guard let folder = conversation.folder else { return "Choose folder…" }
        if let shortcut = folders.shortcut(for: folder) { return "/\(shortcut.name)" }
        return FolderDrop.display(folder)
    }
}
