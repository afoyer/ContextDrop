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
        switch message {
        case .hello, .snapshot, .memberLeft, .ended:
            return nil

        case .addTile(var tile):
            guard room.tiles.count < RoomLimits.maxTiles, room.index(of: tile.id) == nil else { return nil }
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
            }
            room.tiles.append(tile)
            return .addTile(tile)

        case .moveTile(let id, let x, let y, let stamp):
            // Last write wins.
            guard let i = room.index(of: id), stamp > room.tiles[i].movedAt else { return nil }
            room.tiles[i].x = x
            room.tiles[i].y = y
            room.tiles[i].movedAt = stamp
            return message

        case .editTile(let id, let text, let stamp):
            guard let i = room.index(of: id), case .card(var body) = room.tiles[i].content,
                  stamp > room.tiles[i].updatedAt else { return nil }
            if let sender, room.tiles[i].addedBy != sender { return nil }
            body.text = text
            room.tiles[i].content = .card(body)
            room.tiles[i].updatedAt = stamp
            return message

        case .removeTile(let id):
            guard let i = room.index(of: id) else { return nil }
            let tile = room.tiles[i]
            if let sender, tile.addedBy != sender, tile.ownerName != sender, room.hostName != sender { return nil }
            room.tiles.remove(at: i)
            return message

        case .setCollapsed(let id, let collapsed, let stamp):
            guard let i = room.index(of: id), stamp > room.tiles[i].updatedAt else { return nil }
            room.tiles[i].collapsed = collapsed
            room.tiles[i].updatedAt = stamp
            return message

        case .chatMessage(let id, var chat):
            guard let i = room.index(of: id), let tile = room.tiles[i].chat,
                  !tile.messages.contains(where: { $0.id == chat.id }) else { return nil }
            if let sender {
                if sender == tile.ownerName {
                    // The owner's Mac speaks for the model, and for itself.
                    switch chat.kind {
                    case .user: chat.author = sender
                    case .assistant: chat.author = RoomChatMessage.assistantAuthor
                    case .event: break
                    }
                } else {
                    guard chat.kind == .user else { return nil }
                    chat.author = sender
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
            if let sender, sender != tile.ownerName { return nil }
            room.updateChat(at: i) { tile in
                tile.messages[j].text = reply.text
                tile.messages[j].streaming = reply.streaming
                tile.messages[j].sawFiles = reply.sawFiles
                tile.messages[j].sawRuns = reply.sawRuns
                tile.messages[j].failed = reply.failed
            }
            return message

        case .addFile(let id, var file):
            guard let i = room.index(of: id), let tile = room.tiles[i].chat,
                  tile.files.count < RoomLimits.maxFilesPerChat, !tile.files.contains(where: { $0.id == file.id }) else { return nil }
            if let sender {
                file.addedBy = sender
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
            guard let i = room.index(of: id), let tile = room.tiles[i].chat,
                  let j = tile.files.firstIndex(where: { $0.id == fileID }) else { return nil }
            if let sender, sender != tile.ownerName { return nil }
            room.updateChat(at: i) { $0.files[j].status = status }
            return message

        case .removeFile(let id, let fileID, let eventID, let stamped):
            guard let i = room.index(of: id), let tile = room.tiles[i].chat,
                  let file = tile.files.first(where: { $0.id == fileID }) else { return nil }
            if let sender, sender != file.addedBy, sender != tile.ownerName { return nil }
            let by = sender ?? stamped
            room.updateChat(at: i) { tile in
                tile.files.removeAll { $0.id == fileID }
                tile.appendEvent(eventID, eventLine(by, "removed \(file.name)"))
            }
            return .removeFile(id, fileID: fileID, messageID: eventID, by: by)

        case .requestFiles(let source, let target):
            // Nothing changes here; the owner of the source chat acts on it (see `RoomStore.afterApply`).
            guard let s = room.index(of: source), room.tiles[s].chat != nil,
                  let t = room.index(of: target), let chat = room.tiles[t].chat else { return nil }
            if let sender, sender != chat.ownerName { return nil }
            return message

        case .attachRun(let runID, let chatID, let eventID, let stamped):
            guard let i = room.index(of: chatID), let r = room.index(of: runID), let run = room.tiles[r].run,
                  let tile = room.tiles[i].chat, !tile.runIDs.contains(runID),
                  tile.runIDs.count < RoomLimits.maxRunsPerChat else { return nil }
            let by = sender ?? stamped
            room.updateChat(at: i) { tile in
                tile.runIDs.append(runID)
                tile.appendEvent(eventID, eventLine(by, "added \(run.ownerName)’s run “\(run.title)”"))
            }
            return .attachRun(runID, to: chatID, messageID: eventID, by: by)

        case .runUpdate(let id, var run):
            guard let i = room.index(of: id), let current = room.tiles[i].run else { return nil }
            if let sender, sender != current.ownerName { return nil }
            // Who owns it and the notes people left belong to the room, not to the update.
            run.ownerName = current.ownerName
            run.notes = current.notes
            room.tiles[i].content = .run(run)
            return .runUpdate(id, run)

        case .runNote(let id, var note):
            guard let i = room.index(of: id), case .run(var run) = room.tiles[i].content,
                  !run.notes.contains(where: { $0.id == note.id }) else { return nil }
            if let sender { note.from = sender }
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

extension RoomState {
    func index(of tileID: UUID) -> Int? { tiles.firstIndex { $0.id == tileID } }

    fileprivate mutating func updateChat(at i: Int, _ body: (inout RoomChatTile) -> Void) {
        guard case .chat(var chat) = tiles[i].content else { return }
        body(&chat)
        tiles[i].content = .chat(chat)
    }

    /// Someone left: their runs can't report any more and their chats stop mid-answer.
    mutating func memberGone(_ name: String) {
        for i in tiles.indices {
            switch tiles[i].content {
            case .run(var run) where run.ownerName == name && run.isLive:
                run.state = .waiting("\(name) left the room, so this run is no longer reporting.")
                tiles[i].content = .run(run)
            case .chat(var chat) where chat.ownerName == name && chat.isStreaming:
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
