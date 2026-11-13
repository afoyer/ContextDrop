import XCTest
@testable import ContextDrop

/// The room wire format: what is accepted, what is refused, and what is cut down to size on the way in.
final class RoomCodecTests: XCTestCase {
    private func tile(text: String = "hi", x: Double = 10, y: Double = 20) -> RoomTile {
        RoomTile(id: UUID(), x: x, y: y, addedBy: "Alice",
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
            .addTile(tile()), .moveTile(id, x: 1, y: 2), .editTile(id, text: "t"),
            .removeTile(id), .setCollapsed(id, true),
            .chatMessage(id, chat), .chatDelta(id, chat),
            .addFile(id, file), .fileStatus(id, fileID: file.id, .ready), .removeFile(id, fileID: file.id, messageID: UUID()),
            .requestFiles(from: id, to: other),
            .attachRun(other, to: id, messageID: UUID()), .runUpdate(id, run), .runNote(id, RunNote(id: UUID(), from: "Bob", text: "?")),
            .runRequest(id, RunRequest(id: UUID(), from: "Bob", text: "go on", files: [file])),
            .runRequestStatus(id, requestID: other, .accepted),
        ]
        for message in messages {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testOperationOutcomesKeepFullPayloadInFlatEnvelope() throws {
        let operationID = UUID()
        let change = RoomMessage.editTile(UUID(), text: "quoted \"text\"")
        for message in [RoomMessage.submit(operationID, change), .accepted(operationID, change),
                        .rejected(operationID, "Room capacity reached.")] {
            XCTAssertEqual(try roundTrip(message), message)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: RoomCodec.encode(message)) as? [String: Any])
            XCTAssertEqual(json["operationID"] as? String, operationID.uuidString)
            XCTAssertEqual(json["version"] as? Int, RoomMessage.currentVersion)
            XCTAssertNil(json["change"], "Operations must retain the flat wire format")
        }
    }

    func testMemberIdentityAndRunNoteIdentitySurviveTheCodec() throws {
        let memberID = UUID().uuidString
        let note = RunNote(id: UUID(), from: "Alice", fromID: memberID, text: "Review this")
        XCTAssertEqual(try roundTrip(.hello(RoomMember(id: memberID, name: "Alice", isHost: false))),
                       .hello(RoomMember(id: memberID, name: "Alice", isHost: false)))
        XCTAssertEqual(try roundTrip(.runNote(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, note)),
                       .runNote(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, note))
    }

    func testAcceptedPayloadIsStillSanitized() throws {
        let operationID = UUID()
        let original = tile(text: String(repeating: "x", count: RoomLimits.maxTextLength + 500), x: 9e12)
        let accepted = try roundTrip(.accepted(operationID, .addTile(original)))
        XCTAssertEqual(accepted, .accepted(operationID, .addTile(original.sanitized())))
    }

    func testVersionIsCheckedBeforeUnknownKindOrPayload() {
        for json in [#"{"kind":"futureOperation"}"#,
                     #"{"version":999,"kind":"futureOperation","tile":"different schema"}"#] {
            XCTAssertThrowsError(try RoomCodec.decode(Data(json.utf8))) { error in
                guard case RoomWireError.unsupportedVersion = error else {
                    return XCTFail("Expected version failure before payload decoding, got \(error)")
                }
            }
        }
    }

    func testFixedMoveFixture() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let json = #"{"version":\#(RoomMessage.currentVersion),"kind":"moveTile","tileID":"11111111-1111-1111-1111-111111111111","x":12.5,"y":-9}"#
        XCTAssertEqual(try RoomCodec.decode(Data(json.utf8)),
                       .moveTile(id, x: 12.5, y: -9))
    }

    func testPayloadByteLimitAppliesBeforeDecoding() {
        XCTAssertThrowsError(try RoomCodec.decode(Data(repeating: 32, count: RoomLimits.maxPayloadBytes + 1))) { error in
            guard case RoomWireError.payloadTooLarge = error else { return XCTFail("Expected byte limit, got \(error)") }
        }
    }

    func testMissingPayloadIsRefused() throws {
        let v = RoomMessage.currentVersion
        let data = Data(#"{"version":\#(v),"kind":"moveTile","tileID":"\#(UUID().uuidString)"}"#.utf8)
        XCTAssertThrowsError(try RoomCodec.decode(data))
        XCTAssertNoThrow(try RoomCodec.decode(Data(#"{"version":\#(v),"kind":"removeTile","tileID":"\#(UUID().uuidString)"}"#.utf8)))
        XCTAssertThrowsError(try RoomCodec.decode(Data(#"{"version":\#(v),"kind":"runRequestStatus","tileID":"\#(UUID().uuidString)"}"#.utf8)))
    }

    func testOtherVersionsAreRefused() throws {
        let data = Data(#"{"version":\#(RoomMessage.currentVersion + 1),"kind":"removeTile","tileID":"\#(UUID().uuidString)"}"#.utf8)
        XCTAssertThrowsError(try RoomCodec.decode(data))
    }

    func testARunRequestKeepsItsFilesAndIsCutDown() throws {
        let files = (0..<12).map { RoomFile(id: UUID(), name: "f\($0).txt", kind: .text, size: 1, addedBy: "Bob", thumbnail: nil, status: .sending) }
        let request = RunRequest(id: UUID(), from: "Bob", text: String(repeating: "x", count: RoomLimits.maxQuestionLength + 50), files: files)
        guard case .runRequest(_, let decoded) = try roundTrip(.runRequest(UUID(), request)) else { return XCTFail("wrong kind") }
        XCTAssertEqual(decoded.text.count, RoomLimits.maxQuestionLength)
        XCTAssertEqual(decoded.files.map(\.id), Array(files.prefix(RoomLimits.maxFilesPerRequest)).map(\.id))
        XCTAssertEqual(decoded.status, .pending)
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
