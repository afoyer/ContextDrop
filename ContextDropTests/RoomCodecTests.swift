import XCTest
@testable import ContextDrop

/// The room wire format: what is accepted, what is refused, and what is cut down to size on the way in.
final class RoomCodecTests: XCTestCase {
    private func tile(text: String = "hi", x: Double = 10, y: Double = 20) -> RoomTile {
        RoomTile(id: UUID(), x: x, y: y, addedBy: "Alice", movedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100),
                 content: .card(RoomCardBody(kind: .thought, text: text, caption: nil)))
    }

    private func roundTrip(_ message: RoomMessage) throws -> RoomMessage {
        try RoomCodec.decode(try RoomCodec.encode(message))
    }

    func testAddTileRoundTrips() throws {
        let original = tile()
        XCTAssertEqual(try roundTrip(.addTile(original)), .addTile(original))
    }

    func testEveryKindRoundTripsWithItsPayload() throws {
        let id = UUID(), other = UUID(), stamp = Date(timeIntervalSince1970: 100)
        let chat = RoomChatMessage(id: UUID(), kind: .user, author: "Alice", text: "hello", createdAt: stamp)
        let file = RoomFile(id: UUID(), name: "a.pdf", kind: .pdf, size: 10, addedBy: "Alice", thumbnail: nil, status: .sending)
        let run = RoomRunTile(ownerName: "Alice", title: "Run", folder: "~/p")
        let messages: [RoomMessage] = [
            .hello(RoomMember(id: "Alice", name: "Alice", isHost: false)),
            .snapshot(RoomState(id: id, name: "Table", hostName: "Alice", members: [], tiles: [tile()])),
            .memberLeft("Alice"), .ended,
            .addTile(tile()), .moveTile(id, x: 1, y: 2, stamp: stamp), .editTile(id, text: "t", stamp: stamp),
            .removeTile(id), .setCollapsed(id, true, stamp: stamp),
            .chatMessage(id, chat), .chatDelta(id, chat),
            .addFile(id, file), .fileStatus(id, fileID: file.id, .ready), .removeFile(id, fileID: file.id, messageID: UUID()),
            .requestFiles(from: id, to: other),
            .attachRun(other, to: id, messageID: UUID()), .runUpdate(id, run), .runNote(id, RunNote(id: UUID(), from: "Bob", text: "?")),
        ]
        for message in messages {
            XCTAssertEqual(try roundTrip(message).kind, message.kind)
        }
    }

    func testMissingPayloadIsRefused() throws {
        let data = Data(#"{"version":2,"kind":"moveTile","tileID":"\#(UUID().uuidString)"}"#.utf8)
        XCTAssertThrowsError(try RoomCodec.decode(data))
        XCTAssertNoThrow(try RoomCodec.decode(Data(#"{"version":2,"kind":"removeTile","tileID":"\#(UUID().uuidString)"}"#.utf8)))
    }

    func testOtherVersionsAreRefused() throws {
        let data = Data(#"{"version":\#(RoomMessage.currentVersion + 1),"kind":"removeTile","tileID":"\#(UUID().uuidString)"}"#.utf8)
        XCTAssertThrowsError(try RoomCodec.decode(data))
    }

    func testGarbageIsRefused() {
        XCTAssertThrowsError(try RoomCodec.decode(Data("nope".utf8)))
    }

    func testOversizedTextAndCoordinatesAreCutDown() throws {
        let long = String(repeating: "a", count: RoomLimits.maxTextLength + 50)
        guard case .addTile(let decoded) = try roundTrip(.addTile(tile(text: long, x: -9e12, y: 9e12))) else { return XCTFail("not a tile") }
        XCTAssertEqual(decoded.card?.text.count, RoomLimits.maxTextLength)
        XCTAssertEqual(decoded.x, -RoomLimits.coordinateLimit)
        XCTAssertEqual(decoded.y, RoomLimits.coordinateLimit)
    }

    func testAStampFromTheFutureIsPulledBack() throws {
        let future = Date().addingTimeInterval(3_600)
        guard case .moveTile(_, _, _, let stamp) = try roundTrip(.moveTile(UUID(), x: 0, y: 0, stamp: future)) else { return XCTFail("not a move") }
        XCTAssertLessThan(stamp, Date().addingTimeInterval(RoomLimits.maxClockSkew + 1))
    }

    func testSnapshotDropsDuplicateTilesAndMembers() throws {
        let one = tile()
        let member = RoomMember(id: "Alice", name: "Alice", isHost: true)
        let state = RoomState(id: UUID(), name: "Table", hostName: "Alice", members: [member, member], tiles: [one, one])
        guard case .snapshot(let decoded) = try roundTrip(.snapshot(state)) else { return XCTFail("not a snapshot") }
        XCTAssertEqual(decoded.tiles.count, 1)
        XCTAssertEqual(decoded.members.count, 1)

        // Who did it travels under the wire key `from`, and only where it is used.
        let removal = RoomMessage.removeFile(UUID(), fileID: UUID(), messageID: UUID(), by: "Alice")
        XCTAssertEqual(try roundTrip(removal), removal)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: RoomCodec.encode(removal)) as? [String: Any])
        XCTAssertEqual(json["from"] as? String, "Alice")
        XCTAssertEqual(json["version"] as? Int, RoomMessage.currentVersion)
        XCTAssertEqual(json["kind"] as? String, "removeFile")
    }

    func testInvitationRoundTripsAndIsNotAPreview() {
        let invitation = RoomInvitation(id: UUID(), name: "Table", hostName: "Alice", memberCount: 99)
        let decoded = RoomCodec.decodeInvitation(RoomCodec.encodeInvitation(invitation))
        XCTAssertEqual(decoded?.id, invitation.id)
        XCTAssertEqual(decoded?.memberCount, RoomLimits.maxMembers)
        XCTAssertNil(RoomCodec.decodeInvitation(Data(#"{"title":"a share preview"}"#.utf8)))
        XCTAssertNil(RoomCodec.decodeInvitation(nil))
    }
}
