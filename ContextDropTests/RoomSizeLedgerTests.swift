import XCTest
@testable import ContextDrop

final class RoomSizeLedgerTests: XCTestCase {
    private func room(text: String) -> RoomState {
        let message = RoomChatMessage(id: UUID(), kind: .assistant, author: "OpenAI", text: text)
        let chat = RoomChatTile(title: "Chat", ownerName: "Alice", model: "model", messages: [message])
        let tile = RoomTile(id: UUID(), x: 0, y: 0, addedBy: "Alice", content: .chat(chat))
        return RoomState(id: UUID(), name: "Table", hostName: "Alice", members: [], tiles: [tile])
    }

    func testGrowthStopsAtConservativeBudget() throws {
        var state = room(text: "small")
        let initialBytes = try RoomCodec.encode(.snapshot(state)).count
        let ledger = try RoomSizeLedger(room: state, budgetBytes: initialBytes + 20)
        var reply = try XCTUnwrap(state.tiles[0].chat?.messages[0])
        reply.text = String(repeating: "x", count: 200)
        let change = RoomMessage.chatDelta(state.tiles[0].id, reply)
        XCTAssertNotNil(RoomReducer.apply(change, to: &state, sender: "Alice"))
        XCTAssertNil(try ledger.admitting(state, change: change))
    }

    func testRemovalReleasesBudget() throws {
        var state = room(text: String(repeating: "a", count: 100))
        let ledger = try RoomSizeLedger(room: state)
        state.tiles = []
        let smaller = try XCTUnwrap(ledger.admitting(state))
        XCTAssertLessThan(smaller.estimatedBytes, ledger.estimatedBytes)
    }
}
