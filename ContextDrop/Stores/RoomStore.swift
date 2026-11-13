import AppKit
import CoreGraphics
import Foundation
@preconcurrency import MultipeerConnectivity
import Observation
import UniformTypeIdentifiers

/// The room this Mac is in (if any): the shared tiles, who is here, and the rules of the table.
///
/// The host holds the authoritative state: it checks every message a guest sends, applies it and relays it
/// to everyone else. Guests only talk to the host. Private chats never enter a room; only what someone puts
/// on the canvas does. A chat tile runs on its owner's Mac (`RoomChatEngine`), and a Claude Code run stays on
/// its owner's Mac (`RoomRunBroadcaster`); the room only carries their messages and summaries.
@MainActor
@Observable
final class RoomStore {
    /// Nil when not in a room. After the room ends (or this Mac leaves it), the last state stays here read-only
    /// with `ended == true` until `leave()`, so people can read it and take things home.
    private(set) var room: RoomState?
    private(set) var isHost = false
    private(set) var ended = false
    /// Accepted an invitation and waiting for the host's snapshot.
    private(set) var isJoining = false
    /// Log lines seen so far for each run tile (the "Watch" panel). Never sent anywhere.
    private(set) var runLogs: [UUID: [RunLogLine]] = [:]
    var notice: String?

    /// A room invitation arrived (show it; `join` / `declineInvitation` answer it).
    @ObservationIgnored var onInvitation: (@MainActor (RoomInvitation) -> Void)?
    /// The room opened, ended or was left, people came or went, or the pending invitations changed.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// This Mac's private chats: read for run tiles and written by "take home". Never sent as a whole.
    @ObservationIgnored weak var chats: ChatStore?
    /// Where new tiles land when nothing says otherwise: the middle of what this Mac is looking at.
    @ObservationIgnored var viewCenter = CGPoint(x: 480, y: 320)
    /// What this Mac is typing into each chat tile. Never sent; shared by the canvas tile and its popped-out tab.
    var chatDrafts: [UUID: String] = [:]
    /// A local draft rescued when its chat tile disappears while someone is typing or sending.
    var recoveredChatDraft: String?
    private(set) var sendingChatTiles: Set<UUID> = []
    private(set) var slowChatTiles: Set<UUID> = []

    @ObservationIgnored let peers: PeerService
    @ObservationIgnored private let identityOverride: RoomMember?
    @ObservationIgnored private let service: any RoomTransport
    @ObservationIgnored private(set) lazy var engine = RoomChatEngine(store: self)
    @ObservationIgnored private(set) lazy var runs = RoomRunBroadcaster(store: self)
    @ObservationIgnored private(set) lazy var inbox = RoomRunInbox(store: self)
    @ObservationIgnored private var joiningRoomID: UUID?
    @ObservationIgnored private var pendingMoves: [UUID: RoomMessage] = [:]
    @ObservationIgnored private var lastMoveSent: [UUID: Date] = [:]
    @ObservationIgnored private var moveFlush: Task<Void, Never>?
    @ObservationIgnored private var sizeLedger: RoomSizeLedger?
    @ObservationIgnored private var pending: [UUID: PendingOperation] = [:]
    @ObservationIgnored private var pendingTileActions: [UUID: [@MainActor () -> Void]] = [:]
    @ObservationIgnored private var pendingTileSettlements: [UUID: [@MainActor (String?) -> Void]] = [:]
    private var localPositions: [UUID: CGPoint] = [:]
    @ObservationIgnored private var finalMoveIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var peerMembers: [MCPeerID: String] = [:]
    @ObservationIgnored private var seenOperations: Set<UUID> = []
    @ObservationIgnored private var recentOperations: [UUID] = []
    @ObservationIgnored private var rejectionReason: String?

    private struct PendingOperation {
        var message: RoomMessage
        var finished: (@MainActor (String?) -> Void)?
    }

    private static let moveInterval: TimeInterval = 1.0 / 15
    private static let maxWatchLines = 400
    static let untitledChat = RoomReducer.untitledChat

    init(peers: PeerService, transport: (any RoomTransport)? = nil, identity: RoomMember? = nil) {
        self.peers = peers
        identityOverride = identity
        service = transport ?? RoomService(peers: peers)
        service.onInvitation = { [weak self] invitation in self?.onInvitation?(invitation) }
        service.onInvitationsChanged = { [weak self] in self?.onChange?() }
        service.onMessage = { [weak self] message, peerID in self?.handle(message, from: peerID) }
        service.onPeerConnected = { [weak self] peerID in self?.peerConnected(peerID) }
        service.onPeerDisconnected = { [weak self] peerID in self?.peerDisconnected(peerID) }
        service.onInviteUnanswered = { [weak self] peerID in self?.notice = "\(peerID.displayName) didn’t join." }
        service.onJoinFailed = { [weak self] in self?.joinFailed() }
        service.onFailure = { [weak self] error in self?.notice = error }
        service.onFile = { [weak self] url, name in
            guard let self else { try? FileManager.default.removeItem(at: url); return }
            self.fileArrived(url, name: name)
        }
    }

    // MARK: State

    var members: [RoomMember] { room?.members ?? [] }
    var tiles: [RoomTile] { room?.tiles ?? [] }
    var pendingInvitations: [RoomInvitation] { service.pendingInvitations }
    /// In a live room (not nil, not ended).
    var isActive: Bool { room != nil && !ended }
    var localName: String { identityOverride?.name ?? peers.localDisplayName }
    var localID: String { identityOverride?.id ?? LocalIdentity.memberID }
    /// How many people are at the table, this Mac included.
    var presentCount: Int { members.count }
    /// This Mac's runs that are in the room (by conversation id) and how much of each is shown. Never sent;
    /// changes are reported through `onChange`.
    var sharedRuns: [UUID: RunShareLevel] { runs.levels }

    /// Nearby people who are not at the table yet.
    var invitablePeers: [NearbyPeer] {
        return peers.nearbyPeers.filter { peerMembers[$0.peerID] == nil }
    }

    func isInvited(_ peer: NearbyPeer) -> Bool { service.invitedPeers.contains(peer.peerID) }
    func isPresent(_ id: String) -> Bool { members.contains { $0.id == id } }

    func tile(_ id: UUID) -> RoomTile? { room?.tiles.first { $0.id == id } }
    func whenTileAccepted(_ id: UUID, perform action: @escaping @MainActor () -> Void) {
        if tile(id) != nil { action() }
        else if pending.values.contains(where: { if case .addTile(let candidate) = $0.message { candidate.id == id } else { false } }) {
            pendingTileActions[id, default: []].append(action)
        }
    }
    func whenTileSettled(_ id: UUID, perform action: @escaping @MainActor (String?) -> Void) {
        if tile(id) != nil { action(nil) }
        else if pending.values.contains(where: { if case .addTile(let candidate) = $0.message { candidate.id == id } else { false } }) {
            pendingTileSettlements[id, default: []].append(action)
        }
    }
    func displayPosition(of tile: RoomTile) -> CGPoint { localPositions[tile.id] ?? tile.position }
    func canEdit(_ tile: RoomTile) -> Bool { isActive && tile.card != nil && tile.addedByID == localID }
    func canRemove(_ tile: RoomTile) -> Bool {
        isActive && (tile.addedByID == localID || tile.ownerID == localID || isHost)
    }
    func canRemove(_ file: RoomFile, in tile: RoomTile) -> Bool {
        isActive && (file.addedByID == localID || tile.ownerID == localID)
    }

    /// Run tiles that are running or waiting on their owner.
    var liveRuns: [RoomTile] { tiles.filter { $0.run?.isLive == true } }

    // MARK: Opening, inviting, joining, leaving

    /// Opens a room with this Mac as host. Does nothing while already in a live room.
    func openRoom(named: String? = nil) {
        guard !isActive else { return }
        reset()
        let trimmed = (named ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "\(localName)’s table" : trimmed
        room = RoomState(id: UUID(),
                         name: String(name.prefix(RoomLimits.maxRoomNameLength)),
                         hostName: localName, hostID: localID,
                         members: [RoomMember(id: localID, name: localName, isHost: true)],
                         tiles: [])
        sizeLedger = room.flatMap { try? RoomSizeLedger(room: $0) }
        isHost = true
        service.host()
        onChange?()
    }

    /// Host only: asks a nearby person to join. They get an invitation that lasts 60 s.
    func invite(_ peer: NearbyPeer) {
        guard isActive, isHost, let room else { return }
        guard peerMembers[peer.peerID] == nil, !isInvited(peer) else { return }
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
    /// - `takingCards`: also takes this Mac's own cards off the table first.
    /// - `keepForTakeHome`: keeps a read-only copy here (`ended == true`) so things can be taken home;
    ///   call `leave()` again to close it.
    func leave(takingCards: Bool = false, keepForTakeHome: Bool = false) {
        guard isActive else {
            service.close()
            reset()
            onChange?()
            return
        }
        if takingCards {
            for tile in tiles where tile.card != nil && tile.addedByID == localID { removeTile(tile.id) }
        }
        flushMoves()
        service.send(isHost ? .ended : .memberLeft(localID))
        service.close(afterFlush: true)
        if keepForTakeHome, room?.tiles.isEmpty == false {
            stopWork()
            room?.settleStreams()
            ended = true
            notice = nil
        } else {
            reset()
        }
        onChange?()
    }

    /// Stops everything this Mac was doing for the room (replies, uploads, run updates).
    private func stopWork() {
        engine.reset()
        runs.reset()
        inbox.reset()
        moveFlush?.cancel()
        moveFlush = nil
        pendingMoves = [:]
        lastMoveSent = [:]
    }

    private func reset() {
        stopWork()
        for id in Array(pending.keys) { finishPending(id, error: "The room ended before this change was accepted.") }
        pendingTileActions = [:]
        pendingTileSettlements = [:]
        localPositions = [:]
        finalMoveIDs = [:]
        sizeLedger = nil
        peerMembers = [:]
        seenOperations = []
        recentOperations = []
        runLogs = [:]
        sendingChatTiles = []
        slowChatTiles = []
        room = nil
        isHost = false
        ended = false
        isJoining = false
        joiningRoomID = nil
    }

    private func markEnded(_ message: String) {
        stopWork()
        for id in Array(pending.keys) { finishPending(id, error: message) }
        pendingTileActions = [:]
        pendingTileSettlements = [:]
        sendingChatTiles = []
        slowChatTiles = []
        localPositions = [:]
        finalMoveIDs = [:]
        service.close()
        isJoining = false
        joiningRoomID = nil
        if room != nil {
            room?.settleStreams()
            ended = true
        }
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

    // MARK: Posting changes

    /// Applies a change made on this Mac and sends it to the room. False when it was not allowed.
    @discardableResult
    func post(_ message: RoomMessage, onAccepted: (@MainActor (String?) -> Void)? = nil) -> Bool {
        guard isActive else { return false }
        let id = UUID()
        if isHost {
            guard let applied = apply(message, sender: localID) else {
                notice = rejectionReason ?? "The room could not apply this change."
                return false
            }
            service.send(.accepted(id, applied))
            afterApply(applied)
            onAccepted?(nil)
            return true
        }
        guard pending.count < 256 else { notice = "Too many room changes are waiting for the host."; return false }
        pending[id] = PendingOperation(message: message, finished: onAccepted)
        guard service.send(.submit(id, message)) else {
            pending[id] = nil
            return false
        }
        return true
    }

    // MARK: Tiles

    private func makeTile(_ content: RoomTileContent, at point: CGPoint?, width: Double) -> RoomTile? {
        guard isActive, let tiles = room?.tiles else { return nil }
        guard tiles.count < RoomLimits.maxTiles else {
            notice = "The canvas is full (\(RoomLimits.maxTiles) tiles). Remove some to add more."
            return nil
        }
        let spot = point ?? freeSpot(near: CGPoint(x: viewCenter.x - width / 2, y: viewCenter.y - 120))
        return RoomTile(id: UUID(), x: spot.x, y: spot.y, addedBy: localName, addedByID: localID, content: content).sanitized()
    }

    /// Puts a card on the canvas for everyone. A nil point means a free spot in the middle of the view.
    @discardableResult
    func addCard(kind: RoomCardBody.Kind, text: String, caption: String? = nil, at point: CGPoint? = nil,
                 onAccepted: (@MainActor (String?) -> Void)? = nil) -> UUID? {
        let body = RoomCardBody(kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), caption: caption)
        guard let tile = makeTile(.card(body), at: point, width: RoomMetrics.cardWidth),
              post(.addTile(tile), onAccepted: onAccepted) else { return nil }
        return tile.id
    }

    /// The first spot at or after `start` (stepping right, then down) that doesn't sit on another tile.
    func freeSpot(near start: CGPoint) -> CGPoint {
        let tiles = room?.tiles ?? []
        func taken(_ p: CGPoint) -> Bool {
            tiles.contains { abs($0.x - p.x) < 120 && abs($0.y - p.y) < 90 }
        }
        var p = start
        for _ in 0..<40 where taken(p) { p.x += 34; p.y += 34 }
        return p
    }

    /// Moves a tile. Call it as often as you like (every drag frame): the position updates locally at once,
    /// and the network gets at most ~15 updates a second plus the final position.
    func moveTile(_ id: UUID, to point: CGPoint) {
        guard isActive, let tile = tile(id) else { return }
        let position = CGPoint(x: RoomLimits.clampCoordinate(point.x), y: RoomLimits.clampCoordinate(point.y))
        guard displayPosition(of: tile) != position else { return }
        localPositions[id] = position
        let message = RoomMessage.moveTile(id, x: position.x, y: position.y)
        let now = Date()
        if now.timeIntervalSince(lastMoveSent[id] ?? .distantPast) >= Self.moveInterval {
            lastMoveSent[id] = now
            pendingMoves[id] = nil
            sendMove(message, tileID: id)
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
            self.flushMoves()
        }
    }

    private func flushMoves() {
        let now = Date()
        let moves = pendingMoves
        pendingMoves = [:]
        for (id, message) in moves {
            lastMoveSent[id] = now
            sendMove(message, tileID: id)
        }
    }

    private func sendMove(_ message: RoomMessage, tileID: UUID) {
        if isHost {
            _ = post(message)
            localPositions[tileID] = nil
            return
        }
        let operationID = UUID()
        guard pending.count < 256 else { notice = "Too many room changes are waiting for the host."; return }
        pending[operationID] = PendingOperation(message: message, finished: nil)
        finalMoveIDs[tileID] = operationID
        guard service.send(.submit(operationID, message)) else {
            pending[operationID] = nil
            finalMoveIDs[tileID] = nil
            localPositions[tileID] = nil
            return
        }
    }

    /// Changes the text of one of your own cards.
    @discardableResult
    func editCard(_ id: UUID, text: String, onAccepted: (@MainActor (String?) -> Void)? = nil) -> Bool {
        guard let tile = tile(id), canEdit(tile) else { return false }
        return post(.editTile(id, text: text.trimmingCharacters(in: .whitespacesAndNewlines)), onAccepted: onAccepted)
    }

    /// Removes a tile you added or own (the host may remove any tile).
    func removeTile(_ id: UUID) {
        guard let tile = tile(id), canRemove(tile) else { return }
        pendingMoves[id] = nil
        lastMoveSent[id] = nil
        post(.removeTile(id))
    }

    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let tile = tile(id), tile.collapsed != collapsed else { return }
        post(.setCollapsed(id, collapsed))
    }

    // MARK: Chat tiles

    /// A new chat tile owned by this Mac. Returns nil when the canvas is full.
    @discardableResult
    func addChatTile(title: String, messages: [RoomChatMessage] = [], files: [RoomFile] = [], runIDs: [UUID] = [],
                     spawnedFrom: [UUID] = [], spawnedLabels: [String] = [], at point: CGPoint? = nil) -> UUID? {
        let chat = RoomChatTile(title: title, ownerName: localName, ownerID: localID, model: OpenAISettings.model, messages: messages,
                                files: files, runIDs: runIDs, spawnedFrom: spawnedFrom, spawnedLabels: spawnedLabels)
        guard let tile = makeTile(.chat(chat), at: point, width: RoomMetrics.chatWidth), post(.addTile(tile)) else { return nil }
        return tile.id
    }

    /// Anyone in the room can reply in any chat tile. The answer comes from the tile owner's Mac.
    @discardableResult
    func sendChat(_ text: String, in tileID: UUID) -> Bool {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RoomLimits.maxQuestionLength))
        guard isActive, !trimmed.isEmpty, !sendingChatTiles.contains(tileID), let chat = tile(tileID)?.chat else { return false }
        guard members.contains(where: { $0.id == chat.ownerID }) else {
            notice = "\(chat.ownerName) left the room, so this chat can’t answer any more. Select it and start a new chat from it."
            return false
        }
        sendingChatTiles.insert(tileID)
        let submittedDraft = chatDrafts[tileID] ?? text
        let accepted = post(.chatMessage(tileID, RoomChatMessage(id: UUID(), kind: .user, author: localName, text: trimmed)),
                            onAccepted: { [weak self] error in
            guard let self else { return }
            self.sendingChatTiles.remove(tileID)
            self.slowChatTiles.remove(tileID)
            if error == nil, self.chatDrafts[tileID] == submittedDraft { self.chatDrafts[tileID] = nil }
        })
        guard accepted else {
            sendingChatTiles.remove(tileID)
            notice = notice ?? "Couldn’t send the message. Your draft is saved."
            return false
        }
        if sendingChatTiles.contains(tileID) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.sendingChatTiles.contains(tileID) else { return }
                self.slowChatTiles.insert(tileID)
            }
        }
        return true
    }

    /// "Ask the room" and "New chat from selection": a new chat tile on this Mac, started from the selected
    /// tiles (a summary of each selected chat, all of their files, and the selected cards).
    @discardableResult
    func spawnChat(question: String, selected: Set<UUID>) -> UUID? {
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RoomLimits.maxQuestionLength))
        guard isActive else { return nil }
        let (sources, spot) = spawnSources(selected)

        // Every selected chat's files come along. Ones this Mac already holds are ready at once;
        // the rest are sent over by the chat that has them.
        var files: [RoomFile] = []
        var askOwners: [UUID] = []
        for tile in sources {
            guard let chat = tile.chat else { continue }
            var needsBytes = false
            for file in chat.files where file.status == .ready && !files.contains(where: { $0.id == file.id }) {
                guard files.count < RoomLimits.maxFilesPerChat else { break }
                var copy = file
                if !engine.holds(file.id) {
                    copy.status = .sending
                    needsBytes = true
                }
                files.append(copy)
            }
            if needsBytes { askOwners.append(tile.id) }
        }
        let runIDs = sources.filter { $0.run != nil }.map(\.id)
            + sources.compactMap(\.chat).flatMap(\.runIDs)
        var seenRuns = Set<UUID>()

        let title = question.isEmpty ? Self.untitledChat : Conversation.title(from: question)
        var messages: [RoomChatMessage] = []
        if !question.isEmpty { messages.append(RoomChatMessage(id: UUID(), kind: .user, author: localName, text: question)) }
        guard let id = addChatTile(title: title, messages: messages, files: files,
                                   runIDs: runIDs.filter { seenRuns.insert($0).inserted },
                                   spawnedFrom: sources.map(\.id), spawnedLabels: sources.map(\.shortLabel), at: spot) else { return nil }
        whenTileAccepted(id) { [weak self] in
            guard let self else { return }
            for source in askOwners { self.post(.requestFiles(from: source, to: id)) }
            self.engine.begin(id, from: sources, ask: !question.isEmpty)
        }
        return id
    }

    /// The selected tiles a new chat or run starts from, top to bottom, and a free spot beside them for it
    /// (nil, so it lands where new tiles do, when nothing is selected).
    func spawnSources(_ selected: Set<UUID>) -> (sources: [RoomTile], spot: CGPoint?) {
        let sources = Array(tiles.filter { selected.contains($0.id) }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .prefix(RoomLimits.maxSpawnSources))
        guard let right = sources.map({ $0.x + RoomMetrics.width(for: $0) }).max(), let top = sources.map(\.y).min() else {
            return (sources, nil)
        }
        return (sources, freeSpot(near: CGPoint(x: right + 70, y: top)))
    }

    // MARK: Files (always inside a chat tile)

    func addFiles(_ urls: [URL], to tileID: UUID) {
        for url in urls.prefix(8) { addFile(url, to: tileID) }
    }

    /// Adds a file to anyone's chat tile. The bytes go to the chat owner's Mac once; everyone else sees its name.
    func addFile(_ url: URL, to tileID: UUID, name: String? = nil) {
        guard isActive, let chat = tile(tileID)?.chat else { return }
        let name = name ?? url.lastPathComponent
        guard isPresent(chat.ownerID) else {
            notice = "\(chat.ownerName) left the room, so this chat can’t take new files."
            return
        }
        guard chat.files.count < RoomLimits.maxFilesPerChat else {
            notice = "This chat already holds \(RoomLimits.maxFilesPerChat) files. Remove one to add another."
            return
        }
        // Copy now: sending is asynchronous and the original may move.
        guard let (file, copy) = prepareFile(url, name: name) else { return }
        guard post(.addFile(tileID, file), onAccepted: { [weak self] error in
            guard let self, error == nil else { try? FileManager.default.removeItem(at: copy); return }
            if chat.ownerID == self.localID {
                self.engine.ingest(copy, tileID: tileID, fileID: file.id)
            } else {
                let owner = chat.ownerID
                self.service.sendFile(copy, name: Self.resourceName(tileID, file.id), toMember: owner) { [weak self] sent in
                    try? FileManager.default.removeItem(at: copy)
                    guard let self, !sent else { return }
                    self.removeFile(file.id, from: tileID)
                    self.notice = "“\(name)” couldn’t be sent to \(chat.ownerName)’s Mac."
                }
            }
        }) else {
            try? FileManager.default.removeItem(at: copy)
            return
        }
    }

    /// An image that isn't a file yet (dragged from a browser, pasted).
    func addImage(_ image: NSImage, to tileID: UUID) {
        guard let attachment = Attachments.save(image, name: "Image \(Date().formatted(date: .omitted, time: .shortened)).png") else { return }
        addFile(attachment.url, to: tileID, name: attachment.name)
        try? FileManager.default.removeItem(at: attachment.url)
    }

    /// Whoever added a file, or the chat's owner, can take it out. It is left out of every later request.
    func removeFile(_ fileID: UUID, from tileID: UUID) {
        guard let tile = tile(tileID), let file = tile.chat?.files.first(where: { $0.id == fileID }), canRemove(file, in: tile) else { return }
        post(.removeFile(tileID, fileID: fileID, messageID: UUID()))
    }

    private static func resourceName(_ tileID: UUID, _ fileID: UUID) -> String { "\(tileID.uuidString)|\(fileID.uuidString)" }

    /// Sends a file this Mac holds toward the owner of `tileID` (used when a chat is spawned from another owner's chat).
    func forwardFile(_ url: URL, tileID: UUID, fileID: UUID) {
        guard isActive, let chat = tile(tileID)?.chat, chat.ownerID != localID else { return }
        service.sendFile(url, name: Self.resourceName(tileID, fileID), toMember: chat.ownerID) { _ in }
    }

    /// File bytes arrived: for a chat or a run this Mac owns, or (on the host) to pass on to the tile's owner.
    private func fileArrived(_ url: URL, name: String) {
        let parts = name.split(separator: "|")
        guard isActive, parts.count == 2, let tileID = UUID(uuidString: String(parts[0])), let fileID = UUID(uuidString: String(parts[1])),
              let tile = tile(tileID), Self.sendingFile(fileID, in: tile) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if tile.ownerID == localID {
            if tile.run != nil {
                inbox.ingest(url, tileID: tileID, fileID: fileID)
            } else {
                engine.ingest(url, tileID: tileID, fileID: fileID)
            }
        } else if isHost {
            service.sendFile(url, name: name, toMember: tile.ownerID) { _ in try? FileManager.default.removeItem(at: url) }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The tile (a chat, or a follow-up on a run) has this file and is still waiting for its bytes.
    private static func sendingFile(_ fileID: UUID, in tile: RoomTile) -> Bool {
        switch tile.content {
        case .chat(let chat): chat.files.contains { $0.id == fileID && $0.status == .sending }
        case .run(let run): run.requests.contains { $0.status == .pending && $0.files.contains { $0.id == fileID && $0.status == .sending } }
        case .card: false
        }
    }

    // MARK: Claude Code and Codex runs

    /// Gives a chat a run's plan, status and changed files as context ("how far along is it?").
    func attachRun(_ runID: UUID, to chatID: UUID) {
        guard let chat = tile(chatID)?.chat, tile(runID)?.run != nil else { return }
        guard !chat.runIDs.contains(runID) else { return }
        guard chat.runIDs.count < RoomLimits.maxRunsPerChat else {
            notice = "This chat already follows \(RoomLimits.maxRunsPerChat) runs."
            return
        }
        post(.attachRun(runID, to: chatID, messageID: UUID()))
    }

    /// "Ask Camille…": a note on the run tile for its owner. It does not steer the run.
    func sendRunNote(_ text: String, to tileID: UUID) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RoomLimits.maxNoteLength))
        guard !trimmed.isEmpty, tile(tileID)?.run != nil else { return }
        post(.runNote(tileID, RunNote(id: UUID(), from: localName, text: trimmed)))
    }

    /// Whether this Mac can send a follow-up to a run tile now, and if not, why.
    func continueBlocker(_ tileID: UUID) -> String? {
        guard isActive, let run = tile(tileID)?.run else { return "The room has ended." }
        guard isPresent(run.ownerID) else { return "\(run.ownerName) left the room, so this run can’t be continued here." }
        if run.pendingRequests.count >= RoomLimits.maxRunRequests {
            return run.ownerID == localID
                ? "Run or dismiss the follow-ups waiting on this tile first."
                : "\(run.ownerName) has \(RoomLimits.maxRunRequests) follow-ups waiting. Try again once they’ve answered some."
        }
        if run.ownerID == localID { return inbox.blocker(for: tileID) }
        if run.pendingRequests.contains(where: { $0.fromID == localID }) {
            return "\(run.ownerName) hasn’t answered your last follow-up yet."
        }
        return nil
    }

    /// Continues a run from the room: a follow-up prompt with files, run in the same session on the owner's Mac.
    /// The owner's own follow-up runs at once; anyone else's waits on the tile until the owner runs or dismisses it.
    /// The file bytes go only to the owner's Mac.
    @discardableResult
    func continueRun(_ text: String, files urls: [URL], in tileID: UUID) -> Bool {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RoomLimits.maxQuestionLength))
        guard !trimmed.isEmpty || !urls.isEmpty, let run = tile(tileID)?.run else { return false }
        if let blocker = continueBlocker(tileID) {
            notice = blocker
            return false
        }
        // Copy each file now: sending is asynchronous and the original may move.
        let files = urls.prefix(RoomLimits.maxFilesPerRequest).compactMap { prepareFile($0) }
        if urls.count > RoomLimits.maxFilesPerRequest {
            notice = "A follow-up takes up to \(RoomLimits.maxFilesPerRequest) files; the rest were left out."
        }
        guard !trimmed.isEmpty || !files.isEmpty else { return false }
        return run.ownerID == localID
            ? continueOwnRun(trimmed, files: files, in: tileID)
            : askToContinue(trimmed, files: files, in: tileID, owner: run.ownerName)
    }

    /// The owner's own follow-up: its files are kept here and it runs at once.
    private func continueOwnRun(_ text: String, files prepared: [PreparedFile], in tileID: UUID) -> Bool {
        let files = prepared.map { item in
            var file = item.file
            let kept = inbox.keep(item.copy, fileID: file.id, name: file.name, tileID: tileID)
            file.status = kept ? .ready : .failed("It couldn’t be saved on your Mac.")
            return file
        }
        let request = RunRequest(id: UUID(), from: localName, text: text, files: files, status: .accepted)
        guard post(.runRequest(tileID, request), onAccepted: { [weak self] error in
            guard let self, error == nil else { self?.inbox.discard(request); return }
            self.inbox.run(request, in: tileID)
        }) else {
            inbox.discard(request)
            return false
        }
        return true
    }

    /// Someone else's run: the follow-up waits on the tile, and its files go to the owner's Mac.
    private func askToContinue(_ text: String, files prepared: [PreparedFile], in tileID: UUID, owner: String) -> Bool {
        let request = RunRequest(id: UUID(), from: localName, text: text, files: prepared.map(\.file), status: .pending)
        guard post(.runRequest(tileID, request), onAccepted: { [weak self] error in
            guard let self, error == nil else {
                for item in prepared { try? FileManager.default.removeItem(at: item.copy) }
                return
            }
            for (file, copy) in prepared {
                self.service.sendFile(copy, name: Self.resourceName(tileID, file.id), toMember: self.tile(tileID)?.run?.ownerID ?? "") { [weak self] sent in
                    try? FileManager.default.removeItem(at: copy)
                    guard let self, !sent else { return }
                    self.notice = "“\(file.name)” couldn’t be sent to \(owner)’s Mac."
                }
            }
        }) else {
            for item in prepared { try? FileManager.default.removeItem(at: item.copy) }
            return false
        }
        return true
    }

    /// The owner runs someone's follow-up in the run's own session. Files that never arrived are left out.
    func acceptRunRequest(_ requestID: UUID, in tileID: UUID) {
        guard let run = tile(tileID)?.run, run.ownerID == localID,
              let request = run.requests.first(where: { $0.id == requestID }), request.status == .pending else { return }
        if let blocker = inbox.blocker(for: tileID) {
            notice = blocker
            return
        }
        guard request.filesSettled else {
            notice = "\(request.from)’s files are still on their way."
            return
        }
        _ = post(.runRequestStatus(tileID, requestID: requestID, .accepted), onAccepted: { [weak self] error in
            if error == nil { self?.inbox.run(request, in: tileID) }
        })
    }

    /// The owner says no to a follow-up. Its files are deleted from this Mac.
    func dismissRunRequest(_ requestID: UUID, in tileID: UUID) {
        guard let run = tile(tileID)?.run, run.ownerID == localID,
              let request = run.requests.first(where: { $0.id == requestID }), request.status == .pending else { return }
        _ = post(.runRequestStatus(tileID, requestID: requestID, .dismissed), onAccepted: { [weak self] error in
            if error == nil { self?.inbox.discard(request) }
        })
    }

    /// A file checked and copied for the room, and the temporary copy that holds its bytes.
    private typealias PreparedFile = (file: RoomFile, copy: URL)

    /// Checks a file someone wants to add (to a chat or a follow-up) and copies it somewhere it can't move.
    /// Nil, with a notice, when it can't go. `name` is what the room sees; the file's own name by default.
    private func prepareFile(_ url: URL, name: String? = nil) -> PreparedFile? {
        let name = name ?? url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values?.isDirectory != true, let size = values?.fileSize else {
            notice = "“\(name)” isn’t a file that can be added. Folders can’t be sent."
            return nil
        }
        guard size <= RoomLimits.maxFileBytes else {
            notice = "“\(name)” is larger than 20 MB, so it wasn’t added."
            return nil
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxdrop-room-\(UUID().uuidString)").appendingPathExtension(url.pathExtension)
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else {
            notice = "“\(name)” couldn’t be read."
            return nil
        }
        let kind = RoomFile.Kind.of(url)
        let file = RoomFile(id: UUID(), name: name, kind: kind, size: size, addedBy: localName, addedByID: localID,
                            thumbnail: kind == .image ? RoomFile.thumbnail(url) : nil, status: .sending)
        return (file, copy)
    }

    /// Puts one of this Mac's Claude Code or Codex chats in the room as a live tile that people can continue.
    /// `level` says how much the room sees. A run already in the room keeps its tile and its level
    /// (`setShareLevel` changes that).
    @discardableResult
    func shareRun(_ conversation: Conversation, level: RunShareLevel = .steps) -> UUID? {
        guard isActive else { return nil }
        if let existing = runs.tileID(for: conversation.id) {
            if tile(existing) != nil { return existing }
            // Its tile is gone; share it afresh.
            runs.tileRemoved(existing)
        }
        guard let snapshot = runs.snapshot(of: conversation.id, level: level),
              let tile = makeTile(.run(snapshot), at: nil, width: RoomMetrics.runWidth), post(.addTile(tile)) else { return nil }
        whenTileAccepted(tile.id) { [weak self] in self?.runs.track(conversation.id, as: tile.id, level: level) }
        return tile.id
    }

    /// Takes one of this Mac's runs back out of the room (its tile is removed for everyone; the run goes on here).
    /// If the removal is refused, the tile and the share stay.
    func unshareRun(conversationID: UUID) {
        guard let tileID = runs.tileID(for: conversationID) else { return }
        removeTile(tileID)
        if tile(tileID) == nil { runs.tileRemoved(tileID) }
    }

    /// Changes how much of a shared run the room sees, from the next update on.
    func setShareLevel(_ level: RunShareLevel, for conversationID: UUID) {
        guard isActive else { return }
        runs.setLevel(level, forConversation: conversationID)
    }

    /// Puts one of this Mac's OpenAI chats in the room as a chat tile: its text, and its images as files.
    @discardableResult
    func shareChat(_ conversation: Conversation) -> UUID? {
        guard isActive else { return nil }
        let messages = conversation.messages.filter { $0.error == nil && !$0.text.isEmpty }.suffix(60).map { message in
            RoomChatMessage(id: UUID(), kind: message.role == .user ? .user : .assistant,
                            author: message.role == .user ? localName : RoomChatMessage.assistantAuthor, text: message.text, createdAt: message.createdAt)
        }
        guard let id = addChatTile(title: conversation.title, messages: Array(messages)) else { return nil }
        whenTileAccepted(id) { [weak self] in
            guard let self else { return }
            for attachment in conversation.allAttachments.filter(\.isImage).prefix(RoomLimits.maxFilesPerChat) {
                self.addFile(attachment.url, to: id, name: attachment.name)
            }
        }
        return id
    }

    // MARK: Peers coming and going

    private func peerConnected(_ peerID: MCPeerID) {
        // A guest introduces itself to the host and gets the snapshot back. The host waits for that hello.
        guard !isHost, service.isHostPeer(peerID) else { return }
        service.send(.hello(RoomMember(id: localID, name: localName, isHost: false)))
    }

    private func peerDisconnected(_ peerID: MCPeerID) {
        if isHost, let id = peerMembers.removeValue(forKey: peerID) {
            removeMember(id, relayExcept: peerID)
        } else if service.isHostPeer(peerID) {
            markEnded(room == nil ? "Couldn’t join: \(peerID.displayName) closed the room." : "\(peerID.displayName) left, so the room ended.")
        }
    }

    /// Host: drops someone from the faces (their tiles stay) and tells everyone else.
    private func removeMember(_ id: String, relayExcept: MCPeerID?) {
        guard let index = room?.members.firstIndex(where: { $0.id == id && !$0.isHost }) else { return }
        room?.members.remove(at: index)
        room?.memberGone(id)
        if let state = room { sizeLedger = try? RoomSizeLedger(room: state) }
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
        if case .hello(let claimed) = message {
            guard UUID(uuidString: claimed.id) != nil, claimed.id != room.hostID else { return }
            // A peer is bound to one installation ID for this session, independent of display name.
            guard peerMembers[peerID] == nil || peerMembers[peerID] == claimed.id else { return }
            guard !peerMembers.contains(where: { $0.key != peerID && $0.value == claimed.id }) else {
                notice = "A nearby Mac tried to join using another member’s identity."
                return
            }
            let member = RoomMember(id: claimed.id, name: peerID.displayName, isHost: false)
            if !room.members.contains(where: { $0.id == member.id }) {
                guard room.members.count < RoomLimits.maxMembers else { return }
                self.room?.members.append(member)
                if let state = self.room { sizeLedger = try? RoomSizeLedger(room: state) }
                service.send(.hello(member), except: peerID)
                onChange?()
            }
            peerMembers[peerID] = member.id
            service.bindMember(member.id, to: peerID)
            if let state = self.room { service.send(.snapshot(state), to: [peerID]) }
            return
        }
        guard let sender = peerMembers[peerID], room.members.contains(where: { $0.id == sender && !$0.isHost }) else { return }
        switch message {
        case .memberLeft:
            removeMember(sender, relayExcept: peerID)
        case .submit(let operationID, let change):
            guard seenOperations.insert(operationID).inserted else {
                service.send(.rejected(operationID, "This change was already processed."), to: [peerID])
                return
            }
            recentOperations.append(operationID)
            if recentOperations.count > 1_024 { seenOperations.remove(recentOperations.removeFirst()) }
            guard let applied = apply(change, sender: sender) else {
                let reason = rejectionReason ?? "The host could not apply this change."
                if case .chatDelta(let tileID, let attempted) = change,
                   reason.contains("room is full") {
                    settleFullStream(tileID: tileID, answerID: attempted.id)
                }
                service.send(.rejected(operationID, reason), to: [peerID])
                return
            }
            service.send(.accepted(operationID, applied))
            afterApply(applied)
        default:
            break // guests cannot send control messages or unwrapped changes
        }
    }

    private func handleAsGuest(_ message: RoomMessage) {
        if case .snapshot(let state) = message {
            guard isJoining ? state.id == joiningRoomID : state.id == room?.id, !ended,
                  state.members.contains(where: { $0.id == localID }) else { return }
            room = state
            sizeLedger = try? RoomSizeLedger(room: state)
            isJoining = false
            joiningRoomID = nil
            onChange?()
            return
        }
        guard isActive, let room else { return }
        switch message {
        case .hello(let member):
            guard room.members.count < RoomLimits.maxMembers,
                  !room.members.contains(where: { $0.id == member.id }) else { return }
            self.room?.members.append(member)
            onChange?()
        case .memberLeft(let id):
            guard id != localID else { return }
            self.room?.members.removeAll { $0.id == id && !$0.isHost }
            self.room?.memberGone(id)
            onChange?()
        case .ended:
            markEnded("\(room.hostName) ended the room.")
        case .rejected(let id, let reason):
            finishPending(id, error: reason)
        case .accepted(let id, let change):
            if let applied = apply(change, sender: nil) { afterApply(applied) }
            finishPending(id, error: nil)
        default:
            break // only host-confirmed changes can mutate a guest room
        }
    }

    private func finishPending(_ id: UUID, error: String?) {
        guard let operation = pending.removeValue(forKey: id) else { return }
        if let error { notice = error }
        switch operation.message {
        case .addTile(let tile):
            if error == nil { for action in pendingTileActions.removeValue(forKey: tile.id) ?? [] { action() } }
            else { pendingTileActions[tile.id] = nil }
            for action in pendingTileSettlements.removeValue(forKey: tile.id) ?? [] { action(error) }
        case .moveTile(let tileID, _, _):
            if finalMoveIDs[tileID] == id && pendingMoves[tileID] == nil {
                localPositions[tileID] = nil
                finalMoveIDs[tileID] = nil
            }
        default: break
        }
        operation.finished?(error)
    }

    private func settleFullStream(tileID: UUID, answerID: UUID) {
        guard let accepted = tile(tileID)?.chat?.messages.first(where: { $0.id == answerID && $0.streaming }) else { return }
        var stopped = accepted
        stopped.streaming = false
        stopped.failed = false
        stopped.failureReason = "Room capacity reached. Remove content before continuing."
        let change = RoomMessage.chatDelta(tileID, stopped)
        guard let applied = apply(change, sender: nil) else { return }
        service.send(.accepted(UUID(), applied))
        afterApply(applied)
    }

    // MARK: Applying a change

    /// Applies one change by the room's rules (`RoomReducer`). Returns the message to relay, with authorship
    /// stamped, or nil when the change was refused or is stale.
    private func apply(_ message: RoomMessage, sender: String?) -> RoomMessage? {
        rejectionReason = nil
        guard var state = room, let applied = RoomReducer.apply(message, to: &state, sender: sender) else {
            rejectionReason = "The change is no longer allowed or its target is gone."
            return nil
        }
        if isHost {
            do {
                let ledger: RoomSizeLedger
                if let existing = sizeLedger { ledger = existing }
                else { ledger = try RoomSizeLedger(room: room!) }
                let terminal: Bool
                if case .chatDelta(_, let reply) = applied { terminal = reply.failureReason != nil && !reply.streaming }
                else { terminal = false }
                guard let next = try ledger.admitting(state, change: applied, terminal: terminal) else {
                    rejectionReason = "The room is full. Remove content before adding more."
                    return nil
                }
                sizeLedger = next
            } catch {
                rejectionReason = "The room is too large to send to a new member."
                return nil
            }
        }
        room = state
        switch applied {
        case .addTile(let tile):
            if let run = tile.run { mergeLog(run.log, into: tile.id) }
        case .runUpdate(let id, let run):
            mergeLog(run.log, into: id)
        default: break
        }
        return applied
    }

    private func mergeLog(_ lines: [RunLogLine], into tileID: UUID) {
        // No log in the update: the owner shows steps only (or turned the log off), so drop what was seen.
        guard !lines.isEmpty else {
            if runLogs[tileID] != nil { runLogs[tileID] = nil }
            return
        }
        let last = runLogs[tileID]?.last?.seq ?? Int.min
        let new = lines.filter { $0.seq > last }
        guard !new.isEmpty else { return }
        var seen = runLogs[tileID] ?? []
        seen.append(contentsOf: new)
        if seen.count > Self.maxWatchLines { seen.removeFirst(seen.count - Self.maxWatchLines) }
        runLogs[tileID] = seen
    }

    /// What this Mac does because of a change (as the owner of a chat or a run).
    private func afterApply(_ message: RoomMessage) {
        switch message {
        case .chatDelta(let id, let reply):
            if reply.failureReason != nil && tile(id)?.chat?.ownerID == localID {
                engine.stopReply(id)
            }
        case .chatMessage(let id, let chat):
            guard chat.kind == .user, tile(id)?.chat?.ownerID == localID else { return }
            engine.userMessageArrived(id)
        case .addFile(let id, let file):
            guard tile(id)?.chat?.ownerID == localID, file.addedByID != localID else { return }
            engine.expectFile(file.id, in: id)
        case .removeFile(_, let fileID, _, _):
            engine.forgetFile(fileID)
        case .requestFiles(let source, let target):
            guard tile(source)?.chat?.ownerID == localID else { return }
            engine.sendFiles(from: source, to: target)
        case .removeTile(let id):
            engine.tileRemoved(id)
            runs.tileRemoved(id)
            inbox.tileRemoved(id)
            runLogs[id] = nil
            if let draft = chatDrafts[id], !draft.isEmpty {
                recoveredChatDraft = draft
                notice = "The chat was removed. Your unsent text is saved."
            }
            chatDrafts[id] = nil
        case .runNote(let id, let note):
            guard let run = tile(id)?.run, run.ownerID == localID, note.fromID != localID else { return }
            notice = "\(note.from) about “\(run.title)”: \(note.text)"
        case .runRequest(let id, let request):
            guard let run = tile(id)?.run, run.ownerID == localID, request.fromID != localID else { return }
            inbox.expectFiles(of: request, in: id)
            let files = request.files.isEmpty ? "" : " with \(request.files.count) file\(request.files.count == 1 ? "" : "s")"
            notice = "\(request.from) wants to continue “\(run.title)”\(files). Run or dismiss it on the tile."
        case .runRequestStatus(let id, let requestID, let status):
            guard let run = tile(id)?.run, run.ownerID != localID,
                  run.requests.first(where: { $0.id == requestID })?.fromID == localID else { return }
            notice = status == .accepted
                ? "\(run.ownerName) ran your follow-up on “\(run.title)”."
                : "\(run.ownerName) dismissed your follow-up on “\(run.title)”."
        default:
            break
        }
    }
}

// MARK: - File kinds

extension RoomFile.Kind {
    private static let documents: Set<String> = ["doc", "docx", "rtf", "odt", "xlsx", "xls", "ppt", "pptx", "iif"]

    static func of(_ url: URL) -> RoomFile.Kind {
        let ext = url.pathExtension.lowercased()
        if documents.contains(ext) { return .document }
        if Attachments.isImage(url) { return .image }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .yaml) || type.conforms(to: .propertyList) { return .text }
        return .other
    }
}

extension RoomFile {
    /// A small JPEG for the file strip, or nil when it can't be made small enough.
    static func thumbnail(_ url: URL) -> Data? {
        for (pixels, quality) in [(CGFloat(192), CGFloat(0.6)), (128, 0.5), (96, 0.4)] {
            if let data = Attachments.jpegData(url, maxPixels: pixels, quality: quality), data.count <= RoomLimits.maxThumbnailBytes {
                return data
            }
        }
        return nil
    }
}
