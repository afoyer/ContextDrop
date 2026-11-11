import AppKit
import SwiftUI

/// What the menu bar popover can ask the app to do.
@MainActor
struct MenuBarActions {
    var openChat: (UUID) -> Void = { _ in }
    var openQuickChat: () -> Void = {}
    var openWindow: () -> Void = {}
    var newChat: () -> Void = {}
    var openSettings: () -> Void = {}
    var openRoom: () -> Void = {}
    var dropCurrent: () -> Void = {}
    var close: () -> Void = {}
}

/// R3 board 3: what's brewing, at a glance. Things waiting for you come first and can be answered here.
struct MenuBarView: View {
    let model: PanelModel
    let room: RoomStore
    let shortcut: String
    let actions: MenuBarActions

    private var store: ChatStore { model.store }
    private var peers: PeerService { model.peers }

    private var needing: [Conversation] { store.conversationsNeedingYou }
    private var brewing: [Conversation] { store.runningConversations }
    private var offers: [IncomingOffer] { peers.offers.filter { $0.phase == .pending } }
    private var unread: [ReceivedShare] { store.received.filter { !$0.read } }
    private var done: [Conversation] { store.conversations.filter { store.finishedUnseen.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            nearby
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(room.pendingInvitations) { invitation in
                        HairlineDivider()
                        RoomInvitationView(store: room, invitation: invitation) { joined in
                            if joined { actions.openRoom() }
                        }
                    }
                    if !needing.isEmpty {
                        section("Needs you", tint: NeedsYou.tint)
                        ForEach(needing) { needsYou($0) }
                    }
                    if !brewing.isEmpty {
                        section("Brewing")
                        ForEach(brewing) { brewingRow($0) }
                    }
                    if !offers.isEmpty || !unread.isEmpty {
                        section("Incoming", tint: .accentColor)
                        ForEach(offers) { offer in
                            row(icon: AnyView(AvatarView(name: offer.senderName, size: 22)), title: offer.preview.tabTitles?.joined(separator: " · ") ?? offer.preview.title,
                                caption: "\(offer.senderName) shared \(offer.preview.whatWasShared)") {
                                Button("Decline") { model.decline(offer) }
                                Button(offer.preview.tabCount > 1 ? "Open as Tabs" : "Continue") { model.accept(offer, open: true); actions.close() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        ForEach(unread) { received in
                            row(icon: AnyView(AvatarView(name: received.share.senderName, size: 22)), title: received.share.title,
                                caption: "From \(received.share.senderName) · saved for later") {
                                Button("Continue") {
                                    model.continueChat(received.share)
                                    actions.openQuickChat()
                                }
                            }
                        }
                    }
                    if !done.isEmpty {
                        section("Done", tint: .green)
                        ForEach(done) { conversation in
                            row(icon: AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)), title: conversation.title,
                                caption: lastAnswer(conversation).map { String($0.prefix(90)) } ?? conversation.provider.displayName) {
                                Button("Copy") { copy(conversation) }
                                Button("Open") { actions.openChat(conversation.id) }
                            }
                        }
                    }
                    if needing.isEmpty && brewing.isEmpty && offers.isEmpty && unread.isEmpty && done.isEmpty && room.pendingInvitations.isEmpty {
                        HairlineDivider()
                        Text("Nothing brewing. Ask something with \(shortcut).")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 14)
                    }
                    HairlineDivider()
                    roomRow
                }
            }
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            HairlineDivider()
            footer
        }
        .frame(width: 360)
        .controlSize(.small)
    }

    // MARK: Nearby

    private var nearby: some View {
        let people = peers.nearbyPeers
        return HStack(spacing: 8) {
            if people.isEmpty {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
                Text("No one nearby").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: -5) {
                    ForEach(people.prefix(5)) { peer in
                        AvatarView(name: peer.name, size: 24).help(peer.name)
                    }
                }
                Text(people.count == 1 ? "\(people[0].name) is nearby" : "\(people.count) nearby")
                    .font(.system(size: 12)).lineLimit(1)
            }
            Spacer()
            Button("Drop current chat") { actions.dropCurrent() }
                .disabled(currentChat == nil)
                .help("Share the chat you're in with someone nearby")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    /// The chat a "Drop" from here would share.
    private var currentChat: UUID? {
        let id = model.workspace.selected ?? model.panelConversationID ?? store.recentConversations.first?.id
        return store.conversation(id)?.messages.isEmpty == false ? id : nil
    }

    // MARK: Sections

    private func section(_ title: String, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineDivider()
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).kerning(0.5)
                .foregroundStyle(tint)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        }
    }

    private func row<Buttons: View>(icon: AnyView, title: String, caption: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            buttons()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: Needs you

    @ViewBuilder
    private func needsYou(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(NeedsYou.tint).frame(width: 7, height: 7)
                Text(conversation.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                Button("Open…") { actions.openChat(conversation.id) }.buttonStyle(.link)
            }
            ForEach(conversation.pendingPermissions.prefix(2)) { request in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(request.isEdit ? "Edit \(request.fileName)?" : "\(request.tool):")
                            .font(.system(size: 12))
                        if request.isEdit { DiffStat(added: request.added, removed: request.removed) } else {
                            Text(request.summary).font(.system(size: 11.5, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                        }
                    }
                    HStack(spacing: 6) {
                        if request.isEdit { Button("See diff") { actions.openChat(conversation.id) } }
                        Spacer()
                        Button("Deny") { store.deny(request.id, in: conversation.id) }
                        Button("Allow") { store.allow(request.id, in: conversation.id) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(8)
                .background(NeedsYou.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            ForEach(conversation.pendingQuestions.prefix(1)) { question in
                if let item = question.current {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.question).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).lineLimit(3)
                        if item.multiSelect {
                            Button("Answer in the chat…") { actions.openChat(conversation.id) }
                        } else {
                            ForEach(Array(item.options.prefix(4).enumerated()), id: \.offset) { index, option in
                                Button {
                                    store.answer(question.id, with: option.label, in: conversation.id)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("\(index + 1)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                                        Text(option.label).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(NeedsYou.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: Brewing

    private func brewingRow(_ conversation: Conversation) -> some View {
        let run = store.terminals[conversation.id]?.run
        let agents = conversation.runningSubagents
        let step = conversation.messages.last.flatMap { message in message.steps.last(where: { !$0.done }) ?? message.steps.last }
        return HStack(spacing: 10) {
            ProgressView().controlSize(.small).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(caption(conversation, agents: agents, started: run?.startedAt, now: context.date, step: step))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            Button("Stop") { store.stop(conversation.id) }
            Button("Open") { actions.openChat(conversation.id) }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func caption(_ conversation: Conversation, agents: Int, started: Date?, now: Date, step: ToolStep?) -> String {
        var parts = [conversation.provider.displayName]
        if agents > 0 { parts.append("\(agents) agent\(agents == 1 ? "" : "s")") }
        if let started {
            let seconds = max(0, Int(now.timeIntervalSince(started)))
            parts.append(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s")
        }
        if let step { parts.append("\(step.label) \(step.detail)".trimmingCharacters(in: .whitespaces)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Room

    private var roomRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2").foregroundStyle(room.isActive ? Color.accentColor : Color.secondary).frame(width: 22)
            if room.isActive, let state = room.room {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text("\(room.members.count) here · \(state.tiles.count) tile\(state.tiles.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open") { actions.openRoom() }
            } else {
                Text("Open a room for people nearby").font(.system(size: 12.5))
                Spacer()
                Button("Open a Room") { actions.openRoom() }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { actions.openQuickChat() } label: { Text("Quick Chat  \(shortcut)") }
            Button("Window") { actions.openWindow() }
            Spacer()
            Button { actions.openSettings() } label: { Image(systemName: "gearshape") }
                .help("Settings…")
                .accessibilityLabel("Settings")
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func lastAnswer(_ conversation: Conversation) -> String? {
        conversation.messages.last(where: { $0.role != .user && $0.error == nil && !$0.text.isEmpty })?.text
    }

    private func copy(_ conversation: Conversation) {
        guard let text = lastAnswer(conversation) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.markSeen(conversation.id)
    }
}
