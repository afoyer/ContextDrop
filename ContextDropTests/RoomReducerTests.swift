import XCTest
@testable import ContextDrop

/// The room's rules: who may change what, and which of two changes wins.
final class RoomReducerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100)
    private var later: Date { t0.addingTimeInterval(10) }

    private func card(by name: String, text: String = "note") -> RoomTile {
        RoomTile(id: UUID(), x: 0, y: 0, addedBy: name, movedAt: t0, updatedAt: t0,
                 content: .card(RoomCardBody(kind: .thought, text: text, caption: nil)))
    }

    private func chat(ownedBy name: String, title: String = RoomReducer.untitledChat) -> RoomTile {
        RoomTile(id: UUID(), x: 0, y: 0, addedBy: name, movedAt: t0, updatedAt: t0,
                 content: .chat(RoomChatTile(title: title, ownerName: name, model: "gpt-4.1")))
    }

    private func run(ownedBy name: String) -> RoomTile {
        RoomTile(id: UUID(), x: 0, y: 0, addedBy: name, movedAt: t0, updatedAt: t0,
                 content: .run(RoomRunTile(ownerName: name, title: "Run", folder: "~/p")))
    }

    /// Alice hosts; Bob and Carol are guests.
    private func room(_ tiles: RoomTile...) -> RoomState {
        RoomState(id: UUID(), name: "Table", hostName: "Alice",
                  members: ["Alice", "Bob", "Carol"].map { RoomMember(id: $0, name: $0, isHost: $0 == "Alice") }, tiles: tiles)
    }

    private func message(_ kind: RoomChatMessage.Kind, by author: String, _ text: String = "hi") -> RoomChatMessage {
        RoomChatMessage(id: UUID(), kind: kind, author: author, text: text, createdAt: t0)
    }

    // MARK: Tiles

    func testMembershipMessagesAreNotChangesToTheTable() {
        var state = room()
        let before = state
        XCTAssertNil(RoomReducer.apply(.ended, to: &state, sender: "Bob"))
        XCTAssertNil(RoomReducer.apply(.memberLeft("Carol"), to: &state, sender: "Bob"))
        XCTAssertNil(RoomReducer.apply(.snapshot(room()), to: &state, sender: "Bob"))
        XCTAssertEqual(state, before)
    }

    func testAnAddedTileBelongsToWhoeverSentIt() {
        var state = room()
        var forged = chat(ownedBy: "Alice")
        forged.content = .chat(RoomChatTile(title: "t", ownerName: "Alice", model: "gpt-4.1", messages: [message(.user, by: "Alice")]))
        guard case .addTile(let stamped) = RoomReducer.apply(.addTile(forged), to: &state, sender: "Bob") else { return XCTFail("refused") }
        XCTAssertEqual(stamped.addedBy, "Bob")
        XCTAssertEqual(stamped.chat?.ownerName, "Bob")
        XCTAssertEqual(stamped.chat?.messages.first?.author, "Bob")
        XCTAssertEqual(state.tiles, [stamped])

        XCTAssertNil(RoomReducer.apply(.addTile(stamped), to: &state, sender: "Bob"), "the same tile twice")
    }

    func testTheHostsRelayIsTakenAsItIs() {
        var state = room()
        let tile = card(by: "Carol")
        XCTAssertEqual(RoomReducer.apply(.addTile(tile), to: &state, sender: nil), .addTile(tile))
        XCTAssertEqual(state.tiles.first?.addedBy, "Carol")
    }

    func testTheLaterMoveWins() {
        let tile = card(by: "Bob")
        var state = room(tile)
        XCTAssertNotNil(RoomReducer.apply(.moveTile(tile.id, x: 5, y: 6, stamp: later), to: &state, sender: "Carol"), "anyone may move a tile")
        XCTAssertNil(RoomReducer.apply(.moveTile(tile.id, x: 9, y: 9, stamp: t0.addingTimeInterval(1)), to: &state, sender: "Bob"), "an older move is stale")
        XCTAssertEqual(state.tiles[0].x, 5)
        XCTAssertEqual(state.tiles[0].movedAt, later)
    }

    func testOnlyTheAuthorEditsACard() {
        let tile = card(by: "Bob")
        var state = room(tile)
        XCTAssertNil(RoomReducer.apply(.editTile(tile.id, text: "mine now", stamp: later), to: &state, sender: "Carol"))
        XCTAssertNil(RoomReducer.apply(.editTile(tile.id, text: "host", stamp: later), to: &state, sender: "Alice"), "not even the host")
        XCTAssertNil(RoomReducer.apply(.editTile(tile.id, text: "old", stamp: t0), to: &state, sender: "Bob"), "not newer than what is there")
        XCTAssertNotNil(RoomReducer.apply(.editTile(tile.id, text: "new", stamp: later), to: &state, sender: "Bob"))
        XCTAssertEqual(state.tiles[0].card?.text, "new")
    }

    func testATileIsRemovedByItsAuthorOrTheHost() {
        let bobs = card(by: "Bob"), carols = card(by: "Carol")
        var state = room(bobs, carols)
        XCTAssertNil(RoomReducer.apply(.removeTile(bobs.id), to: &state, sender: "Carol"))
        XCTAssertNotNil(RoomReducer.apply(.removeTile(bobs.id), to: &state, sender: "Bob"))
        XCTAssertNotNil(RoomReducer.apply(.removeTile(carols.id), to: &state, sender: "Alice"), "the host may remove any tile")
        XCTAssertTrue(state.tiles.isEmpty)

        XCTAssertNil(RoomReducer.apply(.moveTile(bobs.id, x: 1, y: 1, stamp: later), to: &state, sender: "Bob"), "a late change to a removed tile")
        XCTAssertNil(RoomReducer.apply(.removeTile(bobs.id), to: &state, sender: nil))
    }

    // MARK: Chats

    func testAGuestSpeaksOnlyAsThemselves() {
        let tile = chat(ownedBy: "Bob")
        var state = room(tile)
        var forged = message(.user, by: "Alice", "why does the build fail today?")
        forged.streaming = true
        guard case .chatMessage(_, let stamped) = RoomReducer.apply(.chatMessage(tile.id, forged), to: &state, sender: "Carol") else { return XCTFail("refused") }
        XCTAssertEqual(stamped.author, "Carol")
        XCTAssertFalse(stamped.streaming)
        XCTAssertEqual(state.tiles[0].chat?.title, "Why does the build fail today", "the first question names the chat")

        XCTAssertNil(RoomReducer.apply(.chatMessage(tile.id, message(.assistant, by: "OpenAI")), to: &state, sender: "Carol"), "only the owner's Mac speaks for the model")
        XCTAssertNil(RoomReducer.apply(.chatMessage(tile.id, stamped), to: &state, sender: "Carol"), "the same message twice")
        XCTAssertEqual(state.tiles[0].chat?.messages.count, 1)
    }

    func testOnlyTheOwnerStreamsTheReply() {
        let tile = chat(ownedBy: "Bob")
        var state = room(tile)
        var reply = message(.assistant, by: "whoever", "")
        reply.streaming = true
        guard case .chatMessage(_, let stamped) = RoomReducer.apply(.chatMessage(tile.id, reply), to: &state, sender: "Bob") else { return XCTFail("refused") }
        XCTAssertEqual(stamped.author, RoomChatMessage.assistantAuthor)

        var grown = stamped
        grown.text = "Hello"
        grown.streaming = false
        XCTAssertNil(RoomReducer.apply(.chatDelta(tile.id, grown), to: &state, sender: "Carol"))
        XCTAssertNotNil(RoomReducer.apply(.chatDelta(tile.id, grown), to: &state, sender: "Bob"))
        XCTAssertEqual(state.tiles[0].chat?.lastReply?.text, "Hello")
        XCTAssertEqual(state.tiles[0].chat?.isStreaming, false)

        XCTAssertNil(RoomReducer.apply(.chatDelta(tile.id, message(.assistant, by: "x")), to: &state, sender: "Bob"), "a delta for a reply nobody has")
    }

    func testFilesAreAddedByAnyoneMarkedReadyByTheOwnerAndRemovedByEither() {
        let tile = chat(ownedBy: "Bob")
        var state = room(tile)
        let file = RoomFile(id: UUID(), name: "a.pdf", kind: .pdf, size: 10, addedBy: "Alice", thumbnail: nil, status: .ready)
        guard case .addFile(_, let stamped) = RoomReducer.apply(.addFile(tile.id, file), to: &state, sender: "Carol") else { return XCTFail("refused") }
        XCTAssertEqual(stamped.addedBy, "Carol")
        XCTAssertEqual(stamped.status, .sending, "only the owner's Mac can say a file is ready")
        XCTAssertEqual(state.tiles[0].chat?.messages.last?.text, "Carol added a.pdf")

        XCTAssertNil(RoomReducer.apply(.fileStatus(tile.id, fileID: file.id, .ready), to: &state, sender: "Carol"))
        XCTAssertNotNil(RoomReducer.apply(.fileStatus(tile.id, fileID: file.id, .ready), to: &state, sender: "Bob"))
        XCTAssertEqual(state.tiles[0].chat?.files.first?.status, .ready)

        let eventID = UUID()
        XCTAssertNil(RoomReducer.apply(.removeFile(tile.id, fileID: file.id, messageID: eventID), to: &state, sender: "Alice"),
                     "neither who added it nor the chat's owner")
        let relayed = RoomReducer.apply(.removeFile(tile.id, fileID: file.id, messageID: eventID, by: "Mallory"), to: &state, sender: "Carol")
        XCTAssertEqual(relayed, .removeFile(tile.id, fileID: file.id, messageID: eventID, by: "Carol"), "who did it is the sender, not the claim")
        XCTAssertEqual(state.tiles[0].chat?.files.count, 0)
        XCTAssertEqual(state.tiles[0].chat?.messages.last?.text, "Carol removed a.pdf")
    }

    func testAGuestAppliesTheHostsStampedRemoval() {
        let tile = chat(ownedBy: "Bob")
        var state = room(tile)
        let file = RoomFile(id: UUID(), name: "a.pdf", kind: .pdf, size: 10, addedBy: "Carol", thumbnail: nil, status: .ready)
        XCTAssertNotNil(RoomReducer.apply(.addFile(tile.id, file), to: &state, sender: nil))
        XCTAssertNotNil(RoomReducer.apply(.removeFile(tile.id, fileID: file.id, messageID: UUID(), by: "Carol"), to: &state, sender: nil))
        XCTAssertEqual(state.tiles[0].chat?.messages.last?.text, "Carol removed a.pdf")
    }

    func testFilesAreRequestedByTheOwnerOfTheNewChat() {
        let source = chat(ownedBy: "Bob"), target = chat(ownedBy: "Carol")
        var state = room(source, target)
        XCTAssertNil(RoomReducer.apply(.requestFiles(from: source.id, to: target.id), to: &state, sender: "Bob"))
        XCTAssertNotNil(RoomReducer.apply(.requestFiles(from: source.id, to: target.id), to: &state, sender: "Carol"))
        XCTAssertNil(RoomReducer.apply(.requestFiles(from: UUID(), to: target.id), to: &state, sender: "Carol"))
    }

    // MARK: Runs

    func testARunIsAttachedOnceWithALineSayingWho() {
        let talk = chat(ownedBy: "Bob"), work = run(ownedBy: "Carol")
        var state = room(talk, work)
        let attach = RoomMessage.attachRun(work.id, to: talk.id, messageID: UUID())
        XCTAssertNotNil(RoomReducer.apply(attach, to: &state, sender: "Alice"))
        XCTAssertEqual(state.tiles[0].chat?.runIDs, [work.id])
        XCTAssertEqual(state.tiles[0].chat?.messages.last?.text, "Alice added Carol’s run “Run”")
        XCTAssertNil(RoomReducer.apply(attach, to: &state, sender: "Alice"))
        XCTAssertNil(RoomReducer.apply(.attachRun(talk.id, to: talk.id, messageID: UUID()), to: &state, sender: "Alice"), "a chat is not a run")
    }

    func testOnlyTheOwnerUpdatesARunAndNotesSurviveTheUpdate() {
        let work = run(ownedBy: "Carol")
        var state = room(work)
        guard case .runNote(_, let note) = RoomReducer.apply(.runNote(work.id, RunNote(id: UUID(), from: "Alice", text: "try main")), to: &state, sender: "Bob")
        else { return XCTFail("refused") }
        XCTAssertEqual(note.from, "Bob")

        var update = RoomRunTile(ownerName: "Bob", title: "Run", folder: "~/p")
        update.state = .done
        XCTAssertNil(RoomReducer.apply(.runUpdate(work.id, update), to: &state, sender: "Bob"))
        XCTAssertNotNil(RoomReducer.apply(.runUpdate(work.id, update), to: &state, sender: "Carol"))
        XCTAssertEqual(state.tiles[0].run?.state, .done)
        XCTAssertEqual(state.tiles[0].run?.ownerName, "Carol", "an update can't hand the run to someone else")
        XCTAssertEqual(state.tiles[0].run?.notes, [note])
    }

    // MARK: People leaving

    func testWhenSomeoneLeavesTheirWorkStops() {
        var streaming = chat(ownedBy: "Bob")
        var reply = message(.assistant, by: "OpenAI")
        reply.streaming = true
        streaming.content = .chat(RoomChatTile(title: "t", ownerName: "Bob", model: "gpt-4.1", messages: [reply]))
        var state = room(streaming, run(ownedBy: "Bob"), run(ownedBy: "Carol"))
        state.memberGone("Bob")
        XCTAssertEqual(state.tiles[0].chat?.isStreaming, false)
        XCTAssertEqual(state.tiles[1].run?.state, .waiting("Bob left the room, so this run is no longer reporting."))
        XCTAssertEqual(state.tiles[2].run?.state, .running)
    }
}
