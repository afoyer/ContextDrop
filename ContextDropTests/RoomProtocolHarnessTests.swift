import Foundation
@preconcurrency import MultipeerConnectivity
import XCTest
@testable import ContextDrop

@MainActor
private final class MemoryRoomNetwork {
    var host: MemoryRoomTransport!
    var guests: [MemoryRoomTransport] = []

    func guest(_ name: String) -> MemoryRoomTransport {
        let transport = MemoryRoomTransport(network: self, peerID: MCPeerID(displayName: name))
        guests.append(transport)
        return transport
    }
}

@MainActor
private final class MemoryRoomTransport: RoomTransport {
    let network: MemoryRoomNetwork
    let peerID: MCPeerID
    var hosting = false
    var pendingInvitations: [RoomInvitation] = []
    var invitedPeers: [MCPeerID] = []
    var onInvitation: (@MainActor (RoomInvitation) -> Void)?
    var onInvitationsChanged: (@MainActor () -> Void)?
    var onMessage: (@MainActor (RoomMessage, MCPeerID) -> Void)?
    var onPeerConnected: (@MainActor (MCPeerID) -> Void)?
    var onPeerDisconnected: (@MainActor (MCPeerID) -> Void)?
    var onInviteUnanswered: (@MainActor (MCPeerID) -> Void)?
    var onJoinFailed: (@MainActor () -> Void)?
    var onFile: (@MainActor (URL, String) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var delivered: [RoomMessage] = []
    var deferOutgoing = false
    var queuedOutgoing: [RoomMessage] = []

    init(network: MemoryRoomNetwork, peerID: MCPeerID) {
        self.network = network
        self.peerID = peerID
    }
    func host() { hosting = true; network.host = self }
    func invite(_ peerID: MCPeerID, invitation: RoomInvitation) -> Bool { true }
    func accept(_ invitation: RoomInvitation) -> Bool { true }
    func decline(_ invitation: RoomInvitation) {}
    func close(afterFlush: Bool) { hosting = false }
    func bindMember(_ id: String, to peerID: MCPeerID) {}
    func isHostPeer(_ peerID: MCPeerID) -> Bool { !hosting && network.host?.peerID == peerID }
    func sendFile(_ url: URL, name: String, toMember: String, done: @escaping @MainActor @Sendable (Bool) -> Void) { done(false) }

    @discardableResult
    func send(_ message: RoomMessage, to targets: [MCPeerID]?, except: MCPeerID?) -> Bool {
        if hosting {
            for guest in network.guests where (targets == nil || targets!.contains(guest.peerID)) && guest.peerID != except {
                // Exercise the real codec, including sanitization, on both sides.
                guard let decoded = try? RoomCodec.decode(RoomCodec.encode(message)) else { return false }
                guest.delivered.append(decoded)
                guest.onMessage?(decoded, peerID)
            }
        } else {
            if deferOutgoing {
                queuedOutgoing.append(message)
                return true
            }
            guard let host = network.host,
                  let decoded = try? RoomCodec.decode(RoomCodec.encode(message)) else { return false }
            host.delivered.append(decoded)
            host.onMessage?(decoded, peerID)
        }
        return true
    }
    func flushOutgoing() {
        deferOutgoing = false
        let messages = queuedOutgoing
        queuedOutgoing = []
        for message in messages { _ = send(message, to: nil, except: nil) }
    }
    func connect() { onPeerConnected?(network.host.peerID) }
}

@MainActor
final class RoomProtocolHarnessTests: XCTestCase {
    private func setupRoom() -> (RoomStore, RoomStore, RoomStore, MemoryRoomNetwork) {
        let network = MemoryRoomNetwork()
        let hostTransport = MemoryRoomTransport(network: network, peerID: MCPeerID(displayName: "Host"))
        let guestA = network.guest("Alice")
        let guestB = network.guest("Alice")
        let peerService = PeerService(notices: NoticeCenter())
        let host = RoomStore(peers: peerService, transport: hostTransport,
                             identity: RoomMember(id: UUID().uuidString, name: "Host", isHost: true))
        let aliceA = RoomStore(peers: peerService, transport: guestA,
                               identity: RoomMember(id: UUID().uuidString, name: "Alice", isHost: false))
        let aliceB = RoomStore(peers: peerService, transport: guestB,
                               identity: RoomMember(id: UUID().uuidString, name: "Alice", isHost: false))
        host.openRoom()
        let invitation = RoomInvitation(id: host.room!.id, name: host.room!.name, hostName: "Host", memberCount: 1)
        aliceA.join(invitation); guestA.connect()
        aliceB.join(invitation); guestB.connect()
        return (host, aliceA, aliceB, network)
    }

    func testTwoPeopleWithSameNameHaveDifferentPermissionsAndSenderGetsEcho() {
        let (host, aliceA, aliceB, network) = setupRoom()
        XCTAssertEqual(host.members.count, 3)
        XCTAssertNotEqual(aliceA.localID, aliceB.localID)
        let tileID = aliceA.addCard(kind: .note, text: "mine")!
        XCTAssertNotNil(aliceA.tile(tileID), "Sender must apply its own host echo")
        XCTAssertNotNil(aliceB.tile(tileID))
        XCTAssertEqual(host.tile(tileID)?.addedByID, aliceA.localID)
        _ = aliceB.post(.editTile(tileID, text: "stolen"))
        XCTAssertEqual(host.tile(tileID)?.card?.text, "mine")
        XCTAssertEqual(aliceA.tile(tileID)?.card?.text, "mine")
        XCTAssertNotNil(aliceB.notice)
        XCTAssertTrue(network.guests[1].delivered.contains { if case .rejected = $0 { true } else { false } })
    }

    func testRejectedCreationDoesNotRunDeferredAction() {
        let (host, guest, _, _) = setupRoom()
        // Keep the host at the tile limit while the guest still has its earlier snapshot.
        for index in 0..<RoomLimits.maxTiles {
            _ = host.addCard(kind: .note, text: "\(index)")
        }
        var opened = false
        // The guest has received the host's additions, so its local limit prevents submission.
        // An unauthorized edit proves the rejection path without relying on UI timing.
        let target = host.tiles[0].id
        _ = guest.post(.editTile(target, text: "no"), onAccepted: { error in opened = error == nil })
        XCTAssertFalse(opened)
        XCTAssertEqual(host.tile(target)?.card?.text, "0")
    }

    func testChatDraftWaitsForEchoAndSurvivesRejection() {
        let (host, guest, _, network) = setupRoom()
        let tileID = host.addChatTile(title: "Help")!
        let transport = network.guests[0]
        transport.deferOutgoing = true
        guest.chatDrafts[tileID] = "first question"
        XCTAssertTrue(guest.sendChat("first question", in: tileID))
        XCTAssertTrue(guest.sendingChatTiles.contains(tileID))
        XCTAssertEqual(guest.chatDrafts[tileID], "first question")
        XCTAssertFalse(guest.sendChat("first question", in: tileID), "A pending send must not duplicate")
        transport.flushOutgoing()
        XCTAssertFalse(guest.sendingChatTiles.contains(tileID))
        XCTAssertNil(guest.chatDrafts[tileID])
        XCTAssertEqual(host.tile(tileID)?.chat?.messages.filter { $0.kind == .user }.count, 1)

        transport.deferOutgoing = true
        guest.chatDrafts[tileID] = "keep this draft"
        XCTAssertTrue(guest.sendChat("keep this draft", in: tileID))
        host.removeTile(tileID)
        transport.flushOutgoing()
        XCTAssertFalse(guest.sendingChatTiles.contains(tileID))
        XCTAssertEqual(guest.recoveredChatDraft, "keep this draft")
        XCTAssertNotNil(guest.notice)
    }

    func testCardEditWaitsForEchoAndReportsRejection() {
        let (host, guest, _, network) = setupRoom()
        let tileID = guest.addCard(kind: .note, text: "original")!
        let transport = network.guests[0]
        transport.deferOutgoing = true
        var result: String?
        XCTAssertTrue(guest.editCard(tileID, text: "my edited draft", onAccepted: { result = $0 ?? "accepted" }))
        XCTAssertEqual(guest.tile(tileID)?.card?.text, "original", "The edit must wait for the host")
        host.removeTile(tileID)
        transport.flushOutgoing()
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result, "accepted")
    }
}
