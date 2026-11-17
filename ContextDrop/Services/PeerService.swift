import AppKit
import Foundation
@preconcurrency import MultipeerConnectivity
import Observation
import os

let p2pLog = Logger(subsystem: "edu.cmu.hackathon.ContextDrop", category: "P2P")

struct NearbyPeer: Identifiable, Equatable {
    let peerID: MCPeerID
    var device: String
    var isNearby: Bool
    var id: MCPeerID { peerID }
    var name: String { peerID.displayName }
}

/// An offer from someone nearby, waiting for Decline / Save for Later / Continue.
struct IncomingOffer: Identifiable, Equatable {
    enum Phase: Equatable { case pending, receiving(open: Bool), failed }
    let id: UUID
    let peerID: MCPeerID
    let preview: SharePreview
    let receivedAt: Date
    var phase: Phase = .pending
    var seen = false
    var senderName: String { preview.senderName.isEmpty ? peerID.displayName : preview.senderName }
}

/// The share currently being sent, as the Nearby view shows it.
struct OutgoingTransfer: Equatable {
    enum Phase: Equatable { case waiting, sending, delivered, declined, failed }
    let shareID: UUID
    let peerID: MCPeerID
    var phase: Phase
    let startedAt: Date
    var peerName: String { peerID.displayName }
}

/// Handoff transport over Multipeer Connectivity.
///
/// Sender: invite (preview as context) → receiver accepts → send ShareSummary → receiver acks → done.
/// Every transfer gets its own MCSession, so transfers never interfere and stale callbacks are easy to drop.
/// MPC delegates run on private queues; each is `nonisolated` and only forwards to the main actor.
@MainActor
@Observable
final class PeerService: NSObject {
    nonisolated static let serviceType = "ctxdrop"
    nonisolated static let invitationTimeout: TimeInterval = 90
    nonisolated static let receiveTimeout: TimeInterval = 30

    private(set) var localDisplayName: String
    private(set) var localDevice: String = MachineInfo.cachedModel ?? "Mac"
    private(set) var peers: [NearbyPeer] = []
    private(set) var offers: [IncomingOffer] = []
    private(set) var outgoing: OutgoingTransfer?
    private(set) var isDiscovering = false
    /// Where problems the user should know about are posted.
    @ObservationIgnored let notices: NoticeCenter

    /// Called when a full share arrived and was acknowledged. `open` = the user chose Continue.
    /// One share, or several tabs shared together (first is the one the offer previewed).
    @ObservationIgnored var onShareReceived: (@MainActor ([ShareSummary], Bool) -> Void)?
    /// Called when a new offer arrives (to show the notification panel).
    @ObservationIgnored var onOfferArrived: (@MainActor (IncomingOffer) -> Void)?
    /// Called when someone nearby invites this Mac into a room (see `RoomService`). The receiver must call the reply.
    @ObservationIgnored var onRoomInvitation: (@MainActor (RoomInvitation, MCPeerID, InvitationReply) -> Void)?

    var nearbyPeers: [NearbyPeer] { peers.filter(\.isNearby) }

    private struct Transfer {
        enum Role { case sending(ShareSummary), receiving(offerID: UUID, open: Bool) }
        let session: MCSession
        let peerID: MCPeerID
        var role: Role
        let startedAt: Date
        var completed = false
        /// Tabs sent along with the main share.
        var extras: [ShareSummary] = []
    }

    @ObservationIgnored private var myPeerID: MCPeerID
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser
    @ObservationIgnored private var transfers: [ObjectIdentifier: Transfer] = [:]
    @ObservationIgnored private var invitationReplies: [UUID: InvitationReply] = [:]

    init(notices: NoticeCenter) {
        self.notices = notices
        let name = LocalIdentity.displayName()
        let peerID = LocalIdentity.peerID(for: name)
        localDisplayName = name
        myPeerID = peerID
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        super.init()
        browser.delegate = self
    }

    // MARK: Lifecycle

    func start() {
        guard !isDiscovering else { return }
        if advertiser == nil { rebuildAdvertiser() }
        advertiser?.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        isDiscovering = true
        p2pLog.info("Discovery started as \(self.localDisplayName, privacy: .public) (\(self.localDevice, privacy: .public))")
        Task {
            let device = await MachineInfo.modelName()
            if device != localDevice { updateDevice(device) }
        }
    }

    func stop() {
        guard isDiscovering else { return }
        advertiser?.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        isDiscovering = false
    }

    func shutdown() {
        stop()
        for offer in offers where offer.phase == .pending { decline(offer) }
        for transfer in transfers.values { transfer.session.disconnect() }
        transfers.removeAll()
    }

    private func rebuildAdvertiser() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        let adv = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: ["device": localDevice], serviceType: Self.serviceType)
        adv.delegate = self
        advertiser = adv
    }

    private func updateDevice(_ device: String) {
        localDevice = device
        rebuildAdvertiser()
        if isDiscovering { advertiser?.startAdvertisingPeer() }
    }

    func updateDisplayName(_ raw: String) {
        let name = LocalIdentity.sanitize(raw)
        guard name != localDisplayName else { return }
        let wasDiscovering = isDiscovering
        shutdown()
        LocalIdentity.saveDisplayName(name)
        localDisplayName = name
        myPeerID = LocalIdentity.peerID(for: name)
        browser.delegate = nil
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        browser.delegate = self
        advertiser = nil
        peers.removeAll()
        if wasDiscovering { start() }
    }

    // MARK: Sending

    func send(_ share: ShareSummary, extras: [ShareSummary] = [], to peerID: MCPeerID) {
        if let current = outgoing, current.phase == .waiting || current.phase == .sending { return }
        let extras = Array(extras.prefix(WireEnvelope.maxExtraShares))
        let session = makeSession()
        transfers[ObjectIdentifier(session)] = Transfer(session: session, peerID: peerID, role: .sending(share), startedAt: Date(), extras: extras)
        outgoing = OutgoingTransfer(shareID: share.id, peerID: peerID, phase: .waiting, startedAt: Date())
        var preview = share.preview
        if !extras.isEmpty { preview.tabTitles = ([share] + extras).map { String($0.title.prefix(60)) } }
        browser.invitePeer(peerID, to: session, withContext: WireCodec.encodePreview(preview), timeout: Self.invitationTimeout)
        p2pLog.info("Offered \"\(share.title, privacy: .public)\" to \(peerID.displayName, privacy: .public)")
    }

    func cancelSend() {
        guard let outgoing else { return }
        for (key, transfer) in transfers where transfer.peerID == outgoing.peerID {
            if case .sending = transfer.role {
                transfer.session.disconnect()
                transfers[key] = nil
            }
        }
        self.outgoing = nil
    }

    func clearOutgoing() { outgoing = nil }

    // MARK: Receiving

    func decline(_ offer: IncomingOffer) {
        offers.removeAll { $0.id == offer.id }
        invitationReplies.removeValue(forKey: offer.id)?.handler(false, nil)
        p2pLog.info("Declined offer from \(offer.senderName, privacy: .public)")
    }

    /// Accepts the invitation; the share arrives over the new session. `open` = Continue (vs Save for Later).
    func accept(_ offer: IncomingOffer, open: Bool) {
        guard let reply = invitationReplies.removeValue(forKey: offer.id),
              let index = offers.firstIndex(where: { $0.id == offer.id }) else { return }
        let session = makeSession()
        transfers[ObjectIdentifier(session)] = Transfer(session: session, peerID: offer.peerID, role: .receiving(offerID: offer.id, open: open), startedAt: Date())
        offers[index].phase = .receiving(open: open)
        reply.handler(true, session)
        p2pLog.info("Accepted offer from \(offer.senderName, privacy: .public)")

        // Never sit on "Receiving…" forever: give up if nothing arrived.
        let key = ObjectIdentifier(session)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.receiveTimeout))
            guard let self, let transfer = self.transfers[key], !transfer.completed else { return }
            p2pLog.error("Timed out receiving from \(offer.senderName, privacy: .public)")
            self.transfers[key] = nil
            transfer.session.disconnect()
            if let i = self.offers.firstIndex(where: { $0.id == offer.id }) { self.offers[i].phase = .failed }
            self.notices.text = "\(offer.senderName)’s chat didn’t arrive. Make sure you’re both on the same Wi-Fi (or Bluetooth is on) and ask them to send it again."
        }
    }

    func markSeen(_ offer: IncomingOffer) {
        if let i = offers.firstIndex(where: { $0.id == offer.id }) { offers[i].seen = true }
    }

    func dismissFailedOffer(_ offer: IncomingOffer) {
        offers.removeAll { $0.id == offer.id }
    }

    // MARK: Delegate handlers (main actor)

    fileprivate func handleFound(_ peerID: MCPeerID, info: [String: String]?) {
        guard peerID != myPeerID else { return }
        // Equal display names do not imply that two discovered Macs are the same peer.
        let device = String((info?["device"] ?? "Mac").prefix(40))
        if let i = peers.firstIndex(where: { $0.peerID == peerID }) {
            peers[i].isNearby = true
            peers[i].device = device
        } else {
            peers.append(NearbyPeer(peerID: peerID, device: device, isNearby: true))
        }
        p2pLog.info("Found \(peerID.displayName, privacy: .public) (\(device, privacy: .public))")
    }

    fileprivate func handleLost(_ peerID: MCPeerID) {
        if let i = peers.firstIndex(where: { $0.peerID == peerID }) { peers[i].isNearby = false }
    }

    fileprivate func handleInvitation(from peerID: MCPeerID, context: Data?, reply: InvitationReply) {
        // Room invitations carry a different context; everything else is a share offer, as before.
        if let invitation = RoomCodec.decodeInvitation(context) {
            if let onRoomInvitation {
                onRoomInvitation(invitation, peerID, reply)
            } else {
                reply.handler(false, nil)
            }
            return
        }
        guard let preview = WireCodec.decodePreview(context) else {
            p2pLog.error("Rejected invitation without a valid preview from \(peerID.displayName, privacy: .public)")
            reply.handler(false, nil)
            return
        }
        for old in offers where old.peerID == peerID && old.phase == .pending { decline(old) }
        let offer = IncomingOffer(id: UUID(), peerID: peerID, preview: preview, receivedAt: Date())
        offers.insert(offer, at: 0)
        invitationReplies[offer.id] = reply
        p2pLog.info("Offer \"\(preview.title, privacy: .public)\" from \(peerID.displayName, privacy: .public)")
        onOfferArrived?(offer)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.invitationTimeout - 2))
            guard let self, let current = self.offers.first(where: { $0.id == offer.id }), current.phase == .pending else { return }
            self.decline(current)
        }
    }

    fileprivate func handleStateChange(_ state: MCSessionState, session: MCSession) {
        let key = ObjectIdentifier(session)
        guard let transfer = transfers[key] else { return }
        switch state {
        case .connected:
            p2pLog.info("Connected to \(transfer.peerID.displayName, privacy: .public)")
            if case .sending(let share) = transfer.role {
                outgoing?.phase = .sending
                do {
                    let envelope = WireEnvelope(kind: .share, share: share, shares: transfer.extras.isEmpty ? nil : transfer.extras)
                    let data = try WireCodec.encode(envelope)
                    guard data.count <= WireCodec.maxPayloadBytes else { throw WireError.payloadTooLarge(data.count) }
                    try session.send(data, toPeers: [transfer.peerID], with: .reliable)
                } catch {
                    p2pLog.error("Send failed: \(error.localizedDescription, privacy: .public)")
                    finishSending(key, phase: .failed)
                }
            }
        case .notConnected:
            guard !transfer.completed else { transfers[key] = nil; return }
            switch transfer.role {
            case .sending:
                // MPC has no explicit "declined": a prompt drop before connecting means the user declined.
                let elapsed = Date().timeIntervalSince(transfer.startedAt)
                let declined = outgoing?.phase == .waiting && elapsed < Self.invitationTimeout - 3
                finishSending(key, phase: declined ? .declined : .failed)
            case .receiving(let offerID, _):
                transfers[key] = nil
                if let i = offers.firstIndex(where: { $0.id == offerID }) { offers[i].phase = .failed }
                notices.text = "Couldn't receive the chat from \(transfer.peerID.displayName). Ask them to send it again."
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    fileprivate func handleData(_ data: Data, session: MCSession) {
        let key = ObjectIdentifier(session)
        guard let transfer = transfers[key] else { return }
        do {
            let envelope = try WireCodec.decode(data)
            switch (envelope.kind, transfer.role) {
            case (.share, .receiving(let offerID, let open)):
                guard let share = envelope.share,
                      let offer = offers.first(where: { $0.id == offerID }),
                      share.id == offer.preview.id else { throw WireError.invalidContent }
                let ack = try WireCodec.encode(WireEnvelope(kind: .ack, ackID: share.id))
                try? session.send(ack, toPeers: [transfer.peerID], with: .reliable)
                transfers[key]?.completed = true
                offers.removeAll { $0.id == offerID }
                p2pLog.info("Received \"\(share.title, privacy: .public)\" from \(transfer.peerID.displayName, privacy: .public)")
                onShareReceived?([share] + (envelope.shares ?? []), open)
                closeLater(session)
            case (.ack, .sending(let share)) where envelope.ackID == share.id:
                p2pLog.info("Delivered to \(transfer.peerID.displayName, privacy: .public)")
                finishSending(key, phase: .delivered)
            default:
                throw WireError.missingPayload
            }
        } catch {
            p2pLog.error("Ignored invalid payload from \(transfer.peerID.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
            notices.text = "Ignored an unreadable message from \(transfer.peerID.displayName)."
        }
    }

    fileprivate func handleStartFailure(_ what: String, _ error: Error) {
        isDiscovering = false
        p2pLog.error("\(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        notices.text = "Couldn't start \(what). Check System Settings › Privacy & Security › Local Network."
    }

    // MARK: Rooms (used by RoomService)

    /// A session for the local peer with no delegate set; the caller owns it and its callbacks.
    func makeUnownedSession() -> MCSession {
        MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
    }

    /// Invites a nearby peer into a session owned by someone else (a room).
    func invite(_ peerID: MCPeerID, to session: MCSession, context: Data, timeout: TimeInterval = 60) {
        browser.invitePeer(peerID, to: session, withContext: context, timeout: timeout)
    }

    // MARK: Helpers

    private func makeSession() -> MCSession {
        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    private func finishSending(_ key: ObjectIdentifier, phase: OutgoingTransfer.Phase) {
        guard let transfer = transfers[key] else { return }
        transfers[key]?.completed = true
        if outgoing?.peerID == transfer.peerID { outgoing?.phase = phase }
        closeLater(transfer.session)
    }

    private func closeLater(_ session: MCSession) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            session.disconnect()
            self?.transfers[ObjectIdentifier(session)] = nil
        }
    }

    fileprivate func owns(_ session: MCSession) -> Bool { transfers[ObjectIdentifier(session)] != nil }
    fileprivate func isCurrent(advertiser other: MCNearbyServiceAdvertiser) -> Bool { other === advertiser }
    fileprivate func isCurrent(browser other: MCNearbyServiceBrowser) -> Bool { other === browser }
}

/// MPC's invitation handler isn't Sendable; it is safe to call from any thread.
struct InvitationReply: @unchecked Sendable {
    let handler: (Bool, MCSession?) -> Void
}

// MARK: - Delegates (nonisolated → main actor)

extension PeerService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.handleStateChange(state, session: session) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.handleData(data, session: session) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PeerService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let reply = InvitationReply(handler: invitationHandler)
        Task { @MainActor in
            guard self.isCurrent(advertiser: advertiser) else { reply.handler(false, nil); return }
            self.handleInvitation(from: peerID, context: context, reply: reply)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.handleStartFailure("advertising", error) }
    }
}

extension PeerService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard self.isCurrent(browser: browser) else { return }
            self.handleFound(peerID, info: info)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard self.isCurrent(browser: browser) else { return }
            self.handleLost(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.handleStartFailure("browsing", error) }
    }
}

// MARK: - Local identity persistence

/// Persists the display name and a stable MCPeerID per name (prevents ghost peers on other Macs).
/// `-ContextDrop.displayName <name>` on the command line overrides it, for two instances on one Mac.
enum LocalIdentity {
    private static let displayNameKey = "ContextDrop.displayName"
    private static var defaults: UserDefaults { .standard }

    /// Stable installation identity; changing the visible name never changes room ownership.
    static var memberID: String {
        let key = "ContextDrop.memberID"
        if let id = defaults.string(forKey: key), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }

    static func displayName() -> String {
        sanitize(defaults.string(forKey: displayNameKey) ?? "")
    }

    static func saveDisplayName(_ name: String) {
        defaults.set(name, forKey: displayNameKey)
    }

    /// MCPeerID requires a non-empty name of at most 63 UTF-8 bytes.
    static func sanitize(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = NSFullUserName().split(separator: " ").first.map(String.init) ?? "" }
        if name.isEmpty { name = Host.current().localizedName ?? "Mac" }
        if name.isEmpty { name = "Mac" }
        while name.utf8.count > 63 { name.removeLast() }
        return name
    }

    static func peerID(for name: String) -> MCPeerID {
        let key = "ContextDrop.peerID.\(name)"
        if let data = defaults.data(forKey: key),
           let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           stored.displayName == name {
            return stored
        }
        let peerID = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: peerID, requiringSecureCoding: true) {
            defaults.set(data, forKey: key)
        }
        return peerID
    }
}
