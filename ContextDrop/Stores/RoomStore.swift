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

    @ObservationIgnored let peers: PeerService
    @ObservationIgnored private let service: RoomService
    @ObservationIgnored private(set) lazy var engine = RoomChatEngine(store: self)
    @ObservationIgnored private(set) lazy var runs = RoomRunBroadcaster(store: self)
    @ObservationIgnored private var joiningRoomID: UUID?
    @ObservationIgnored private var pendingMoves: [UUID: RoomMessage] = [:]
    @ObservationIgnored private var lastMoveSent: [UUID: Date] = [:]
    @ObservationIgnored private var moveFlush: Task<Void, Never>?

    private static let moveInterval: TimeInterval = 1.0 / 15
    private static let maxWatchLines = 400
    static let untitledChat = "New chat"

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
    var localName: String { peers.localDisplayName }

    /// Nearby people who are not at the table yet.
    var invitablePeers: [NearbyPeer] {
        let here = Set(members.map(\.id))
        return peers.nearbyPeers.filter { !here.contains($0.name) }
    }

    func isInvited(_ peer: NearbyPeer) -> Bool { service.invitedPeers.contains(peer.peerID) }
    func isPresent(_ name: String) -> Bool { members.contains { $0.id == name } }

    func tile(_ id: UUID) -> RoomTile? { room?.tiles.first { $0.id == id } }
    func canEdit(_ tile: RoomTile) -> Bool { isActive && tile.card != nil && tile.addedBy == localName }
    func canRemove(_ tile: RoomTile) -> Bool {
        isActive && (tile.addedBy == localName || tile.ownerName == localName || isHost)
    }
    func canRemove(_ file: RoomFile, in tile: RoomTile) -> Bool {
        isActive && (file.addedBy == localName || tile.ownerName == localName)
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
                         hostName: localName,
                         members: [RoomMember(id: localName, name: localName, isHost: true)],
                         tiles: [])
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
            for tile in tiles where tile.card != nil && tile.addedBy == localName { removeTile(tile.id) }
        }
        flushMoves()
        service.send(isHost ? .ended : .memberLeft(localName))
        service.close(afterFlush: true)
        if keepForTakeHome, room?.tiles.isEmpty == false {
            stopWork()
            settleStreams()
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
        moveFlush?.cancel()
        moveFlush = nil
        pendingMoves = [:]
        lastMoveSent = [:]
    }

    /// Nothing streams into a room that is over.
    private func settleStreams() {
        for i in room?.tiles.indices ?? 0..<0 {
            guard case .chat(var chat) = room?.tiles[i].content, chat.isStreaming else { continue }
            chat.stopStreaming()
            room?.tiles[i].content = .chat(chat)
        }
    }

    private func reset() {
        stopWork()
        runLogs = [:]
        chatDrafts = [:]
        room = nil
        isHost = false
        ended = false
        isJoining = false
        joiningRoomID = nil
    }

    private func markEnded(_ message: String) {
        stopWork()
        service.close()
        isJoining = false
        joiningRoomID = nil
        if room != nil {
            settleStreams()
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
    func post(_ message: RoomMessage) -> Bool {
        guard isActive else { return false }
        var message = message
        guard apply(&message, sender: localName) else { return false }
        service.send(message)
        afterApply(message)
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
        let now = Date()
        return RoomTile(id: UUID(), x: spot.x, y: spot.y, addedBy: localName, movedAt: now, updatedAt: now, content: content).sanitized()
    }

    /// Puts a card on the canvas for everyone. A nil point means a free spot in the middle of the view.
    @discardableResult
    func addCard(kind: RoomCardBody.Kind, text: String, caption: String? = nil, at point: CGPoint? = nil) -> UUID? {
        let body = RoomCardBody(kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), caption: caption)
        guard let tile = makeTile(.card(body), at: point, width: RoomMetrics.cardWidth), post(.addTile(tile)) else { return nil }
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
        let x = RoomLimits.clampCoordinate(point.x), y = RoomLimits.clampCoordinate(point.y)
        guard tile.x != x || tile.y != y else { return }
        let now = Date()
        var message = RoomMessage.moveTile(id, x: x, y: y, stamp: Self.stamp(after: tile.movedAt))
        guard apply(&message, sender: localName) else { return }
        if now.timeIntervalSince(lastMoveSent[id] ?? .distantPast) >= Self.moveInterval {
            lastMoveSent[id] = now
            pendingMoves[id] = nil
            service.send(message)
        } else {
            pendingMoves[id] = message
            scheduleMoveFlush()
        }
    }

    /// Always later than what we have seen, so a local change wins even when another Mac's clock runs ahead.
    private static func stamp(after previous: Date) -> Date { max(Date(), previous.addingTimeInterval(0.001)) }

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
        for (id, message) in pendingMoves {
            lastMoveSent[id] = now
            service.send(message)
        }
        pendingMoves = [:]
    }

    /// Changes the text of one of your own cards.
    func editCard(_ id: UUID, text: String) {
        guard let tile = tile(id), canEdit(tile) else { return }
        post(.editTile(id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), stamp: Self.stamp(after: tile.updatedAt)))
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
        post(.setCollapsed(id, collapsed, stamp: Self.stamp(after: tile.updatedAt)))
    }

    // MARK: Chat tiles

    /// A new chat tile owned by this Mac. Returns nil when the canvas is full.
    @discardableResult
    func addChatTile(title: String, messages: [RoomChatMessage] = [], files: [RoomFile] = [], runIDs: [UUID] = [],
                     spawnedFrom: [UUID] = [], spawnedLabels: [String] = [], at point: CGPoint? = nil) -> UUID? {
        let chat = RoomChatTile(title: title, ownerName: localName, model: OpenAISettings.model, messages: messages,
                                files: files, runIDs: runIDs, spawnedFrom: spawnedFrom, spawnedLabels: spawnedLabels)
        guard let tile = makeTile(.chat(chat), at: point, width: RoomMetrics.chatWidth), post(.addTile(tile)) else { return nil }
        return tile.id
    }

    /// Anyone in the room can reply in any chat tile. The answer comes from the tile owner's Mac.
    func sendChat(_ text: String, in tileID: UUID) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RoomLimits.maxQuestionLength))
        guard isActive, !trimmed.isEmpty, let chat = tile(tileID)?.chat else { return }
        guard isPresent(chat.ownerName) else {
            notice = "\(chat.ownerName) left the room, so this chat can’t answer any more. Select it and start a new chat from it."
            return
        }
        post(.chatMessage(tileID, RoomChatMessage(id: UUID(), kind: .user, author: localName, text: trimmed)))
    }

    /// "Ask the room" and "New chat from selection": a new chat tile on this Mac, started from the selected
    /// tiles (a summary of each selected chat, all of their files, and the selected cards).
    @discardableResult
    func spawnChat(question: String, selected: Set<UUID>) -> UUID? {
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RoomLimits.maxQuestionLength))
        guard isActive else { return nil }
        let sources = tiles.filter { selected.contains($0.id) }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .prefix(RoomLimits.maxSpawnSources)

        // Beside the selection; otherwise in the middle of the view.
        var spot: CGPoint?
        if let right = sources.map({ $0.x + RoomMetrics.width(for: $0) }).max(), let top = sources.map(\.y).min() {
            spot = freeSpot(near: CGPoint(x: right + 70, y: top))
        }

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

        let title = question.isEmpty ? Self.untitledChat : ChatStore.title(from: question)
        var messages: [RoomChatMessage] = []
        if !question.isEmpty { messages.append(RoomChatMessage(id: UUID(), kind: .user, author: localName, text: question)) }
        guard let id = addChatTile(title: title, messages: messages, files: files,
                                   runIDs: runIDs.filter { seenRuns.insert($0).inserted },
                                   spawnedFrom: sources.map(\.id), spawnedLabels: sources.map(\.shortLabel), at: spot) else { return nil }
        for source in askOwners { post(.requestFiles(from: source, to: id)) }
        engine.begin(id, from: Array(sources), ask: !question.isEmpty)
        return id
    }

    // MARK: Files (always inside a chat tile)

    func addFiles(_ urls: [URL], to tileID: UUID) {
        for url in urls.prefix(8) { addFile(url, to: tileID) }
    }

    /// Adds a file to anyone's chat tile. The bytes go to the chat owner's Mac once; everyone else sees its name.
    func addFile(_ url: URL, to tileID: UUID, name: String? = nil) {
        guard isActive, let chat = tile(tileID)?.chat else { return }
        let name = name ?? url.lastPathComponent
        guard isPresent(chat.ownerName) else {
            notice = "\(chat.ownerName) left the room, so this chat can’t take new files."
            return
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values?.isDirectory != true, let size = values?.fileSize else {
            notice = "“\(name)” isn’t a file that can be added. Folders can’t go in a chat."
            return
        }
        guard size <= RoomLimits.maxFileBytes else {
            notice = "“\(name)” is larger than 20 MB, so it wasn’t added."
            return
        }
        guard chat.files.count < RoomLimits.maxFilesPerChat else {
            notice = "This chat already holds \(RoomLimits.maxFilesPerChat) files. Remove one to add another."
            return
        }
        // Copy now: sending is asynchronous and the original may move.
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxdrop-room-\(UUID().uuidString)").appendingPathExtension(url.pathExtension)
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else {
            notice = "“\(name)” couldn’t be read."
            return
        }
        let kind = RoomFile.Kind.of(url)
        let file = RoomFile(id: UUID(), name: name, kind: kind, size: size, addedBy: localName,
                            thumbnail: kind == .image ? RoomFile.thumbnail(url) : nil, status: .sending)
        guard post(.addFile(tileID, file)) else {
            try? FileManager.default.removeItem(at: copy)
            return
        }
        if chat.ownerName == localName {
            engine.ingest(copy, tileID: tileID, fileID: file.id)
        } else {
            let owner = chat.ownerName
            service.sendFile(copy, name: Self.resourceName(tileID, file.id), toMember: owner) { [weak self] sent in
                try? FileManager.default.removeItem(at: copy)
                guard let self, !sent else { return }
                self.removeFile(file.id, from: tileID)
                self.notice = "“\(name)” couldn’t be sent to \(owner)’s Mac."
            }
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
        guard isActive, let chat = tile(tileID)?.chat, chat.ownerName != localName else { return }
        service.sendFile(url, name: Self.resourceName(tileID, fileID), toMember: chat.ownerName) { _ in }
    }

    /// File bytes arrived: for a chat this Mac owns, or (on the host) to pass on to the chat's owner.
    private func fileArrived(_ url: URL, name: String) {
        let parts = name.split(separator: "|")
        guard isActive, parts.count == 2, let tileID = UUID(uuidString: String(parts[0])), let fileID = UUID(uuidString: String(parts[1])),
              let chat = tile(tileID)?.chat, let file = chat.files.first(where: { $0.id == fileID }), file.status == .sending else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if chat.ownerName == localName {
            engine.ingest(url, tileID: tileID, fileID: fileID)
        } else if isHost {
            service.sendFile(url, name: name, toMember: chat.ownerName) { _ in try? FileManager.default.removeItem(at: url) }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Claude Code runs

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

    /// Puts one of this Mac's Claude Code chats in the room as a live, watch-only tile.
    @discardableResult
    func shareRun(_ conversation: Conversation) -> UUID? {
        guard isActive else { return nil }
        if let existing = runs.tileID(for: conversation.id), tile(existing) != nil { return existing }
        guard let snapshot = runs.snapshot(of: conversation.id),
              let tile = makeTile(.run(snapshot), at: nil, width: RoomMetrics.runWidth), post(.addTile(tile)) else { return nil }
        runs.track(conversation.id, as: tile.id)
        return tile.id
    }

    /// Puts one of this Mac's OpenAI chats in the room as a chat tile: its text, and its images as files.
    @discardableResult
    func shareChat(_ conversation: Conversation) -> UUID? {
        guard isActive else { return nil }
        let messages = conversation.messages.filter { $0.error == nil && !$0.text.isEmpty }.suffix(60).map { message in
            RoomChatMessage(id: UUID(), kind: message.role == .user ? .user : .assistant,
                            author: message.role == .user ? localName : "OpenAI", text: message.text, createdAt: message.createdAt)
        }
        guard let id = addChatTile(title: conversation.title, messages: Array(messages)) else { return nil }
        for attachment in conversation.allAttachments.filter(\.isImage).prefix(RoomLimits.maxFilesPerChat) {
            addFile(attachment.url, to: id, name: attachment.name)
        }
        return id
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

    /// Host: drops someone from the faces (their tiles stay) and tells everyone else.
    private func removeMember(_ id: String, relayExcept: MCPeerID?) {
        guard let index = room?.members.firstIndex(where: { $0.id == id && !$0.isHost }) else { return }
        room?.members.remove(at: index)
        memberGone(id)
        service.send(.memberLeft(id), except: relayExcept)
        onChange?()
    }

    /// Someone left: their runs can't report any more and their chats stop mid-answer.
    private func memberGone(_ name: String) {
        for i in room?.tiles.indices ?? 0..<0 {
            switch room?.tiles[i].content {
            case .run(var run) where run.ownerName == name && run.isLive:
                run.state = .waiting("\(name) left the room, so this run is no longer reporting.")
                room?.tiles[i].content = .run(run)
            case .chat(var chat) where chat.ownerName == name && chat.isStreaming:
                chat.stopStreaming()
                room?.tiles[i].content = .chat(chat)
            default:
                break
            }
        }
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
        case .memberLeft:
            removeMember(sender, relayExcept: peerID)
        case .hello, .snapshot, .ended:
            break // only the host sends these
        default:
            var message = message
            guard apply(&message, sender: sender) else { return }
            service.send(message, except: peerID)
            afterApply(message)
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
        case .memberLeft:
            guard let id = message.memberID, id != localName else { return }
            self.room?.members.removeAll { $0.id == id && !$0.isHost }
            memberGone(id)
            onChange?()
        case .ended:
            markEnded("\(room.hostName) ended the room.")
        case .snapshot:
            break
        default:
            // The host already checked it and stamped who it came from.
            var message = message
            if apply(&message, sender: nil) { afterApply(message) }
        }
    }

    // MARK: Applying a change

    private func index(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        return room?.tiles.firstIndex { $0.id == id }
    }

    private func updateChat(at i: Int, _ body: (inout RoomChatTile) -> Bool) -> Bool {
        guard case .chat(var chat) = room?.tiles[i].content, body(&chat) else { return false }
        room?.tiles[i].content = .chat(chat)
        return true
    }

    /// "Camille removed notes.pdf": built the same way on every Mac from who did it, never sent as text.
    private static func eventLine(_ message: RoomMessage, _ what: String) -> String {
        "\(message.from ?? "Someone") \(what)"
    }

    private static func append(_ message: RoomChatMessage, to chat: inout RoomChatTile) {
        chat.messages.append(message)
        if chat.messages.count > RoomLimits.maxChatMessages {
            chat.messages.removeFirst(chat.messages.count - RoomLimits.maxChatMessages)
        }
    }

    /// Applies one change to the local state. `sender` is who it came from (this Mac for local changes, the
    /// peer's name on the host); the rules are checked against it and authorship is stamped into `message`
    /// before it is relayed. `sender == nil` means the host already did both.
    /// Returns false when the change was refused or is stale.
    private func apply(_ message: inout RoomMessage, sender: String?) -> Bool {
        guard let room else { return false }
        if let sender { message.from = sender }
        switch message.kind {
        case .hello, .snapshot, .memberLeft, .ended:
            return false

        case .addTile:
            guard var tile = message.tile, room.tiles.count < RoomLimits.maxTiles,
                  !room.tiles.contains(where: { $0.id == tile.id }) else { return false }
            if let sender {
                // You can only add tiles that are yours: your card, a chat or a run on your own Mac.
                tile.addedBy = sender
                switch tile.content {
                case .card:
                    break
                case .chat(var chat):
                    chat.ownerName = sender
                    for i in chat.messages.indices where chat.messages[i].kind == .user { chat.messages[i].author = sender }
                    chat.stopStreaming()
                    tile.content = .chat(chat)
                case .run(var run):
                    run.ownerName = sender
                    run.notes = []
                    tile.content = .run(run)
                }
                message.tile = tile
            }
            self.room?.tiles.append(tile)
            if let run = tile.run { mergeLog(run.log, into: tile.id) }
            return true

        case .moveTile:
            // Last write wins.
            guard let i = index(message.tileID), let x = message.x, let y = message.y, let stamp = message.stamp,
                  stamp > room.tiles[i].movedAt else { return false }
            var moved = room.tiles[i]
            moved.x = x
            moved.y = y
            moved.movedAt = stamp
            self.room?.tiles[i] = moved
            return true

        case .editTile:
            guard let i = index(message.tileID), let text = message.text, let stamp = message.stamp,
                  case .card(var body) = room.tiles[i].content, stamp > room.tiles[i].updatedAt else { return false }
            if let sender, room.tiles[i].addedBy != sender { return false }
            body.text = text
            self.room?.tiles[i].content = .card(body)
            self.room?.tiles[i].updatedAt = stamp
            return true

        case .removeTile:
            guard let i = index(message.tileID) else { return false }
            let tile = room.tiles[i]
            if let sender, tile.addedBy != sender, tile.ownerName != sender, room.hostName != sender { return false }
            self.room?.tiles.remove(at: i)
            return true

        case .setCollapsed:
            guard let i = index(message.tileID), let collapsed = message.flag, let stamp = message.stamp,
                  stamp > room.tiles[i].updatedAt else { return false }
            self.room?.tiles[i].collapsed = collapsed
            self.room?.tiles[i].updatedAt = stamp
            return true

        case .chatMessage:
            guard let i = index(message.tileID), var chat = message.chat, let tile = room.tiles[i].chat,
                  !tile.messages.contains(where: { $0.id == chat.id }) else { return false }
            if let sender {
                if sender == tile.ownerName {
                    // The owner's Mac speaks for the model, and for itself.
                    switch chat.kind {
                    case .user: chat.author = sender
                    case .assistant: chat.author = "OpenAI"
                    case .event: break
                    }
                } else {
                    guard chat.kind == .user else { return false }
                    chat.author = sender
                    chat.streaming = false
                    chat.failed = false
                    chat.sawFiles = []
                    chat.sawRuns = false
                }
                message.chat = chat
            }
            return updateChat(at: i) { tile in
                if chat.kind == .user, tile.title == Self.untitledChat { tile.title = ChatStore.title(from: chat.text) }
                Self.append(chat, to: &tile)
                return true
            }

        case .chatDelta:
            guard let i = index(message.tileID), let reply = message.chat, let tile = room.tiles[i].chat else { return false }
            if let sender, sender != tile.ownerName { return false }
            return updateChat(at: i) { tile in
                guard let j = tile.messages.firstIndex(where: { $0.id == reply.id && $0.kind == .assistant }) else { return false }
                tile.messages[j].text = reply.text
                tile.messages[j].streaming = reply.streaming
                tile.messages[j].sawFiles = reply.sawFiles
                tile.messages[j].sawRuns = reply.sawRuns
                tile.messages[j].failed = reply.failed
                return true
            }

        case .addFile:
            guard let i = index(message.tileID), var file = message.file, let tile = room.tiles[i].chat,
                  tile.files.count < RoomLimits.maxFilesPerChat, !tile.files.contains(where: { $0.id == file.id }) else { return false }
            if let sender {
                file.addedBy = sender
                // Only the owner's Mac can say a file is ready.
                file.status = .sending
                message.file = file
            }
            return updateChat(at: i) { tile in
                tile.files.append(file)
                Self.append(RoomChatMessage(id: file.id, kind: .event, author: file.addedBy, text: "\(file.addedBy) added \(file.name)"), to: &tile)
                return true
            }

        case .fileStatus:
            guard let i = index(message.tileID), let fileID = message.fileID, let status = message.fileStatus,
                  let tile = room.tiles[i].chat else { return false }
            if let sender, sender != tile.ownerName { return false }
            return updateChat(at: i) { tile in
                guard let j = tile.files.firstIndex(where: { $0.id == fileID }) else { return false }
                tile.files[j].status = status
                return true
            }

        case .removeFile:
            guard let i = index(message.tileID), let fileID = message.fileID, let eventID = message.messageID,
                  let tile = room.tiles[i].chat, let file = tile.files.first(where: { $0.id == fileID }) else { return false }
            if let sender, sender != file.addedBy, sender != tile.ownerName { return false }
            let line = Self.eventLine(message, "removed \(file.name)")
            return updateChat(at: i) { tile in
                tile.files.removeAll { $0.id == fileID }
                if !tile.messages.contains(where: { $0.id == eventID }) {
                    Self.append(RoomChatMessage(id: eventID, kind: .event, author: "", text: line), to: &tile)
                }
                return true
            }

        case .requestFiles:
            // Nothing changes here; the owner of the source chat acts on it (see `afterApply`).
            guard let source = index(message.tileID), room.tiles[source].chat != nil,
                  let target = index(message.targetTileID), let chat = room.tiles[target].chat else { return false }
            if let sender, sender != chat.ownerName { return false }
            return true

        case .attachRun:
            guard let i = index(message.tileID), let runID = message.runID, let run = tile(runID)?.run,
                  let tile = room.tiles[i].chat, !tile.runIDs.contains(runID), tile.runIDs.count < RoomLimits.maxRunsPerChat else { return false }
            let line = Self.eventLine(message, "added \(run.ownerName)’s run “\(run.title)”")
            return updateChat(at: i) { tile in
                tile.runIDs.append(runID)
                if let eventID = message.messageID, !tile.messages.contains(where: { $0.id == eventID }) {
                    Self.append(RoomChatMessage(id: eventID, kind: .event, author: "", text: line), to: &tile)
                }
                return true
            }

        case .runUpdate:
            guard let i = index(message.tileID), var run = message.run, let current = room.tiles[i].run else { return false }
            if let sender, sender != current.ownerName { return false }
            // Who owns it and the notes people left belong to the room, not to the update.
            run.ownerName = current.ownerName
            run.notes = current.notes
            message.run = run
            self.room?.tiles[i].content = .run(run)
            mergeLog(run.log, into: room.tiles[i].id)
            return true

        case .runNote:
            guard let i = index(message.tileID), var note = message.note, case .run(var run) = room.tiles[i].content,
                  !run.notes.contains(where: { $0.id == note.id }) else { return false }
            if let sender {
                note.from = sender
                message.note = note
            }
            run.notes.append(note)
            if run.notes.count > RoomLimits.maxRunNotes { run.notes.removeFirst(run.notes.count - RoomLimits.maxRunNotes) }
            self.room?.tiles[i].content = .run(run)
            return true
        }
    }

    private func mergeLog(_ lines: [RunLogLine], into tileID: UUID) {
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
        switch message.kind {
        case .chatMessage:
            guard let id = message.tileID, message.chat?.kind == .user, tile(id)?.chat?.ownerName == localName else { return }
            engine.userMessageArrived(id)
        case .addFile:
            guard let id = message.tileID, let file = message.file, tile(id)?.chat?.ownerName == localName,
                  file.addedBy != localName else { return }
            engine.expectFile(file.id, in: id)
        case .removeFile:
            if let fileID = message.fileID { engine.forgetFile(fileID) }
        case .requestFiles:
            guard let source = message.tileID, let target = message.targetTileID,
                  tile(source)?.chat?.ownerName == localName else { return }
            engine.sendFiles(from: source, to: target)
        case .removeTile:
            guard let id = message.tileID else { return }
            engine.tileRemoved(id)
            runs.tileRemoved(id)
            runLogs[id] = nil
            chatDrafts[id] = nil
        case .runNote:
            guard let id = message.tileID, let note = message.note, let run = tile(id)?.run,
                  run.ownerName == localName, note.from != localName else { return }
            notice = "\(note.from) about “\(run.title)”: \(note.text)"
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
