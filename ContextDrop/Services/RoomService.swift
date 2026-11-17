import Foundation
@preconcurrency import MultipeerConnectivity
import Observation

/// Narrow transport seam used by the room coordinator and the in-memory room tests.
@MainActor
protocol RoomTransport: AnyObject {
    var pendingInvitations: [RoomInvitation] { get }
    var invitedPeers: [MCPeerID] { get }
    var onInvitation: (@MainActor (RoomInvitation) -> Void)? { get set }
    var onInvitationsChanged: (@MainActor () -> Void)? { get set }
    var onMessage: (@MainActor (RoomMessage, MCPeerID) -> Void)? { get set }
    var onPeerConnected: (@MainActor (MCPeerID) -> Void)? { get set }
    var onPeerDisconnected: (@MainActor (MCPeerID) -> Void)? { get set }
    var onInviteUnanswered: (@MainActor (MCPeerID) -> Void)? { get set }
    var onJoinFailed: (@MainActor () -> Void)? { get set }
    var onFile: (@MainActor (URL, String) -> Void)? { get set }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    func bindMember(_ id: String, to peerID: MCPeerID)
    func isHostPeer(_ peerID: MCPeerID) -> Bool
    func host()
    func invite(_ peerID: MCPeerID, invitation: RoomInvitation) -> Bool
    func accept(_ invitation: RoomInvitation) -> Bool
    func decline(_ invitation: RoomInvitation)
    @discardableResult func send(_ message: RoomMessage, to: [MCPeerID]?, except: MCPeerID?) -> Bool
    func sendFile(_ url: URL, name: String, toMember: String, done: @escaping @MainActor @Sendable (Bool) -> Void)
    func close(afterFlush: Bool)
}

extension RoomTransport {
    @discardableResult func send(_ message: RoomMessage) -> Bool { send(message, to: nil, except: nil) }
    @discardableResult func send(_ message: RoomMessage, to: [MCPeerID]) -> Bool { send(message, to: to, except: nil) }
    @discardableResult func send(_ message: RoomMessage, except: MCPeerID?) -> Bool { send(message, to: nil, except: except) }
    func close() { close(afterFlush: false) }
}

/// Transport for one room: a single long-lived MCSession, plus the room invitations that arrive for this Mac.
///
/// Host: `host()` then `invite(_:invitation:)` (through PeerService's browser). Every joiner talks to the host,
/// and the host relays. Guest: `accept(_:)` an invitation; the host's peer is remembered and is the only peer
/// a guest sends to or listens to. What the messages mean lives in `RoomStore`.
/// MPC delegates run on private queues; each is `nonisolated` and only forwards to the main actor.
@MainActor
@Observable
final class RoomService: NSObject, RoomTransport {
    nonisolated static let invitationTimeout: TimeInterval = 60
    nonisolated static let joinTimeout: TimeInterval = 30
    /// MCSession holds 8 peers including this one.
    nonisolated static let maxPeers = 8

    private enum Role { case host, guest(host: MCPeerID) }

    private struct PendingReply {
        let token = UUID()
        let peerID: MCPeerID
        let reply: InvitationReply
    }

    /// Room invitations waiting for Join / Not now.
    private(set) var pendingInvitations: [RoomInvitation] = []
    /// Host only: peers invited and not yet answered.
    private(set) var invitedPeers: [MCPeerID] = []
    private(set) var connectedPeers: [MCPeerID] = []

    @ObservationIgnored var onInvitation: (@MainActor (RoomInvitation) -> Void)?
    @ObservationIgnored var onInvitationsChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onMessage: (@MainActor (RoomMessage, MCPeerID) -> Void)?
    @ObservationIgnored var onPeerConnected: (@MainActor (MCPeerID) -> Void)?
    @ObservationIgnored var onPeerDisconnected: (@MainActor (MCPeerID) -> Void)?
    /// Host only: an invited peer declined or never answered.
    @ObservationIgnored var onInviteUnanswered: (@MainActor (MCPeerID) -> Void)?
    /// Guest only: accepted, but the host never connected.
    @ObservationIgnored var onJoinFailed: (@MainActor () -> Void)?
    /// A file arrived (already moved to a temporary place we own). The name is "<tileID>|<fileID>".
    @ObservationIgnored var onFailure: (@MainActor (String) -> Void)?
    @ObservationIgnored var onFile: (@MainActor (URL, String) -> Void)?

    @ObservationIgnored private let peers: PeerService
    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var role: Role?
    @ObservationIgnored private var memberPeers: [String: MCPeerID] = [:]
    @ObservationIgnored private var replies: [UUID: PendingReply] = [:]

    init(peers: PeerService) {
        self.peers = peers
        super.init()
        peers.onRoomInvitation = { [weak self] invitation, peerID, reply in
            guard let self else { reply.handler(false, nil); return }
            self.handleInvitation(invitation, from: peerID, reply: reply)
        }
    }

    func bindMember(_ id: String, to peerID: MCPeerID) { memberPeers[id] = peerID }

    func isHostPeer(_ peerID: MCPeerID) -> Bool {
        if case .guest(let host) = role { return host == peerID }
        return false
    }

    // MARK: Hosting

    func host() {
        close()
        let session = peers.makeUnownedSession()
        session.delegate = self
        self.session = session
        role = .host
        p2pLog.info("Room opened")
    }

    /// Returns false when the invitation could not be sent (not hosting, already here, already invited, room full).
    @discardableResult
    func invite(_ peerID: MCPeerID, invitation: RoomInvitation) -> Bool {
        guard case .host = role, let session,
              !connectedPeers.contains(peerID), !invitedPeers.contains(peerID),
              connectedPeers.count + invitedPeers.count + 1 < Self.maxPeers,
              let context = RoomCodec.encodeInvitation(invitation) else { return false }
        invitedPeers.append(peerID)
        peers.invite(peerID, to: session, context: context, timeout: Self.invitationTimeout)
        p2pLog.info("Invited \(peerID.displayName, privacy: .public) to the room")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.invitationTimeout + 1))
            guard let self, self.session === session, self.invitedPeers.contains(peerID) else { return }
            self.invitedPeers.removeAll { $0 == peerID }
            self.onInviteUnanswered?(peerID)
        }
        return true
    }

    // MARK: Joining

    /// Accepts a pending invitation and starts connecting to its host. False when it already expired.
    func accept(_ invitation: RoomInvitation) -> Bool {
        guard let pending = replies.removeValue(forKey: invitation.id) else {
            removePending(invitation.id)
            return false
        }
        removePending(invitation.id)
        close()
        let session = peers.makeUnownedSession()
        session.delegate = self
        self.session = session
        role = .guest(host: pending.peerID)
        pending.reply.handler(true, session)
        p2pLog.info("Joining \(pending.peerID.displayName, privacy: .public)'s room")

        // Never sit on "Joining…" forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.joinTimeout))
            guard let self, self.session === session, !self.connectedPeers.contains(pending.peerID) else { return }
            p2pLog.error("Timed out joining \(pending.peerID.displayName, privacy: .public)'s room")
            self.close()
            self.onJoinFailed?()
        }
        return true
    }

    func decline(_ invitation: RoomInvitation) {
        replies.removeValue(forKey: invitation.id)?.reply.handler(false, nil)
        removePending(invitation.id)
    }

    private func removePending(_ id: UUID) {
        guard pendingInvitations.contains(where: { $0.id == id }) else { return }
        pendingInvitations.removeAll { $0.id == id }
        onInvitationsChanged?()
    }

    private func handleInvitation(_ raw: RoomInvitation, from peerID: MCPeerID, reply: InvitationReply) {
        guard raw.version == RoomMessage.currentVersion else {
            reply.handler(false, nil)
            onFailure?("This room uses an incompatible app version. Update both Macs before joining.")
            return
        }
        // The name shown is the peer's real display name, not whatever the context claims.
        var invitation = raw.sanitized()
        invitation.hostName = peerID.displayName
        // A repeat from the same host or for the same room replaces the earlier one.
        for (id, pending) in replies where id == invitation.id || pending.peerID == peerID {
            replies.removeValue(forKey: id)?.reply.handler(false, nil)
            pendingInvitations.removeAll { $0.id == id }
        }
        let pending = PendingReply(peerID: peerID, reply: reply)
        replies[invitation.id] = pending
        pendingInvitations.insert(invitation, at: 0)
        p2pLog.info("Room invitation \"\(invitation.name, privacy: .public)\" from \(peerID.displayName, privacy: .public)")
        onInvitationsChanged?()
        onInvitation?(invitation)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.invitationTimeout - 2))
            guard let self, self.replies[invitation.id]?.token == pending.token else { return }
            self.decline(invitation)
        }
    }

    // MARK: Messages

    /// Host: to every connected peer (or `to`), minus `except`. Guest: to the host only.
    @discardableResult
    func send(_ message: RoomMessage, to targets: [MCPeerID]? = nil, except: MCPeerID? = nil) -> Bool {
        guard let session, let role else { return false }
        var recipients: [MCPeerID]
        switch role {
        case .host: recipients = targets ?? connectedPeers
        case .guest(let host): recipients = [host]
        }
        let live = session.connectedPeers
        recipients = recipients.filter { $0 != except && live.contains($0) }
        guard !recipients.isEmpty else { if case .host = role { return true }; return false }
        do {
            try session.send(try RoomCodec.encode(message), toPeers: recipients, with: .reliable)
            return true
        } catch {
            p2pLog.error("Room send (\(message.kind.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            onFailure?("The room change could not be sent. Rejoin the room to synchronize.")
            return false
        }
    }

    /// Sends a file's bytes toward `member` (a display name). A guest always sends to the host, who passes it on.
    /// `done` is called with false when it could not be sent.
    func sendFile(_ url: URL, name: String, toMember member: String, done: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let session, let role else { done(false); return }
        let target: MCPeerID?
        switch role {
        case .host: target = memberPeers[member]
        case .guest(let host): target = host
        }
        guard let target, session.connectedPeers.contains(target) else { done(false); return }
        session.sendResource(at: url, withName: name, toPeer: target, withCompletionHandler: Self.resourceSent(done))
    }

    /// MPC calls this on its own queue, so it must not be a main-actor closure: it only hops to the main actor.
    nonisolated private static func resourceSent(_ done: @escaping @MainActor @Sendable (Bool) -> Void) -> @Sendable (Error?) -> Void {
        { error in
            let sent = error == nil
            if let error { p2pLog.error("Room file send failed: \(error.localizedDescription, privacy: .public)") }
            Task { @MainActor in done(sent) }
        }
    }

    /// Leaves the session. `afterFlush` keeps the connection up briefly so a last message (ended / left) gets out.
    func close(afterFlush: Bool = false) {
        memberPeers = [:]
        guard let session else { return }
        self.session = nil
        role = nil
        connectedPeers = []
        invitedPeers = []
        session.delegate = nil
        if afterFlush {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                session.disconnect()
            }
        } else {
            session.disconnect()
        }
    }

    // MARK: Delegate handlers (main actor)

    fileprivate func handleStateChange(_ state: MCSessionState, peer peerID: MCPeerID, session: MCSession) {
        guard session === self.session else { return }
        switch state {
        case .connected:
            invitedPeers.removeAll { $0 == peerID }
            guard !connectedPeers.contains(peerID) else { return }
            connectedPeers.append(peerID)
            p2pLog.info("Room: \(peerID.displayName, privacy: .public) connected")
            onPeerConnected?(peerID)
        case .notConnected:
            if connectedPeers.contains(peerID) {
                connectedPeers.removeAll { $0 == peerID }
                p2pLog.info("Room: \(peerID.displayName, privacy: .public) disconnected")
                onPeerDisconnected?(peerID)
            } else if invitedPeers.contains(peerID) {
                invitedPeers.removeAll { $0 == peerID }
                onInviteUnanswered?(peerID)
            } else if isHostPeer(peerID) {
                // Accepted, but the connection to the host never came up.
                close()
                onJoinFailed?()
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    fileprivate func handleData(_ data: Data, from peerID: MCPeerID, session: MCSession) {
        guard session === self.session else { return }
        // A guest only listens to the host, even though MPC may connect guests to each other.
        if case .guest(let host) = role, host != peerID { return }
        do {
            onMessage?(try RoomCodec.decode(data), peerID)
        } catch {
            if case RoomWireError.unsupportedVersion = error {
                onFailure?("This Mac uses an incompatible room protocol. Update both apps before joining.")
                if isHostPeer(peerID) { close(); onJoinFailed?() }
            }
            p2pLog.error("Room: ignored invalid message from \(peerID.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    fileprivate func handleFile(_ url: URL, name: String, from peerID: MCPeerID, session: MCSession) {
        var accepted = session === self.session
        // A guest only takes files from the host.
        if case .guest(let host) = role, host != peerID { accepted = false }
        guard accepted, let onFile else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        onFile(url, name)
    }
}

// MARK: - Delegate (nonisolated → main actor)

extension RoomService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.handleStateChange(state, peer: peerID, session: session) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.handleData(data, from: peerID, session: session) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // MPC deletes `localURL` when this returns, so move the file first.
        guard error == nil, let localURL else { return }
        let size = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard size <= RoomLimits.maxFileBytes else { return }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("ctxdrop-room-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: localURL, to: kept)) != nil else { return }
        Task { @MainActor in self.handleFile(kept, name: resourceName, from: peerID, session: session) }
    }
}
