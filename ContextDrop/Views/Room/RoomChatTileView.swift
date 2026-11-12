import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A chat tile: a live conversation anyone in the room can type into. It runs on its owner's Mac.
/// Files never float on the canvas; they live in a chat's file strip, and anyone can drop one in.
struct RoomChatTileView: View {
    enum Style {
        /// On the canvas: fixed width, the conversation scrolls inside a fixed height.
        case tile
        /// Popped out as a tab: fills the space it is given.
        case full
    }

    let store: RoomStore
    let tile: RoomTile
    let chat: RoomChatTile
    var style: Style = .tile
    var onPopOut: (() -> Void)?
    /// The reply field got or lost the keyboard (so the canvas leaves Delete and ⌘V to it).
    var onTyping: (Bool) -> Void = { _ in }

    @State private var dropTargeted = false
    @FocusState private var composerFocused: Bool

    private var isFull: Bool { style == .full }
    private var collapsed: Bool { tile.collapsed && !isFull }
    private var ownerHere: Bool { store.isPresent(chat.ownerName) }
    private var canType: Bool { store.isActive && ownerHere }
    private var isMine: Bool { chat.ownerName == store.localName }
    private var possessive: String { isMine ? "Yours" : "\(chat.ownerName)’s" }
    /// What this Mac is typing here. Kept in the store so the tile and its popped-out tab share it.
    private var draft: String { store.chatDrafts[tile.id] ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            header
            if collapsed {
                collapsedBody
            } else {
                if !chat.spawnedLabels.isEmpty { startedFrom }
                if !chat.files.isEmpty || !chat.runIDs.isEmpty { fileStrip }
                HairlineDivider()
                transcript
                HairlineDivider()
                composer
            }
        }
        .frame(width: isFull ? nil : RoomMetrics.chatWidth)
        .frame(maxWidth: isFull ? .infinity : nil, maxHeight: isFull ? .infinity : nil)
        .background(chat.spawnedFrom.isEmpty ? RoomPalette.tile : RoomPalette.spawned,
                    in: RoundedRectangle(cornerRadius: isFull ? 0 : RoomMetrics.tileRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: isFull ? 0 : RoomMetrics.tileRadius, style: .continuous))
        .overlay {
            if !isFull {
                RoundedRectangle(cornerRadius: RoomMetrics.tileRadius, style: .continuous)
                    .strokeBorder(chat.spawnedFrom.isEmpty ? RoomPalette.border : Color.accentColor.opacity(0.55),
                                  lineWidth: chat.spawnedFrom.isEmpty ? 0.5 : 1)
            }
        }
        .overlay { if dropTargeted { dropOverlay } }
        .shadow(color: .black.opacity(isFull ? 0 : 0.22), radius: 12, y: 5)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: drop)
        .onChange(of: composerFocused) { _, focused in onTyping(focused) }
        .onDisappear { if composerFocused { onTyping(false) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            RoomKindLabel(text: chat.spawnedFrom.isEmpty ? "Chat" : "Chat · spawned from \(chat.spawnedFrom.count)",
                          color: RoomPalette.chatLabel, symbol: chat.spawnedFrom.isEmpty ? nil : "plus")
            Text(chat.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            AvatarView(name: chat.ownerName, size: 18)
            Text("\(possessive) · OpenAI")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help("Runs on \(chat.ownerName)’s Mac with their OpenAI key (\(chat.model)). Anyone here can reply.")
            if !isFull {
                RoomCollapseButton(collapsed: tile.collapsed, noun: "chat") { store.setCollapsed(tile.id, !tile.collapsed) }
                if let onPopOut {
                    Button(action: onPopOut) {
                        HStack(spacing: 4) {
                            Text("Pop out")
                            Text("⌘↵").foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                    .help("Open this chat as a tab. It stays connected to the room.")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoomPalette.tileHeader)
    }

    // MARK: Collapsed

    private var collapsedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.files.isEmpty {
                HStack(spacing: 5) {
                    ForEach(chat.files.prefix(3)) { file in
                        RoomChip(text: file.name, color: file.isProblem ? RoomPalette.waitingLabel : .secondary)
                    }
                    if chat.files.count > 3 {
                        Text("+\(chat.files.count - 3)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            Text(lastLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var lastLine: String {
        if let reply = chat.lastReply, !reply.text.isEmpty {
            return "OpenAI: " + reply.text.replacingOccurrences(of: "\n", with: " ")
        }
        if let last = chat.messages.last(where: { $0.kind == .user }) { return "\(last.author): \(last.text)" }
        return "No messages yet"
    }

    // MARK: Started from

    private var startedFrom: some View {
        HStack(spacing: 5) {
            Text("Started from").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(chat.spawnedLabels.enumerated()), id: \.offset) { _, label in
                        RoomChip(text: label, color: RoomPalette.chatLabel, symbol: "circle.fill")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, chat.files.isEmpty && chat.runIDs.isEmpty ? 9 : 0)
    }

    // MARK: Files

    private var fileStrip: some View {
        let people = Set(chat.files.map(\.addedBy)).count
        return VStack(alignment: .leading, spacing: 8) {
            if !chat.files.isEmpty {
                HStack(spacing: 6) {
                    Text("Files in this chat · \(chat.files.count)\(people > 1 ? " · from \(people) people" : "")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("the model sees all of them")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(chat.files) { file in
                            RoomFileThumb(file: file, canRemove: store.canRemove(file, in: tile)) {
                                store.removeFile(file.id, from: tile.id)
                            }
                        }
                        if canType {
                            Button(action: pickFiles) {
                                Text("Drop a file to add it")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 8)
                                    .frame(width: 96, height: 78)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add a file to this chat")
                        }
                    }
                    .padding(.top, 5) // room for the adder's face on the corner
                    .padding(.trailing, 6)
                }
                if let problem = chat.files.first(where: \.isProblem) {
                    Text(problem.problemText(chatModel: chat.model))
                        .font(.system(size: 11))
                        .foregroundStyle(RoomPalette.waitingLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !chat.runIDs.isEmpty {
                HStack(spacing: 5) {
                    ForEach(chat.runIDs, id: \.self) { id in
                        if let run = store.tile(id)?.run {
                            RoomChip(text: "\(run.ownerName)’s run", color: RoomPalette.runLabel,
                                     symbol: run.isLive ? "arrow.triangle.2.circlepath" : "checkmark")
                                .help("This chat can read the progress of “\(run.title)”")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    // MARK: Conversation

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if chat.messages.isEmpty {
                        Text(canType ? "Ask something. Everyone in the room sees this chat and can reply." : "No messages.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(chat.messages) { message in
                        RoomChatMessageView(message: message, large: isFull).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frame(height: isFull ? nil : RoomMetrics.chatTranscriptHeight)
            .frame(maxHeight: isFull ? .infinity : nil)
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.messages.last?.text.utf8.count) { _, _ in
                if chat.messages.last?.streaming == true { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(canType ? "Anyone here can reply…" : (ownerHere ? "The room has ended" : "\(chat.ownerName) left, so this chat can’t answer"),
                      text: Binding(get: { draft }, set: { store.chatDrafts[tile.id] = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: isFull ? 14 : 13.5))
                .lineLimit(1...(isFull ? 8 : 4))
                .focused($composerFocused)
                .onSubmit(send)
                .disabled(!canType)
            Button(action: pickFiles) {
                Image(systemName: "paperclip")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canType)
            .help("Add a file to this chat")
            .accessibilityLabel("Add a file")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(sendable ? 1 : 0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!sendable)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var sendable: Bool { canType && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard sendable else { return }
        store.sendChat(draft, in: tile.id)
        store.chatDrafts[tile.id] = nil
    }

    private func pickFiles() {
        guard canType else { return }
        let chosen = FilePicker.files(prompt: "Add", message: "Add files to “\(chat.title)”. They are sent to \(isMine ? "OpenAI with your key" : "\(chat.ownerName)’s Mac"), and everyone here can ask about them.")
        store.addFiles(chosen, to: tile.id)
    }

    // MARK: Dropping files

    private var dropOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 24, weight: .regular))
            Text(isMine ? "Add to your chat" : "Add to \(chat.ownerName)’s chat")
                .font(.system(size: 14, weight: .semibold))
            Text("Everyone in it can ask about this file")
                .font(.system(size: 11.5))
                .opacity(0.85)
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
        }
        .padding(.top, 48)
        .padding([.horizontal, .bottom], 10)
        .allowsHitTesting(false)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard canType else { return false }
        let tileID = tile.id
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            Task { @MainActor in
                let urls = await FileDropDelegate.urls(from: files)
                store.addFiles(urls, to: tileID)
            }
            return true
        }
        // An image that is not a file (dragged out of a browser or another app).
        let images = providers.filter { $0.canLoadObject(ofClass: NSImage.self) }
        guard !images.isEmpty else { return false }
        for provider in images.prefix(4) {
            RoomImageDrop.load(provider) { data in
                if let data, let image = NSImage(data: data) { store.addImage(image, to: tileID) }
            }
        }
        return true
    }
}

/// Loads a dragged image. Item providers call back on their own queue, so the callback is made here,
/// outside the main actor, and only its result hops back.
enum RoomImageDrop {
    static func load(_ provider: NSItemProvider, done: @escaping @MainActor @Sendable (Data?) -> Void) {
        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
            let data = (object as? NSImage)?.tiffRepresentation
            Task { @MainActor in done(data) }
        }
    }
}

// MARK: - Messages

struct RoomChatMessageView: View, Equatable {
    let message: RoomChatMessage
    var large = false

    var body: some View {
        switch message.kind {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                AvatarView(name: message.author, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.author)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AvatarView.color(for: message.author))
                    Text(verbatim: message.text)
                        .font(.system(size: large ? 14 : 13.5))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(assistantHeader)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(message.failed ? AnyShapeStyle(RoomPalette.waitingLabel) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                if message.text.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Thinking…").font(.system(size: 12.5)).foregroundStyle(.tertiary)
                    }
                } else {
                    MarkdownView(message.text, fontSize: large ? 14 : 13, streaming: message.streaming)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.answerFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contextMenu {
                Button("Copy Answer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
            }
        case .event:
            HStack(spacing: 8) {
                line
                if !message.author.isEmpty { AvatarView(name: message.author, size: 15) }
                Text(message.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                line
            }
        }
    }

    private var line: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5).frame(minWidth: 12)
    }

    /// "OpenAI · saw activity-pane.png, notes.pdf"
    private var assistantHeader: String {
        var parts = [RoomChatMessage.assistantAuthor]
        if !message.sawFiles.isEmpty {
            let shown = message.sawFiles.prefix(3).joined(separator: ", ")
            let more = message.sawFiles.count > 3 ? " and \(message.sawFiles.count - 3) more" : ""
            parts.append("saw \(shown)\(more)")
        }
        if message.sawRuns { parts.append("read the run’s progress") }
        if message.failed { parts.append("couldn’t answer") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - File strip

extension RoomFile {
    var isProblem: Bool {
        switch status {
        case .unsupported, .failed: true
        case .sending, .ready: false
        }
    }

    /// Never hide a file the model can't use: say why, and what would work.
    func problemText(chatModel: String) -> String {
        switch status {
        case .unsupported(let suggested):
            "\(chatModel) can’t read “\(name)”. A model such as \(suggested) can: the chat’s owner can switch in Settings and add it again."
        case .failed(let reason):
            "“\(name)” isn’t available to the model. \(reason)"
        case .sending, .ready:
            ""
        }
    }
}

struct RoomFileThumb: View {
    let file: RoomFile
    let canRemove: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            preview
                .frame(height: 48)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    if file.status == .sending {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.35))
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            Text(file.name)
                .font(.system(size: 10.5))
                .foregroundStyle(file.isProblem ? AnyShapeStyle(RoomPalette.waitingLabel) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6)
        .frame(width: 96)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(file.isProblem ? RoomPalette.waiting : Color.primary.opacity(0.12), lineWidth: file.isProblem ? 1.5 : 0.5)
        }
        .overlay(alignment: .topTrailing) {
            Group {
                if hovering && canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Color.secondary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(file.name) from this chat")
                } else {
                    AvatarView(name: file.addedBy, size: 18)
                        .overlay(Circle().strokeBorder(RoomPalette.tile, lineWidth: 2))
                }
            }
            .offset(x: 5, y: -5)
        }
        .onHover { hovering = $0 }
        .help(helpText)
        .contextMenu {
            if canRemove { Button("Remove from Chat", role: .destructive, action: onRemove) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.name), added by \(file.addedBy)\(file.isProblem ? ", not readable by the model" : "")")
    }

    private var helpText: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        switch file.status {
        case .sending: return "\(file.name) · \(size) · added by \(file.addedBy) · on its way"
        case .ready: return "\(file.name) · \(size) · added by \(file.addedBy)"
        case .unsupported(let model): return "This chat’s model can’t read \(file.name). Try \(model)."
        case .failed(let reason): return "\(file.name): \(reason)"
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = RoomThumbnails.image(for: file) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            switch file.kind {
            case .pdf:
                badge("PDF", fill: Color(white: 0.9), text: Color(red: 0.77, green: 0.2, blue: 0.11))
            case .text:
                badge("{ }", fill: Color.accentColor.opacity(0.18), text: RoomPalette.chatLabel, mono: true)
            case .document:
                badge("DOC", fill: Color.primary.opacity(0.1), text: .secondary)
            case .image:
                badge("IMG", fill: Color.primary.opacity(0.1), text: .secondary)
            case .other:
                badge("FILE", fill: Color.primary.opacity(0.1), text: .secondary)
            }
        }
    }

    private func badge(_ label: String, fill: Color, text: Color, mono: Bool = false) -> some View {
        ZStack {
            fill
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: mono ? .monospaced : .default))
                .foregroundStyle(text)
        }
    }
}

/// Decoded thumbnails, so a tile that redraws (while dragging, while a reply streams) doesn't decode them again.
@MainActor
enum RoomThumbnails {
    private static let cache = NSCache<NSUUID, NSImage>()

    static func image(for file: RoomFile) -> NSImage? {
        if let cached = cache.object(forKey: file.id as NSUUID) { return cached }
        guard let data = file.thumbnail, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: file.id as NSUUID)
        return image
    }
}
