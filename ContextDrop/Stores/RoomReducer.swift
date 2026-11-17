import Foundation

/// The room's rules: what one change does to the table, and who may make it.
/// Pure, so it can be tested without two Macs. `RoomStore` owns the state and the network around it.
enum RoomReducer {
    /// The title of a chat tile until its first question names it.
    static let untitledChat = "New chat"

    /// Applies one change. `sender` is who it came from (this Mac for local changes, the peer's name on the host):
    /// the rules are checked against it and authorship is stamped into the message that comes back, which is the
    /// one to relay. `sender == nil` means the host already did both.
    /// Returns nil when the change was refused or is stale; the room is then untouched.
    static func apply(_ message: RoomMessage, to room: inout RoomState, sender: String?) -> RoomMessage? {
        let senderName = sender.flatMap { id in room.members.first { $0.id == id }?.name } ?? sender
        func owner(_ id: String, _ name: String) -> String { id.isEmpty ? name : id }
        switch message {
        case .submit, .accepted, .rejected, .hello, .snapshot, .memberLeft, .ended:
            return nil

        case .addTile(var tile):
            guard room.tiles.count < RoomLimits.maxTiles, room.index(of: tile.id) == nil else { return nil }
            if let sender {
                // You can only add tiles that are yours: your card, a chat or a run on your own Mac.
                tile.addedBy = senderName ?? sender
                tile.addedByID = sender
                switch tile.content {
                case .card:
                    break
                case .chat(var chat):
                    chat.ownerName = senderName ?? sender
                    chat.ownerID = sender
                    for i in chat.messages.indices where chat.messages[i].kind == .user { chat.messages[i].author = senderName ?? sender }
                    chat.stopStreaming()
                    tile.content = .chat(chat)
                case .run(var run):
                    run.ownerName = senderName ?? sender
                    run.ownerID = sender
                    run.notes = []
                    run.requests = []
                    tile.content = .run(run)
                }
            }
            room.tiles.append(tile)
            return .addTile(tile)

        case .moveTile(let id, let x, let y):
            guard let i = room.index(of: id) else { return nil }
            room.tiles[i].x = x
            room.tiles[i].y = y
            return message

        case .editTile(let id, let text):
            guard let i = room.index(of: id), case .card(var body) = room.tiles[i].content else { return nil }
            if let sender, owner(room.tiles[i].addedByID, room.tiles[i].addedBy) != sender { return nil }
            body.text = text
            room.tiles[i].content = .card(body)
            return message

        case .removeTile(let id):
            guard let i = room.index(of: id) else { return nil }
            let tile = room.tiles[i]
            if let sender, owner(tile.addedByID, tile.addedBy) != sender,
               owner(tile.ownerID, tile.ownerName) != sender,
               owner(room.hostID, room.hostName) != sender { return nil }
            room.tiles.remove(at: i)
            return message

        case .setCollapsed(let id, let collapsed):
            guard let i = room.index(of: id) else { return nil }
            room.tiles[i].collapsed = collapsed
            return message

        case .chatMessage(let id, var chat):
            guard let i = room.index(of: id), let tile = room.tiles[i].chat,
                  !tile.messages.contains(where: { $0.id == chat.id }) else { return nil }
            if let sender {
                if sender == owner(tile.ownerID, tile.ownerName) {
                    // The owner's Mac speaks for the model, and for itself.
                    switch chat.kind {
                    case .user: chat.author = senderName ?? sender
                    case .assistant: chat.author = RoomChatMessage.assistantAuthor
                    case .event: break
                    }
                } else {
                    guard chat.kind == .user else { return nil }
                    chat.author = senderName ?? sender
                    chat.streaming = false
                    chat.failed = false
                    chat.sawFiles = []
                    chat.sawRuns = false
                }
            }
            let added = chat
            room.updateChat(at: i) { tile in
                if added.kind == .user, tile.title == untitledChat { tile.title = Conversation.title(from: added.text) }
                tile.append(added)
            }
            return .chatMessage(id, chat)

        case .chatDelta(let id, let reply):
            guard let i = room.index(of: id), let tile = room.tiles[i].chat,
                  let j = tile.messages.firstIndex(where: { $0.id == reply.id && $0.kind == .assistant }) else { return nil }
            if let sender, sender != owner(tile.ownerID, tile.ownerName) { return nil }
            room.updateChat(at: i) { tile in
                tile.messages[j].text = reply.text
                tile.messages[j].streaming = reply.streaming
                tile.messages[j].sawFiles = reply.sawFiles
                tile.messages[j].sawRuns = reply.sawRuns
                tile.messages[j].failed = reply.failed
                tile.messages[j].failureReason = reply.failureReason
            }
            return message

        case .addFile(let id, var file):
            guard let i = room.index(of: id), let tile = room.tiles[i].chat,
                  tile.files.count < RoomLimits.maxFilesPerChat, !tile.files.contains(where: { $0.id == file.id }) else { return nil }
            if let sender {
                file.addedBy = senderName ?? sender
                file.addedByID = sender
                // Only the owner's Mac can say a file is ready.
                file.status = .sending
            }
            let added = file
            room.updateChat(at: i) { tile in
                tile.files.append(added)
                tile.append(RoomChatMessage(id: added.id, kind: .event, author: added.addedBy, text: "\(added.addedBy) added \(added.name)"))
            }
            return .addFile(id, file)

        case .fileStatus(let id, let fileID, let status):
            guard let i = room.index(of: id) else { return nil }
            if let sender, sender != owner(room.tiles[i].ownerID, room.tiles[i].ownerName) { return nil }
            switch room.tiles[i].content {
            case .chat(let tile):
                guard let j = tile.files.firstIndex(where: { $0.id == fileID }) else { return nil }
                room.updateChat(at: i) { $0.files[j].status = status }
            case .run(var run):
                guard run.setFileStatus(fileID, status) else { return nil }
                room.tiles[i].content = .run(run)
            case .card:
                return nil
            }
            return message

        case .removeFile(let id, let fileID, let eventID, let stamped):
            guard let i = room.index(of: id), let tile = room.tiles[i].chat,
                  let file = tile.files.first(where: { $0.id == fileID }) else { return nil }
            if let sender, sender != owner(file.addedByID, file.addedBy), sender != owner(tile.ownerID, tile.ownerName) { return nil }
            let by = senderName ?? stamped
            room.updateChat(at: i) { tile in
                tile.files.removeAll { $0.id == fileID }
                tile.appendEvent(eventID, eventLine(by, "removed \(file.name)"))
            }
            return .removeFile(id, fileID: fileID, messageID: eventID, by: by)

        case .requestFiles(let source, let target):
            // Nothing changes here; the owner of the source chat acts on it (see `RoomStore.afterApply`).
            guard let s = room.index(of: source), room.tiles[s].chat != nil,
                  let t = room.index(of: target), let chat = room.tiles[t].chat else { return nil }
            if let sender, sender != owner(chat.ownerID, chat.ownerName) { return nil }
            return message

        case .attachRun(let runID, let chatID, let eventID, let stamped):
            guard let i = room.index(of: chatID), let r = room.index(of: runID), let run = room.tiles[r].run,
                  let tile = room.tiles[i].chat, !tile.runIDs.contains(runID),
                  tile.runIDs.count < RoomLimits.maxRunsPerChat else { return nil }
            let by = senderName ?? stamped
            room.updateChat(at: i) { tile in
                tile.runIDs.append(runID)
                tile.appendEvent(eventID, eventLine(by, "added \(run.ownerName)’s run “\(run.title)”"))
            }
            return .attachRun(runID, to: chatID, messageID: eventID, by: by)

        case .runUpdate(let id, var run):
            guard let i = room.index(of: id), let current = room.tiles[i].run else { return nil }
            if let sender, sender != owner(current.ownerID, current.ownerName) { return nil }
            // Who owns it, the notes people left and their follow-ups belong to the room, not to the update.
            run.ownerName = current.ownerName
            run.notes = current.notes
            run.requests = current.requests
            room.tiles[i].content = .run(run)
            return .runUpdate(id, run)

        case .runRequest(let id, var request):
            guard let i = room.index(of: id), case .run(var run) = room.tiles[i].content,
                  !run.requests.contains(where: { $0.id == request.id }) else { return nil }
            // A follow-up asks for something: some text, or at least a file.
            guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !request.files.isEmpty else { return nil }
            // File bytes are matched to follow-ups by file id, so an id may only ever name one file in the room:
            // otherwise someone could reuse another person's file id and have their bytes land in that follow-up.
            let fileIDs = Set(request.files.map(\.id))
            guard fileIDs.count == request.files.count,
                  !room.tiles.contains(where: { $0.run?.requests.contains { $0.files.contains { fileIDs.contains($0.id) } } == true })
            else { return nil }
            if let sender {
                request.from = senderName ?? sender
                request.fromID = sender
                for j in request.files.indices { request.files[j].addedBy = senderName ?? sender
                    request.files[j].addedByID = sender }
                if sender != owner(run.ownerID, run.ownerName) {
                    // One follow-up waiting per person, so nobody can crowd out the others'.
                    guard !run.requests.contains(where: { $0.fromID == sender && $0.status == .pending }) else { return nil }
                    // Only the owner's Mac decides what runs there, and says when a file has arrived.
                    request.status = .pending
                    for j in request.files.indices { request.files[j].status = .sending }
                } else if request.status == .dismissed {
                    return nil
                }
            }
            // Make room by dropping the oldest answered follow-ups. One still waiting on the owner never disappears:
            // when every kept follow-up is waiting, the new one is refused (`RoomStore.continueBlocker` says why).
            while run.requests.count >= RoomLimits.maxRunRequests {
                guard let k = run.requests.firstIndex(where: { $0.status != .pending }) else { return nil }
                run.requests.remove(at: k)
            }
            run.requests.append(request)
            room.tiles[i].content = .run(run)
            return .runRequest(id, request)

        case .runRequestStatus(let id, let requestID, let status):
            guard status != .pending, let i = room.index(of: id), case .run(var run) = room.tiles[i].content,
                  let j = run.requests.firstIndex(where: { $0.id == requestID }),
                  run.requests[j].status == .pending else { return nil }
            if let sender, sender != owner(run.ownerID, run.ownerName) { return nil }
            run.requests[j].status = status
            room.tiles[i].content = .run(run)
            return message

        case .runNote(let id, var note):
            guard let i = room.index(of: id), case .run(var run) = room.tiles[i].content,
                  !run.notes.contains(where: { $0.id == note.id }) else { return nil }
            if let sender { note.from = senderName ?? sender
                note.fromID = sender }
            run.notes.append(note)
            if run.notes.count > RoomLimits.maxRunNotes { run.notes.removeFirst(run.notes.count - RoomLimits.maxRunNotes) }
            room.tiles[i].content = .run(run)
            return .runNote(id, note)
        }
    }

    /// "Camille removed notes.pdf": built the same way on every Mac from who did it, never sent as text.
    private static func eventLine(_ by: String?, _ what: String) -> String {
        "\(by ?? "Someone") \(what)"
    }
}

extension RoomChatMessage {
    /// The author of every model reply in a room chat.
    static let assistantAuthor = "OpenAI"
}

extension RoomChatTile {
    mutating func append(_ message: RoomChatMessage) {
        messages.append(message)
        if messages.count > RoomLimits.maxChatMessages { messages.removeFirst(messages.count - RoomLimits.maxChatMessages) }
    }

    /// An event line with a known id, so the same line is not added twice.
    fileprivate mutating func appendEvent(_ id: UUID, _ text: String) {
        guard !messages.contains(where: { $0.id == id }) else { return }
        append(RoomChatMessage(id: id, kind: .event, author: "", text: text))
    }
}

extension RoomRunTile {
    /// Sets the status of a file in one of the follow-ups. False when no follow-up has it.
    fileprivate mutating func setFileStatus(_ fileID: UUID, _ status: RoomFile.Status) -> Bool {
        for r in requests.indices {
            guard let j = requests[r].files.firstIndex(where: { $0.id == fileID }) else { continue }
            requests[r].files[j].status = status
            return true
        }
        return false
    }
}

extension RoomState {
    func index(of tileID: UUID) -> Int? { tiles.firstIndex { $0.id == tileID } }

    fileprivate mutating func updateChat(at i: Int, _ body: (inout RoomChatTile) -> Void) {
        guard case .chat(var chat) = tiles[i].content else { return }
        body(&chat)
        tiles[i].content = .chat(chat)
    }

    /// Someone left: their runs can't report any more (or take follow-ups) and their chats stop mid-answer.
    mutating func memberGone(_ id: String) {
        for i in tiles.indices {
            switch tiles[i].content {
            case .run(var run) where run.ownerID == id:
                if run.isLive { run.state = .waiting("\(run.ownerName) left the room, so this run is no longer reporting.") }
                // Nobody is left to answer what was waiting on them.
                for j in run.requests.indices where run.requests[j].status == .pending { run.requests[j].status = .dismissed }
                tiles[i].content = .run(run)
            case .chat(var chat) where chat.ownerID == id && chat.isStreaming:
                chat.stopStreaming()
                tiles[i].content = .chat(chat)
            default:
                break
            }
        }
    }

    /// Nothing streams into a room that is over.
    mutating func settleStreams() {
        for i in tiles.indices {
            guard case .chat(var chat) = tiles[i].content, chat.isStreaming else { continue }
            chat.stopStreaming()
            tiles[i].content = .chat(chat)
        }
    }
}
