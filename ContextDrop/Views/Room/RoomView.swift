import AppKit
import SwiftUI

/// The room window's content: header, the table, the zoom control and the "Ask the room…" bar.
struct RoomView: View {
    let store: RoomStore
    let reduceMotion: () -> Bool

    @State private var selection: Set<UUID> = []
    @State private var draft: RoomDraft?
    @State private var zoom: CGFloat = 1
    @State private var question = ""
    @State private var confirmLeave = false
    @FocusState private var askFocused: Bool

    private static let zoomRange: ClosedRange<CGFloat> = 0.5...2

    var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            if store.room != nil {
                table
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
        }
        .task(id: store.notice) {
            // Notices fade on their own; the "Room ended" banner stays until closed.
            guard store.notice != nil, !store.ended else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { store.notice = nil }
        }
        .confirmationDialog("End the room for everyone?", isPresented: $confirmLeave) {
            Button("End Room", role: .destructive) { store.leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You opened this room, so leaving ends it for everyone here. Cards are not saved.")
        }
    }

    private var selectedCards: [RoomCard] {
        (store.room?.cards ?? []).filter { selection.contains($0.id) }
    }

    /// A text field has the keyboard: ⌘V and Delete belong to it, not to the table.
    private var textActive: Bool { askFocused || draft != nil }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Room")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Color.accentColor, in: Capsule())

            if let room = store.room {
                Text(room.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(store.ended ? "· ended" : "· nearby only · ends when everyone leaves")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                if !store.ended {
                    faces(room.members)
                    inviteMenu
                }
                Button(store.ended ? "Close" : "Leave") {
                    if store.isActive, store.isHost, store.members.count > 1 { confirmLeave = true } else { store.leave() }
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

    private func faces(_ members: [RoomMember]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: -6) {
                ForEach(members.prefix(5)) { member in
                    AvatarView(name: member.name, size: 22)
                        .overlay(Circle().strokeBorder(RoomPalette.header, lineWidth: 1.5))
                }
                if members.count > 5 {
                    Text("+\(members.count - 5)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                }
            }
            Text("\(members.count) here")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .help(members.map { $0.isHost ? "\($0.name) (host)" : $0.name }.joined(separator: ", "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(members.count) here: \(members.map(\.name).joined(separator: ", "))")
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

    // MARK: Table

    private var table: some View {
        ZStack {
            RoomCanvas(store: store, selection: $selection, draft: $draft, zoom: zoom, onInteract: { askFocused = false })

            if store.room?.cards.isEmpty == true, draft == nil, store.isActive {
                VStack(spacing: 6) {
                    Text("Nothing on the table yet")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Double-click to write a thought, or press ⌘V to add what you copied as a note.")
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
                    .padding(.horizontal, 124) // clear of the zoom control
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
                    Text(store.notice ?? "The host left. You can still read the table; nothing new is shared.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Button("Close Room") { store.leave() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RoomPalette.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        } else if let notice = store.notice {
            HStack(spacing: 8) {
                Text(notice).font(.system(size: 12)).lineLimit(2)
                Button { store.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(RoomPalette.border, lineWidth: 0.5))
            .frame(maxWidth: 560)
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            zoomButton("minus", "Zoom out", zoom / 1.25, disabled: zoom <= Self.zoomRange.lowerBound + 0.001)
            Rectangle().fill(RoomPalette.border).frame(width: 0.5, height: 16)
            zoomButton("plus", "Zoom in", zoom * 1.25, disabled: zoom >= Self.zoomRange.upperBound - 0.001)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RoomPalette.border, lineWidth: 0.5))
        .help("Zoom: \(Int((zoom * 100).rounded()))%")
    }

    private func zoomButton(_ symbol: String, _ label: String, _ target: CGFloat, disabled: Bool) -> some View {
        Button {
            let next = min(max(target, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
            // Snap back to exactly 100% when a step lands next to it.
            let snapped = abs(next - 1) < 0.06 ? 1 : next
            if reduceMotion() { zoom = snapped } else { withAnimation(Motion.resize(false)) { zoom = snapped } }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var newThoughtButton: some View {
        Button {
            askFocused = false
            selection = []
            draft = RoomDraft(point: store.nextFreeSpot())
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RoomPalette.border, lineWidth: 0.5))
        .help("Write a new thought (or double-click the table)")
        .accessibilityLabel("New thought")
    }

    // MARK: Ask bar

    private var askBar: some View {
        let cards = selectedCards
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(cards.isEmpty ? "No cards selected" : "\(cards.count) card\(cards.count == 1 ? "" : "s") selected")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(cards.isEmpty ? .secondary : .primary)
                    .fixedSize()
                ForEach(cards.prefix(4)) { card in
                    Text(card.displayLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(RoomPalette.labelColor(for: card))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(RoomPalette.labelColor(for: card).opacity(0.14), in: Capsule())
                        .fixedSize()
                }
                if cards.count > 4 {
                    Text("+\(cards.count - 4)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("Everyone can see questions asked here")
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
                    .onSubmit(ask)
                Button(action: ask) {
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(RoomPalette.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
    }

    private func ask() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.isActive, !trimmed.isEmpty else { return }
        store.ask(trimmed, selected: Set(selectedCards.map(\.id)))
        question = ""
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
                Text("A shared table for people nearby").font(.system(size: 15, weight: .semibold))
                Text("Your chats stay private. Only cards you put on the table are shared, and the room ends when everyone leaves.")
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
                        .background(RoomPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RoomPalette.border, lineWidth: 0.5))
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoomPalette.canvas)
    }

    // MARK: Table shortcuts (⌘V, Delete, Esc)

    /// Invisible buttons carry the table's key commands, so they work wherever focus is in the window.
    /// They are off while a text field is being typed in.
    private var shortcuts: some View {
        Group {
            Button("Paste as Note", action: pasteNote)
                .keyboardShortcut("v", modifiers: .command)
                .disabled(textActive || !store.isActive)
            Button("Remove Selected Cards", action: removeSelected)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(textActive || selection.isEmpty || !store.isActive)
            Button("Remove Selected Cards", action: removeSelected)
                .keyboardShortcut(.deleteForward, modifiers: [])
                .disabled(textActive || selection.isEmpty || !store.isActive)
            Button("Deselect") { selection = [] }
                .keyboardShortcut(.cancelAction)
                .disabled(textActive || selection.isEmpty)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func pasteNote() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else {
            store.notice = "There’s no text on the clipboard to paste."
            return
        }
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = store.addCard(kind: .note, text: text)
        guard store.card(id) != nil else { return }
        selection = [id]
        if text.count > RoomLimits.maxTextLength {
            store.notice = "That was long, so the note keeps the first \(RoomLimits.maxTextLength.formatted()) characters."
        }
    }

    private func removeSelected() {
        let cards = selectedCards
        let removable = cards.filter(store.canRemove)
        for card in removable { store.removeCard(card.id) }
        selection.subtract(removable.map(\.id))
        if removable.count < cards.count {
            store.notice = "You can only remove your own cards."
        }
    }
}
