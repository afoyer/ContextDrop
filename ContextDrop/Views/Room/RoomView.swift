import AppKit
import SwiftUI

/// The room window's content: header, the canvas, the zoom control and the "Ask the room…" bar.
struct RoomView: View {
    let store: RoomStore
    let reduceMotion: () -> Bool
    /// Open a chat tile as a tab that stays connected to the room.
    var onPopOut: (UUID) -> Void = { _ in }
    /// Open one of this Mac's own runs (by run tile id), where it can be approved or stopped.
    var onOpenOwnRun: (UUID) -> Void = { _ in }
    /// Open what was taken home as a new private chat.
    var onTakeHome: (ShareSummary) -> Void = { _ in }

    @State private var selection: Set<UUID> = []
    @State private var draft: RoomDraft?
    @State private var viewport = RoomViewport()
    @State private var viewSize: CGSize = .zero
    @State private var sizes: [UUID: CGSize] = [:]
    @State private var question = ""
    @State private var confirmLeave = false
    @State private var showTakeHome = false
    @State private var watching: UUID?
    @State private var typingTiles: Set<UUID> = []
    @FocusState private var askFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            if store.room != nil {
                HStack(spacing: 0) {
                    table
                    if let watching {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                        RoomRunWatchPanel(store: store, tileID: watching) { self.watching = nil }
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                lobby
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(RoomPalette.header)
        .ignoresSafeArea(.container, edges: .top)
        .background { shortcuts }
        .onChange(of: store.room?.id) { _, _ in
            selection = []
            draft = nil
            question = ""
            sizes = [:]
            watching = nil
            typingTiles = []
            viewport = RoomViewport()
        }
        .onChange(of: viewport) { _, _ in updateCenter() }
        .onChange(of: viewSize) { _, _ in updateCenter() }
        .onChange(of: store.ended) { _, ended in
            // The room is over: offer to take things home, once.
            if ended, store.room?.tiles.isEmpty == false { showTakeHome = true }
        }
        .task(id: store.notice) {
            // Notices fade on their own; the "Room ended" banner stays until closed.
            guard store.notice != nil, !store.ended else { return }
            try? await Task.sleep(for: .seconds(7))
            if !Task.isCancelled { store.notice = nil }
        }
        .confirmationDialog(leaveTitle, isPresented: $confirmLeave) {
            if store.isHost {
                Button("End Room", role: .destructive) { store.leave(keepForTakeHome: true) }
            } else {
                Button("Leave") { store.leave(keepForTakeHome: true) }
                if hasOwnCards {
                    Button("Leave and Take My Cards") { store.leave(takingCards: true, keepForTakeHome: true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(leaveMessage)
        }
        .sheet(isPresented: $showTakeHome) {
            RoomTakeHomeSheet(store: store, onOpen: { share in
                showTakeHome = false
                onTakeHome(share)
            }, onClose: { showTakeHome = false })
        }
    }

    private var selectedTiles: [RoomTile] {
        store.tiles.filter { selection.contains($0.id) }
    }

    private var hasOwnCards: Bool {
        store.tiles.contains { $0.card != nil && $0.addedBy == store.localName }
    }

    private var leaveTitle: String { store.isHost ? "End the room for everyone?" : "Leave the room?" }

    private var leaveMessage: String {
        if store.isHost {
            return "You opened this room, so leaving ends it for everyone here. Chats you run here stop answering. You can each take things home afterwards."
        }
        let owns = store.tiles.contains { ($0.chat != nil || $0.run != nil) && $0.ownerName == store.localName }
        return owns
            ? "Your cards stay until the room ends unless you take them. Chats and runs on your Mac stay on the canvas but stop updating."
            : "Your cards stay until the room ends unless you take them with you."
    }

    /// A text field has the keyboard: ⌘V and Delete belong to it, not to the canvas.
    private var textActive: Bool { askFocused || draft != nil || !typingTiles.isEmpty }

    private func updateCenter() {
        guard viewSize.width > 0 else { return }
        store.viewCenter = viewport.toCanvas(viewMiddle)
    }

    private func animate(_ change: () -> Void) {
        if reduceMotion() { change() } else { withAnimation(Motion.resize(false), change) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Label("Room", systemImage: "square.grid.2x2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RoomPalette.chatLabel)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            if let room = store.room {
                Text(room.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(store.ended ? "· ended" : "· nearby only · ends when everyone leaves")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                if !store.ended {
                    runsPill
                    faces(room.members)
                    addMenu
                    inviteMenu
                }
                Button(store.ended ? "Close" : "Leave") {
                    if store.isActive, store.members.count > 1 || !store.tiles.isEmpty {
                        confirmLeave = true
                    } else {
                        store.leave()
                    }
                }
                .help(store.isActive && store.isHost ? "Ends the room for everyone" : "Leave the room")
            } else {
                Text(store.isJoining ? "Joining…" : "No room open")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
            }
        }
        .padding(.leading, 82) // clear of the window's traffic lights
        .padding(.trailing, 14)
        .frame(height: 50)
    }

    @ViewBuilder
    private var runsPill: some View {
        let live = store.liveRuns
        if !live.isEmpty {
            let waiting = live.filter { if case .waiting = $0.run?.state { true } else { false } }.count
            HStack(spacing: 6) {
                if waiting == live.count {
                    Circle().fill(RoomPalette.waiting).frame(width: 7, height: 7)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(waiting == live.count
                     ? "\(waiting) run\(waiting == 1 ? "" : "s") waiting"
                     : "\(live.count) run\(live.count == 1 ? "" : "s") in progress")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(waiting == live.count ? RoomPalette.waitingLabel : RoomPalette.runLabel)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background((waiting == live.count ? RoomPalette.waiting : RoomPalette.running).opacity(0.16), in: Capsule())
            .fixedSize()
        }
    }

    private func faces(_ members: [RoomMember]) -> some View {
        // A green ring: this person's Claude Code run is working right now. Orange: it is waiting on them.
        var ring: [String: Color] = [:]
        for tile in store.liveRuns {
            guard let run = tile.run else { continue }
            if case .running = run.state { ring[run.ownerName] = RoomPalette.running } else if ring[run.ownerName] == nil { ring[run.ownerName] = RoomPalette.waiting }
        }
        return HStack(spacing: 8) {
            HStack(spacing: -6) {
                ForEach(members.prefix(5)) { member in
                    AvatarView(name: member.name, size: 24)
                        .overlay(Circle().strokeBorder(ring[member.id] ?? RoomPalette.header, lineWidth: ring[member.id] == nil ? 1.5 : 2))
                }
                if members.count > 5 {
                    Text("+\(members.count - 5)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.quaternary, in: Circle())
                }
            }
            Text("\(members.count) here")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .help(members.map { member in
            var text = member.isHost ? "\(member.name) (host)" : member.name
            if ring[member.id] != nil { text += " · running Claude Code" }
            return text
        }.joined(separator: ", "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(members.count) here: \(members.map(\.name).joined(separator: ", "))")
    }

    /// Everything that can go in the room, in one place: a new chat or thought, or one of this Mac's own
    /// Claude Code runs and OpenAI chats.
    private var addMenu: some View {
        let mine = (store.chats?.conversations ?? [])
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
        let runs = mine.filter { $0.provider == .claudeCode }.prefix(8)
        let chats = mine.filter { $0.provider == .openAI }.prefix(8)
        return Menu {
            Button("New Chat", systemImage: "bubble.left") {
                if let id = store.addChatTile(title: "New chat") { show(id) }
            }
            Button("New Thought", systemImage: "square.and.pencil", action: newThought)
            Section("Your Claude Code runs") {
                if runs.isEmpty {
                    Text("No Claude Code chats on this Mac yet")
                } else {
                    ForEach(runs) { conversation in
                        let shared = store.runs.tileID(for: conversation.id).flatMap(store.tile) != nil
                        Button(shared ? "\(conversation.title) · in the room" : conversation.title,
                               systemImage: shared ? "checkmark" : "terminal") {
                            if let id = store.shareRun(conversation) { show(id) }
                        }
                    }
                }
            }
            Section("Your OpenAI chats") {
                if chats.isEmpty {
                    Text("No OpenAI chats on this Mac yet")
                } else {
                    ForEach(chats) { conversation in
                        Button(conversation.title, systemImage: "bubble.left.and.bubble.right") {
                            if let id = store.shareChat(conversation) { show(id) }
                        }
                    }
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Add a chat, a thought, or one of your Claude Code runs to the room")
    }

    /// Selects a tile that was just added and brings it into view.
    private func show(_ id: UUID) {
        selection = [id]
        reveal(id)
    }

    private func newThought() {
        askFocused = false
        selection = []
        draft = RoomDraft(point: store.freeSpot(near: CGPoint(x: store.viewCenter.x - 125, y: store.viewCenter.y - 80)))
    }

    private var inviteMenu: some View {
        let nearby = store.invitablePeers
        return Menu {
            if !store.isHost {
                Text("Only \(store.room?.hostName ?? "the host") can invite people")
            } else if nearby.isEmpty {
                Text("No one else nearby right now")
            } else {
                ForEach(nearby) { peer in
                    Button(store.isInvited(peer) ? "\(peer.name) · invited…" : "\(peer.name) · \(peer.device)") { store.invite(peer) }
                        .disabled(store.isInvited(peer))
                }
                if nearby.count > 1 {
                    Divider()
                    Button("Invite Everyone Nearby") { store.inviteAllNearby() }
                }
            }
        } label: {
            Label("Invite nearby", systemImage: "person.badge.plus")
        }
        .menuStyle(.button)
        .fixedSize()
    }

    // MARK: Canvas

    private var table: some View {
        ZStack {
            RoomCanvas(store: store, viewport: $viewport, selection: $selection, draft: $draft,
                       sizes: $sizes, viewSize: $viewSize, typing: $typingTiles,
                       onInteract: { askFocused = false },
                       onPopOut: onPopOut,
                       onWatch: { id in animate { watching = id } },
                       onOpenOwnRun: onOpenOwnRun,
                       onSpawn: { ids in spawn(question: "", from: ids) })

            if store.room?.tiles.isEmpty == true, draft == nil, store.isActive {
                VStack(spacing: 6) {
                    Text("Nothing in the room yet")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Ask something below to start a chat everyone can reply in.\nDouble-click to write a thought, or drop files onto a chat.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.bottom, 120)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { banner.padding(.top, 14) }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                zoomControl
                if store.isActive { newThoughtButton }
            }
            .padding(16)
        }
        .overlay(alignment: .bottom) {
            if store.isActive {
                askBar
                    .padding(.horizontal, 190) // clear of the zoom control
                    .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if store.ended {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Room ended").font(.system(size: 13, weight: .semibold))
                    Text(store.notice ?? "You can still read the canvas. Nothing new is shared.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Button("Take Home…") { showTakeHome = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.tiles.isEmpty)
                Button("Close Room") { store.leave() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .roomPanel(radius: 12)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        } else if let notice = store.notice {
            HStack(spacing: 8) {
                Text(notice).font(.system(size: 12)).lineLimit(3)
                Button { store.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .roomPanel(radius: 14)
            .frame(maxWidth: 560)
        }
    }

    // MARK: Zoom

    private var viewMiddle: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    private func zoom(to target: CGFloat) {
        animate { viewport.setZoom(target, around: viewMiddle) }
    }

    /// Everything on the canvas, in one view.
    private func zoomToFit() {
        let bounds = store.tiles.reduce(CGRect.null) { $0.union(RoomMetrics.frame(for: $1, measured: sizes[$1.id])) }
        animate {
            if bounds.isNull { viewport = RoomViewport() } else { viewport.fit(bounds, in: viewSize, padding: 90) }
        }
    }

    /// Brings a tile into view if it isn't already.
    private func reveal(_ id: UUID) {
        guard let tile = store.tile(id) else { return }
        let frame = RoomMetrics.frame(for: tile)
        let visible = viewport.toCanvas(CGRect(origin: .zero, size: viewSize)).insetBy(dx: 40, dy: 100)
        guard !visible.contains(frame) else { return }
        animate {
            viewport.offset = CGSize(width: viewSize.width / 2 - frame.midX * viewport.zoom,
                                     height: viewSize.height / 2 - frame.midY * viewport.zoom - 40)
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            zoomButton("minus", "Zoom out") { zoom(to: viewport.zoom / 1.25) }
                .disabled(viewport.zoom <= RoomViewport.zoomRange.lowerBound + 0.001)
            Button { zoom(to: 1) } label: {
                Text("\(Int((viewport.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 42, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to 100% (⌘0)")
            .accessibilityLabel("Zoom \(Int((viewport.zoom * 100).rounded())) percent. Reset to 100 percent")
            zoomButton("plus", "Zoom in") { zoom(to: viewport.zoom * 1.25) }
                .disabled(viewport.zoom >= RoomViewport.zoomRange.upperBound - 0.001)
            Rectangle().fill(RoomPalette.border).frame(width: 0.5, height: 16)
            zoomButton("arrow.up.left.and.arrow.down.right", "Zoom to fit (⇧1)", action: zoomToFit)
        }
        .roomPanel(radius: 8)
    }

    private func zoomButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var newThoughtButton: some View {
        Button(action: newThought) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .roomPanel(radius: 8)
        .help("Write a new thought (or double-click the canvas)")
        .accessibilityLabel("New thought")
    }

    // MARK: Ask bar

    private var askBar: some View {
        let tiles = selectedTiles
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(tiles.isEmpty ? "Nothing selected" : "\(tiles.count) selected")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tiles.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(RoomPalette.chatLabel))
                    .fixedSize()
                ForEach(tiles.prefix(4)) { tile in
                    RoomChip(text: tile.shortLabel, color: RoomPalette.labelColor(for: tile))
                }
                if tiles.count > 4 {
                    Text("+\(tiles.count - 4)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(tiles.isEmpty ? "Everyone can see chats started here" : "The new chat starts from what you selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                TextField("Ask the room…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($askFocused)
                    .onSubmit { spawn(question: question, from: selection) }
                Button {
                    spawn(question: "", from: selection)
                } label: {
                    HStack(spacing: 4) {
                        Text(tiles.isEmpty ? "New chat" : "New chat from selection")
                        Text("⌘N").foregroundStyle(.secondary)
                    }
                }
                .help("A new chat tile on your Mac, started from the selected chats, their files and the selected cards")
                Button {
                    spawn(question: question, from: selection)
                } label: {
                    HStack(spacing: 4) {
                        Text("Ask")
                        Text("↵").opacity(0.8)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty)
                .accessibilityLabel("Ask the room")
            }
        }
        .padding(12)
        .frame(maxWidth: 720)
        .roomPanel(radius: 14)
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
    }

    /// A new chat tile on this Mac, started from `ids`. With a question it is asked straight away.
    private func spawn(question text: String, from ids: Set<UUID>) {
        guard store.isActive else { return }
        let asked = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let id = store.spawnChat(question: text, selected: ids) else { return }
        if asked { question = "" }
        selection = [id]
        reveal(id)
    }

    // MARK: Lobby (no room yet)

    private var lobby: some View {
        VStack(spacing: 14) {
            if store.isJoining {
                ProgressView()
                Text("Joining the room…").font(.system(size: 14, weight: .semibold))
                Button("Cancel") { store.leave() }
            } else {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("A shared canvas of chats for people nearby").font(.system(size: 15, weight: .semibold))
                Text("Your own chats stay private. Only what you put in the room is shared, and the room ends when everyone leaves.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Open a Room") { store.openRoom() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if let notice = store.notice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                ForEach(store.pendingInvitations) { invitation in
                    RoomInvitationView(store: store, invitation: invitation)
                        .roomPanel(radius: 12, fill: RoomPalette.card)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoomPalette.canvas)
    }

    // MARK: Shortcuts

    /// Invisible buttons carry the canvas's key commands, so they work wherever focus is in the window.
    /// The ones without ⌘ are off while a text field is being typed in.
    private var shortcuts: some View {
        Group {
            Button("New Chat from Selection") { spawn(question: "", from: selection) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!store.isActive)
            Button("Pop Out Chat") { if let id = selectedTiles.first(where: { $0.chat != nil })?.id { onPopOut(id) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!selectedTiles.contains { $0.chat != nil })
            Button("Paste as Note", action: pasteNote)
                .keyboardShortcut("v", modifiers: .command)
                .disabled(textActive || !store.isActive)
            Button("Remove Selected", action: removeSelected)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(textActive || selection.isEmpty || !store.isActive)
            Button("Remove Selected", action: removeSelected)
                .keyboardShortcut(.deleteForward, modifiers: [])
                .disabled(textActive || selection.isEmpty || !store.isActive)
            Button("Deselect") { selection = [] }
                .keyboardShortcut(.cancelAction)
                .disabled(textActive || selection.isEmpty || watching != nil)
            Button("Zoom to Fit", action: zoomToFit)
                .keyboardShortcut("1", modifiers: .shift)
                .disabled(textActive || store.room == nil)
            Button("Actual Size") { zoom(to: 1) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom In") { zoom(to: viewport.zoom * 1.25) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { zoom(to: viewport.zoom / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func pasteNote() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else {
            store.notice = "There’s no text on the clipboard to paste. Files go into a chat: drop them on a chat tile."
            return
        }
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = store.addCard(kind: .note, text: text) else { return }
        selection = [id]
        if text.count > RoomLimits.maxTextLength {
            store.notice = "That was long, so the note keeps the first \(RoomLimits.maxTextLength.formatted()) characters."
        }
    }

    private func removeSelected() {
        let tiles = selectedTiles
        let removable = tiles.filter(store.canRemove)
        for tile in removable { store.removeTile(tile.id) }
        selection.subtract(removable.map(\.id))
        if removable.count < tiles.count {
            store.notice = "You can only remove what you added, or chats and runs on your own Mac."
        }
    }
}
