import SwiftUI

/// A conversation laid out like a document (board 1 · 03, board 4 · 03, board 6 · 02).
struct ChatView: View {
    enum Style { case panel, window }

    @Bindable var model: PanelModel
    let conversationID: UUID
    let style: Style
    @FocusState private var inputFocused: Bool
    @State private var hoveredMessageID: UUID?

    private var store: ChatStore { model.store }
    private var conversation: Conversation? { store.conversation(conversationID) }

    var body: some View {
        if let conversation {
            VStack(spacing: 0) {
                header(conversation)
                HairlineDivider()
                transcript(conversation)
                if let notice = model.peers.notice {
                    HairlineDivider()
                    NoticeRow(text: notice) { model.peers.notice = nil }
                }
                HairlineDivider()
                composer(conversation)
            }
            .onAppear { inputFocused = true }
            .onChange(of: model.focusToken) { inputFocused = true }
        }
    }

    // MARK: Header

    private func header(_ conversation: Conversation) -> some View {
        HStack(spacing: 10) {
            Text(conversation.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let picked = conversation.pickedUp {
                PersonBadge(name: picked.senderName, prefix: "From", tint: Palette.fromTint)
            }
            PrivateBadge()
            if let shared = conversation.sharedWith.last {
                PersonBadge(name: shared, prefix: "Shared with")
                    .transition(Motion.pop(model.reduceMotion))
            }
            if conversation.provider.isDeep {
                FolderChip(model: model, conversation: conversation)
            }
            Spacer()
            if style == .panel {
                ProviderPill(model: model, conversationID: conversation.id)
            }
            Button { model.beginShare(conversation.id) } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
                .help(conversation.pickedUp != nil ? "Share back (⌘⇧S)" : "Share this chat (⌘⇧S)")
                .accessibilityLabel("Share this chat")
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(conversation.messages.isEmpty)
            if style == .panel {
                Button { model.onExpand?(conversation.id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help("Open in window (⌘↵)")
                    .accessibilityLabel("Open in window")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 44)
        .animation(Motion.keep(model.reduceMotion), value: conversation.sharedWith)
    }

    // MARK: Transcript

    private func transcript(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let picked = conversation.pickedUp {
                        PickedUpBlock(share: picked, reduceMotion: model.reduceMotion)
                        let asked = Set(conversation.messages.filter { $0.role == .user }.map(\.text))
                        ForEach(picked.openQuestions.filter { !asked.contains($0) }, id: \.self) { question in
                            AskThisRow(question: question) { model.askSuggested(question, in: conversation.id) }
                                .disabled(store.isRunning(conversation.id))
                        }
                    }
                    ForEach(conversation.messages) { message in
                        MessageBlock(
                            message: message,
                            conversation: conversation,
                            model: model,
                            hovered: hoveredMessageID == message.id || model.focusedMessageID == message.id
                        )
                        .id(message.id)
                        .onHover { inside in
                            if inside { hoveredMessageID = message.id } else if hoveredMessageID == message.id { hoveredMessageID = nil }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: style == .window ? 760 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: style == .panel ? 120 : 300, maxHeight: style == .panel ? 520 : .infinity)
            .fixedSize(horizontal: false, vertical: style == .panel)
            .onChange(of: conversation.messages.last?.text.count) { scrollToEnd(proxy, conversation) }
            .onChange(of: conversation.messages.count) { scrollToEnd(proxy, conversation) }
            .onChange(of: model.focusedMessageID) { _, id in
                if let id { withAnimation(Motion.resize(model.reduceMotion)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onAppear { scrollToEnd(proxy, conversation) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ conversation: Conversation) {
        guard let last = conversation.messages.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }

    // MARK: Composer

    private func composer(_ conversation: Conversation) -> some View {
        let running = store.isRunning(conversation.id)
        return HStack(spacing: 12) {
            TextField(placeholder(conversation), text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .focused($inputFocused)
                .accessibilityLabel("Follow-up")
                .onKeyPress(phases: .down) { press in handleKey(press, conversation) }
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
                Button { model.beginShare(conversation.id) } label: {
                    HStack(spacing: 4) { Text(conversation.pickedUp != nil ? "Share back…" : "Share…"); Kbd("⌘⇧S") }
                }
                .controlSize(.small)
                .disabled(conversation.messages.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 54)
    }

    private func placeholder(_ conversation: Conversation) -> String {
        if conversation.provider.isDeep { return "Reply to \(conversation.provider.displayName)…" }
        return conversation.messages.isEmpty ? "Ask anything…" : "Ask a follow-up…"
    }

    private func handleKey(_ press: KeyPress, _ conversation: Conversation) -> KeyPress.Result {
        let cmd = press.modifiers.contains(.command)
        switch press.key {
        case .return:
            if cmd { model.onExpand?(conversation.id); return .handled }
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored } // newline
            if let last = conversation.messages.last, last.error != nil, model.draft.isEmpty {
                store.retry(in: conversation.id); return .handled
            }
            model.submitInChat(conversation.id); return .handled
        case .upArrow where model.draft.isEmpty:
            model.moveAnswerFocus(-1, in: conversation.id); return .handled
        case .downArrow where model.draft.isEmpty:
            model.moveAnswerFocus(1, in: conversation.id); return .handled
        case .escape:
            if style == .panel { model.escape() } else { model.draft = "" }
            return .handled
        default:
            break
        }
        guard cmd else { return .ignored }
        switch press.characters {
        case "k": model.keepFocused(in: conversation.id); return .handled
        case "c" where model.draft.isEmpty: model.copyFocused(in: conversation.id); return .handled
        case "p": model.showProviderMenu.toggle(); return .handled
        default:
            if let digit = press.characters.first, let provider = ProviderKind.allCases.first(where: { $0.shortcutDigit == digit }) {
                model.selectProvider(provider, for: conversation.id); return .handled
            }
            return .ignored
        }
    }
}

// MARK: - One message

struct MessageBlock: View {
    let message: Message
    let conversation: Conversation
    let model: PanelModel
    let hovered: Bool

    var body: some View {
        if message.role == .user {
            VStack(alignment: .leading, spacing: 4) {
                Text("You").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(message.text)
                    .font(.system(size: 15, weight: .semibold))
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
        } else if let error = message.error {
            ErrorCard(message: error, model: model, conversationID: conversation.id)
        } else {
            answer
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(message.author).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if message.kept { KeptLabel().transition(Motion.pop(model.reduceMotion)) }
            }
            if !message.steps.isEmpty { StepsList(steps: message.steps, running: message.isStreaming) }
            if message.isStreaming && message.text.isEmpty && message.steps.isEmpty {
                ThinkingRow(provider: conversation.provider, reduceMotion: model.reduceMotion)
            } else if !message.text.isEmpty {
                (Text(markdown: message.text) + Text(message.isStreaming ? " ▍" : "").foregroundStyle(Color.accentColor))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(message.editRequests) { request in
                EditRequestCard(request: request, provider: conversation.provider,
                                busy: model.store.isRunning(conversation.id)) {
                    model.store.allowEdits(messageID: message.id, in: conversation.id)
                }
            }
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
                Text(provider == .openRouter ? "OpenRouter · \(OpenRouterSettings.model.replacingOccurrences(of: "openrouter/", with: ""))" : provider.displayName)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Board 1 · 04: the question is kept; one-key retry.
struct ErrorCard: View {
    let message: String
    let model: PanelModel
    let conversationID: UUID

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Your question is still here.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings…") { model.onOpenSettings?() }.controlSize(.small)
            Button("Retry ↵") { model.store.retry(in: conversationID) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, -14)
    }

    private var headline: String {
        if message.contains("API key") { return "Add your OpenRouter key" }
        if message.contains("folder") { return "Choose a project folder" }
        return model.store.conversation(conversationID)?.provider == .openRouter ? "OpenRouter didn’t respond" : "The agent stopped"
    }
}

// MARK: - Deep chat pieces (board 6 · 02)

struct StepsList: View {
    let steps: [ToolStep]
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    if !step.done && running {
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    } else if step.failed {
                        Image(systemName: "xmark").foregroundStyle(.red).frame(width: 12)
                    } else if step.label == "Wants to edit" {
                        Image(systemName: "pencil").foregroundStyle(Color.accentColor).frame(width: 12)
                    } else {
                        Image(systemName: "checkmark").foregroundStyle(.green).frame(width: 12)
                    }
                    Text(step.label + (step.kind == .search && step.label == "Searched" ? "" : ""))
                    Text(step.detail).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(height: 22)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct EditRequestCard: View {
    let request: EditRequest
    let provider: ProviderKind
    let busy: Bool
    let onAllow: () -> Void
    @State private var showDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if request.id == "codex-edits" {
                    Text("\(provider.displayName) wants to edit files in this folder.").font(.system(size: 13))
                } else {
                    (Text("Edit ") + Text(request.fileName).font(.system(size: 12, design: .monospaced))
                        + Text(request.addedLines > 0 ? " (+\(request.addedLines) lines)?" : "?"))
                        .font(.system(size: 13))
                }
                Spacer()
                if request.id != "codex-edits" {
                    Button(showDiff ? "Hide diff" : "Show diff") { showDiff.toggle() }.controlSize(.small)
                }
                switch request.status {
                case .pending:
                    Button("Allow", action: onAllow).controlSize(.small).buttonStyle(.borderedProminent).disabled(busy)
                case .allowed, .applied:
                    Label("Allowed", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.green)
                }
            }
            if showDiff {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(request.oldText.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text("- " + line).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.06))
                    }
                    ForEach(Array(request.newText.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text("+ " + line).foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.06))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 0.5))
    }
}

struct FolderChip: View {
    let model: PanelModel
    let conversation: Conversation

    var body: some View {
        Button { model.onChooseFolder?(conversation.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(conversation.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Choose folder…")
                    .lineLimit(1).truncationMode(.head)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9).frame(height: 22)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 220)
        .help("Project folder the agent works in")
    }
}
