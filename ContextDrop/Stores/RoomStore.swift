import CoreGraphics
import Foundation
@preconcurrency import MultipeerConnectivity
import Observation

/// The room this Mac is in (if any): the shared cards, who is here, and the rules of the table.
///
/// The host holds the authoritative state: it checks every message a guest sends, applies it and relays it
/// to everyone else. Guests only talk to the host. Chats never enter a room; only cards put on the table do.
@MainActor
@Observable
final class RoomStore {
    /// Nil when not in a room. After the host leaves, the last state stays here (read-only) with `ended == true`
    /// until `leave()`, so people can still read what was on the table.
    private(set) var room: RoomState?
    private(set) var isHost = false
    /// The room was ended by its host (or the host disconnected). `leave()` clears it.
    private(set) var ended = false
    /// Accepted an invitation and waiting for the host's snapshot.
    private(set) var isJoining = false
    /// AI answer cards this Mac is currently streaming.
    private(set) var streamingCardIDs: Set<UUID> = []
    var notice: String?

    /// A room invitation arrived (show it; `join` / `declineInvitation` answer it).
    @ObservationIgnored var onInvitation: (@MainActor (RoomInvitation) -> Void)?
    /// The room opened, ended or was left, people came or went, or the pending invitations changed.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored let peers: PeerService
    @ObservationIgnored private let service: RoomService
    @ObservationIgnored private var joiningRoomID: UUID?
    @ObservationIgnored private var askTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingMoves: [UUID: RoomMessage] = [:]
    @ObservationIgnored private var lastMoveSent: [UUID: Date] = [:]
    @ObservationIgnored private var moveFlush: Task<Void, Never>?

    private static let moveInterval: TimeInterval = 1.0 / 15
    private static let streamLocalInterval: TimeInterval = 0.08
    private static let streamNetworkInterval: TimeInterval = 0.25

    init(peers: PeerService) {
        self.peers = peers
        service = RoomService(peers: peers)
        service.onInvitation = { [weak self] invitation in self?.onInvitation?(invitation) }
        service.onInvitationsChanged = { [weak self] in self?.onChange?() }
        service.onMessage = { [weak self] message, peerID in self?.handle(message, from: peerID) }
        service.onPeerConnected = { [weak self] peerID in self?.peerConnected(peerID) }
        service.onPeerDisconnected = { [weak self] peerID in self?.peerDisconnected(peerID) }
        service.onInviteUnanswered = { [weak self] peerID in self?.notice = "\(peerID.displayName) didn’t join." }
        service.onJoinFailed = { [weak self] in self?.joinFailed() }
    }

    // MARK: State

    var members: [RoomMember] { room?.members ?? [] }
    var pendingInvitations: [RoomInvitation] { service.pendingInvitations }
    /// In a live room (not nil, not ended).
    var isActive: Bool { room != nil && !ended }
    var localName: String { peers.localDisplayName }

    /// Nearby people who are not at the table yet.
    var invitablePeers: [NearbyPeer] {
        let here = Set(members.map(\.id))
        return peers.nearbyPeers.filter { !here.contains($0.name) }
    }

    func isInvited(_ peer: NearbyPeer) -> Bool { service.invitedPeers.contains(peer.peerID) }

    func card(_ id: UUID) -> RoomCard? { room?.cards.first { $0.id == id } }
    func canEdit(_ card: RoomCard) -> Bool { isActive && card.authorName == localName }
    func canRemove(_ card: RoomCard) -> Bool { isActive && (card.authorName == localName || isHost) }

    // MARK: Opening, inviting, joining, leaving

    /// Opens a room with this Mac as host. Does nothing while already in a live room.
    func openRoom(named: String? = nil) {
        guard !isActive else { return }
        reset()
        let trimmed = (named ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "\(localName)’s table" : trimmed
        room = RoomState(id: UUID(),
                         name: String(name.prefix(RoomLimits.maxRoomNameLength)),
                         hostName: localName,
                         members: [RoomMember(id: localName, name: localName, isHost: true)],
                         cards: [])
        isHost = true
        service.host()
        onChange?()
    }

    /// Host only: asks a nearby person to join. They get an invitation that lasts 60 s.
    func invite(_ peer: NearbyPeer) {
        guard isActive, isHost, let room else { return }
        guard !members.contains(where: { $0.id == peer.name }), !isInvited(peer) else { return }
        let invitation = RoomInvitation(id: room.id, name: room.name, hostName: localName, memberCount: room.members.count)
        if !service.invite(peer.peerID, invitation: invitation) {
            notice = "A room holds up to \(RoomService.maxPeers) people."
        }
    }

    func inviteAllNearby() {
        for peer in invitablePeers where !isInvited(peer) { invite(peer) }
    }

    /// Joins the invited room, leaving the current one first.
    func join(_ invitation: RoomInvitation) {
        if room != nil || isJoining { leave() }
        guard service.accept(invitation) else {
            notice = "That invitation expired. Ask \(invitation.hostName) to invite you again."
            onChange?()
            return
        }
        isJoining = true
        joiningRoomID = invitation.id
        onChange?()
    }

    func declineInvitation(_ invitation: RoomInvitation) {
        service.decline(invitation)
    }

    /// Leaves the room. The host leaving ends it for everyone.
    func leave() {
        if isActive {
            service.send(isHost ? .ended : .memberLeft(localName))
            service.close(afterFlush: true)
        } else {
            service.close()
        }
        reset()
        onChange?()
    }

    private func reset() {
        for task in askTasks.values { task.cancel() }
        askTasks = [:]
        streamingCardIDs = []
        moveFlush?.cancel()
        moveFlush = nil
        pendingMoves = [:]
        lastMoveSent = [:]
        room = nil
        isHost = false
        ended = false
        isJoining = false
        joiningRoomID = nil
    }

    private func markEnded(_ message: String) {
        for task in askTasks.values { task.cancel() }
        askTasks = [:]
        streamingCardIDs = []
        moveFlush?.cancel()
        pendingMoves = [:]
        service.close()
        isJoining = false
        joiningRoomID = nil
        if room != nil { ended = true }
        notice = message
        onChange?()
    }

    private func joinFailed() {
        guard isJoining else { return }
        isJoining = false
        joiningRoomID = nil
        notice = "Couldn’t join the room. Make sure you’re both on the same Wi-Fi (or Bluetooth is on) and ask for a new invitation."
        onChange?()
    }

    // MARK: Cards

    /// Puts a card on the table for everyone. A nil point means the next free spot in a loose grid.
    @discardableResult
    func addCard(kind: RoomCard.Kind, text: String, caption: String? = nil, at point: CGPoint? = nil) -> UUID {
        insertCard(kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), caption: caption, title: nil, question: nil, at: point)
    }

    private func insertCard(kind: RoomCard.Kind, text: String, caption: String?, title: String?, question: String?, at point: CGPoint?) -> UUID {
        let id = UUID()
        guard isActive, let cards = room?.cards else { return id }
        guard cards.count < RoomLimits.maxCards else {
            notice = "The table is full (\(RoomLimits.maxCards) cards). Remove some to add more."
            return id
        }
        let spot = point ?? nextFreeSpot(in: cards)
        let now = Date()
        let card = RoomCard(id: id, kind: kind, text: text, authorName: localName, x: spot.x, y: spot.y,
                            updatedAt: now, movedAt: now, caption: caption, title: title, question: question).sanitized()
        room?.cards.append(card)
        service.send(.addCard(card))
        return id
    }

    /// Where a card added without a position would land.
    func nextFreeSpot() -> CGPoint { nextFreeSpot(in: room?.cards ?? []) }

    private func nextFreeSpot(in cards: [RoomCard], from start: CGPoint? = nil) -> CGPoint {
        func taken(_ p: CGPoint) -> Bool {
            cards.contains { abs($0.x - p.x) < 200 && abs($0.y - p.y) < 130 }
        }
        if var p = start {
            // Next to something: step diagonally until clear.
            for _ in 0..<12 where taken(p) { p.x += 26; p.y += 26 }
            return p
        }
        let columns = 4
        for slot in 0..<(RoomLimits.maxCards * 2) {
            // A little stagger so the grid reads as a table, not a spreadsheet.
            let row = slot / columns, column = slot % columns
            let p = CGPoint(x: 56 + Double(column) * 256 + (row.isMultiple(of: 2) ? 0 : 18), y: 48 + Double(row) * 196 + Double(column % 2) * 14)
            if !taken(p) { return p }
        }
        return CGPoint(x: 56, y: 48)
    }

    /// Moves a card. Call it as often as you like (every drag frame): the position updates locally at once,
    /// and the network gets at most ~15 updates a second plus the final position.
    func moveCard(_ id: UUID, to point: CGPoint) {
        guard isActive, let index = room?.cards.firstIndex(where: { $0.id == id }), let card = room?.cards[index] else { return }
        let x = RoomLimits.clampX(point.x), y = RoomLimits.clampY(point.y)
        guard card.x != x || card.y != y else { return }
        let now = Date()
        // Always later than what we have seen, so a local move wins even when another Mac's clock runs ahead.
        let stamp = max(now, (card.movedAt ?? .distantPast).addingTimeInterval(0.001))
        room?.cards[index].x = x
        room?.cards[index].y = y
        room?.cards[index].movedAt = stamp
        let message = RoomMessage.moveCard(id, x: x, y: y, stamp: stamp)
        if now.timeIntervalSince(lastMoveSent[id] ?? .distantPast) >= Self.moveInterval {
            lastMoveSent[id] = now
            pendingMoves[id] = nil
            service.send(message)
        } else {
            pendingMoves[id] = message
            scheduleMoveFlush()
        }
    }

    private func scheduleMoveFlush() {
        guard moveFlush == nil else { return }
        moveFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.moveInterval))
            guard let self, !Task.isCancelled else { return }
            self.moveFlush = nil
            let now = Date()
            for (id, message) in self.pendingMoves {
                self.lastMoveSent[id] = now
                self.service.send(message)
            }
            self.pendingMoves = [:]
        }
    }

    /// Changes the text of one of your own cards.
    func editCard(_ id: UUID, text: String) {
        guard let card = card(id), canEdit(card) else { return }
        setText(id, text.trimmingCharacters(in: .whitespacesAndNewlines), broadcast: true)
    }

    private func setText(_ id: UUID, _ text: String, broadcast: Bool) {
        guard isActive, let index = room?.cards.firstIndex(where: { $0.id == id }), let card = room?.cards[index] else { return }
        let text = String(text.prefix(RoomLimits.maxTextLength))
        let stamp = max(Date(), card.updatedAt.addingTimeInterval(0.001))
        room?.cards[index].text = text
        room?.cards[index].updatedAt = stamp
        if broadcast { service.send(.editCard(id, text: text, stamp: stamp)) }
    }

    /// Removes one of your own cards (the host may remove any card).
    func removeCard(_ id: UUID) {
        guard let card = card(id), canRemove(card) else { return }
        askTasks.removeValue(forKey: id)?.cancel()
        streamingCardIDs.remove(id)
        pendingMoves[id] = nil
        lastMoveSent[id] = nil
        room?.cards.removeAll { $0.id == id }
        service.send(.removeCard(id))
    }

    // MARK: Ask the room

    /// Sends the selected cards plus the question to OpenAI (with this Mac's key). The answer streams into
    /// a new card that everyone sees.
    func ask(_ question: String, selected: Set<UUID>) {
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RoomLimits.maxQuestionLength))
        guard isActive, !question.isEmpty, let cards = room?.cards else { return }
        let context = cards.filter { selected.contains($0.id) && !$0.text.isEmpty }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }

        var spot: CGPoint?
        if let right = context.map(\.x).max(), let top = context.map(\.y).min() {
            spot = nextFreeSpot(in: cards, from: CGPoint(x: right + 256, y: top))
        }
        let id = insertCard(kind: .note, text: "", caption: "OpenAI · run by \(localName)", title: "AI answer", question: question, at: spot)
        guard card(id) != nil else { return } // table full

        var table = ""
        for card in context {
            let entry = "[\(card.displayLabel) · \(card.authorName)]\n\(card.text)\n\n"
            if table.count + entry.count > 24_000 { break }
            table += entry
        }
        let system = """
        You are helping a few people working together around a shared table of cards on their Macs. \
        Answer the question for the whole group, using the cards they selected as context. \
        Be direct and brief: short paragraphs or a short list. Plain text with light inline Markdown only.
        """
        let user = table.isEmpty ? question : "Cards on the table:\n\n\(table)Question: \(question)"
        let turns = [ChatTurn(role: "system", content: system), ChatTurn(role: "user", content: user)]

        streamingCardIDs.insert(id)
        askTasks[id] = Task { [weak self] in
            var text = ""
            do {
                await OpenAISettings.preload()
                let client = try OpenAIClient.fromSettings()
                var lastLocal = Date.distantPast
                var lastSent = Date.distantPast
                for try await delta in client.stream(turns) {
                    text += delta
                    guard let self, !Task.isCancelled else { return }
                    let now = Date()
                    if now.timeIntervalSince(lastLocal) >= Self.streamLocalInterval {
                        let broadcast = now.timeIntervalSince(lastSent) >= Self.streamNetworkInterval
                        self.setText(id, text, broadcast: broadcast)
                        lastLocal = now
                        if broadcast { lastSent = now }
                    }
                    if text.count >= RoomLimits.maxTextLength { break }
                }
                if text.isEmpty { text = "(No answer.)" }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                let message = cancelled ? "Stopped." : ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                text = text.isEmpty ? message : text + "\n\n" + message
            }
            guard let self, self.askTasks[id] != nil else { return } // card removed or room left
            self.askTasks[id] = nil
            self.streamingCardIDs.remove(id)
            self.setText(id, text, broadcast: true)
        }
    }

    // MARK: Peers coming and going

    private func peerConnected(_ peerID: MCPeerID) {
        // A guest introduces itself to the host and gets the snapshot back. The host waits for that hello.
        guard !isHost, service.isHostPeer(peerID) else { return }
        service.send(.hello(RoomMember(id: localName, name: localName, isHost: false)))
    }

    private func peerDisconnected(_ peerID: MCPeerID) {
        if isHost {
            removeMember(peerID.displayName, relayExcept: peerID)
        } else if service.isHostPeer(peerID) {
            markEnded(room == nil ? "Couldn’t join: \(peerID.displayName) closed the room." : "\(peerID.displayName) left, so the room ended.")
        }
    }

    /// Host: drops someone from the faces (their cards stay) and tells everyone else.
    private func removeMember(_ id: String, relayExcept: MCPeerID?) {
        guard let index = room?.members.firstIndex(where: { $0.id == id && !$0.isHost }) else { return }
        room?.members.remove(at: index)
        service.send(.memberLeft(id), except: relayExcept)
        onChange?()
    }

    // MARK: Incoming messages (already validated and size-limited by RoomCodec)

    private func handle(_ message: RoomMessage, from peerID: MCPeerID) {
        if isHost {
            handleAsHost(message, from: peerID)
        } else if service.isHostPeer(peerID) {
            handleAsGuest(message)
        }
    }

    private func handleAsHost(_ message: RoomMessage, from peerID: MCPeerID) {
        guard isActive, let room else { return }
        // The sender's identity is their peer name, never what the message claims.
        let sender = peerID.displayName
        if message.kind == .hello {
            if !room.members.contains(where: { $0.id == sender }) {
                guard room.members.count < RoomLimits.maxMembers else { return }
                let member = RoomMember(id: sender, name: sender, isHost: false)
                self.room?.members.append(member)
                service.send(.hello(member), except: peerID)
                onChange?()
            }
            if let state = self.room { service.send(.snapshot(state), to: [peerID]) }
            return
        }
        // Everything else only from people who are at the table.
        guard room.members.contains(where: { $0.id == sender && !$0.isHost }) else { return }
        switch message.kind {
        case .addCard:
            guard var card = message.card, room.cards.count < RoomLimits.maxCards,
                  !room.cards.contains(where: { $0.id == card.id }) else { return }
            card.authorName = sender
            self.room?.cards.append(card)
            service.send(.addCard(card), except: peerID)
        case .moveCard:
            guard applyMove(message) else { return }
            service.send(message, except: peerID)
        case .editCard:
            guard let id = message.cardID, card(id)?.authorName == sender, applyEdit(message) else { return }
            service.send(message, except: peerID)
        case .removeCard:
            guard let id = message.cardID, card(id)?.authorName == sender else { return }
            self.room?.cards.removeAll { $0.id == id }
            service.send(message, except: peerID)
        case .memberLeft:
            removeMember(sender, relayExcept: peerID)
        case .hello, .snapshot, .ended:
            break // only the host sends these
        }
    }

    private func handleAsGuest(_ message: RoomMessage) {
        if message.kind == .snapshot {
            guard var state = message.state, isJoining ? state.id == joiningRoomID : state.id == room?.id, !ended else { return }
            if !state.members.contains(where: { $0.id == localName }) {
                state.members.append(RoomMember(id: localName, name: localName, isHost: false))
            }
            room = state
            isJoining = false
            joiningRoomID = nil
            onChange?()
            return
        }
        guard isActive, let room else { return }
        switch message.kind {
        case .hello:
            guard let member = message.member, room.members.count < RoomLimits.maxMembers,
                  !room.members.contains(where: { $0.id == member.id }) else { return }
            self.room?.members.append(RoomMember(id: member.id, name: member.name, isHost: false))
            onChange?()
        case .addCard:
            guard let card = message.card, room.cards.count < RoomLimits.maxCards,
                  !room.cards.contains(where: { $0.id == card.id }) else { return }
            self.room?.cards.append(card)
        case .moveCard:
            _ = applyMove(message)
        case .editCard:
            _ = applyEdit(message)
        case .removeCard:
            guard let id = message.cardID else { return }
            askTasks.removeValue(forKey: id)?.cancel()
            streamingCardIDs.remove(id)
            self.room?.cards.removeAll { $0.id == id }
        case .memberLeft:
            guard let id = message.memberID, id != localName else { return }
            self.room?.members.removeAll { $0.id == id && !$0.isHost }
            onChange?()
        case .ended:
            markEnded("\(room.hostName) ended the room.")
        case .snapshot:
            break
        }
    }

    /// Last write wins. False when the card is gone or we already have a newer position.
    private func applyMove(_ message: RoomMessage) -> Bool {
        guard let id = message.cardID, let x = message.x, let y = message.y, let stamp = message.stamp,
              let index = room?.cards.firstIndex(where: { $0.id == id }), let card = room?.cards[index],
              stamp > (card.movedAt ?? .distantPast) else { return false }
        room?.cards[index].x = x
        room?.cards[index].y = y
        room?.cards[index].movedAt = stamp
        return true
    }

    private func applyEdit(_ message: RoomMessage) -> Bool {
        guard let id = message.cardID, let text = message.text, let stamp = message.stamp,
              let index = room?.cards.firstIndex(where: { $0.id == id }), let card = room?.cards[index],
              stamp > card.updatedAt else { return false }
        room?.cards[index].text = text
        room?.cards[index].updatedAt = stamp
        return true
    }
}
