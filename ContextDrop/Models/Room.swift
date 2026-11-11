import CoreGraphics
import Foundation

/// Hard limits for everything in a room. Applied to local input and to everything decoded from the network.
enum RoomLimits {
    static let maxTextLength = 8_000
    static let maxCards = 300
    static let maxMembers = 16
    static let maxNameLength = 63
    static let maxRoomNameLength = 60
    static let maxCaptionLength = 120
    static let maxTitleLength = 80
    static let maxQuestionLength = 400
    static let canvasWidth: Double = 4_000
    static let canvasHeight: Double = 3_000
    static let maxPayloadBytes = 4 * 1024 * 1024
    static let maxInvitationBytes = 2 * 1024
    /// How far ahead of our clock a remote timestamp may be before it is pulled back.
    static let maxClockSkew: TimeInterval = 2

    static func clampX(_ x: Double) -> Double { x.isFinite ? min(max(x, 0), canvasWidth - 60) : 0 }
    static func clampY(_ y: Double) -> Double { y.isFinite ? min(max(y, 0), canvasHeight - 60) : 0 }
    static func clampStamp(_ stamp: Date) -> Date { min(stamp, Date().addingTimeInterval(maxClockSkew)) }
}

/// One card on the table. `x`/`y` are the top-left corner in unscaled canvas points.
struct RoomCard: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case thought, keptAnswer, note

        var label: String {
            switch self {
            case .thought: "Thought"
            case .keptAnswer: "Kept answer"
            case .note: "Note"
            }
        }
    }

    let id: UUID
    var kind: Kind
    var text: String
    var authorName: String
    var x: Double
    var y: Double
    /// Last text change (last-write-wins for edits).
    var updatedAt: Date
    /// Last position change (last-write-wins for moves). Older builds may omit it.
    var movedAt: Date?
    /// Small provenance line, e.g. "OpenAI · run by Aymeric".
    var caption: String?
    /// Replaces the kind label, e.g. "AI answer".
    var title: String?
    /// The question an AI answer responds to.
    var question: String?

    var position: CGPoint { CGPoint(x: x, y: y) }
    var isAIAnswer: Bool { title != nil && question != nil }
    var displayLabel: String { title ?? kind.label }

    /// A copy that respects every limit. Never fails: oversized fields are cut, bad numbers are reset.
    func sanitized() -> RoomCard {
        var card = self
        card.text = String(text.prefix(RoomLimits.maxTextLength))
        card.authorName = String(authorName.prefix(RoomLimits.maxNameLength))
        card.x = RoomLimits.clampX(x)
        card.y = RoomLimits.clampY(y)
        card.updatedAt = RoomLimits.clampStamp(updatedAt)
        card.movedAt = movedAt.map(RoomLimits.clampStamp)
        card.caption = caption.map { String($0.prefix(RoomLimits.maxCaptionLength)) }
        card.title = title.map { String($0.prefix(RoomLimits.maxTitleLength)) }
        card.question = question.map { String($0.prefix(RoomLimits.maxQuestionLength)) }
        return card
    }
}

/// Someone at the table. `id` is the peer's display name (unique enough for a hackathon room).
struct RoomMember: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var isHost: Bool

    func sanitized() -> RoomMember {
        RoomMember(id: String(id.prefix(RoomLimits.maxNameLength)), name: String(name.prefix(RoomLimits.maxNameLength)), isHost: isHost)
    }
}

struct RoomState: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var hostName: String
    var members: [RoomMember]
    var cards: [RoomCard]

    func sanitized() -> RoomState {
        var seenMembers = Set<String>()
        var seenCards = Set<UUID>()
        return RoomState(
            id: id,
            name: String(name.prefix(RoomLimits.maxRoomNameLength)),
            hostName: String(hostName.prefix(RoomLimits.maxNameLength)),
            members: members.prefix(RoomLimits.maxMembers).map { $0.sanitized() }.filter { !$0.id.isEmpty && seenMembers.insert($0.id).inserted },
            cards: cards.prefix(RoomLimits.maxCards).map { $0.sanitized() }.filter { seenCards.insert($0.id).inserted })
    }
}

/// What a nearby Mac sees before joining. `id` is the room's id.
struct RoomInvitation: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var hostName: String
    var memberCount: Int

    func sanitized() -> RoomInvitation {
        RoomInvitation(id: id,
                       name: String(name.prefix(RoomLimits.maxRoomNameLength)),
                       hostName: String(hostName.prefix(RoomLimits.maxNameLength)),
                       memberCount: min(max(memberCount, 1), RoomLimits.maxMembers))
    }
}

/// Invitation context on the wire: `{"room": {...}}`. The `room` key is what tells it apart from a share preview.
struct RoomInvitationContext: Codable, Sendable {
    let room: RoomInvitation
}

/// One JSON message per `send` on the room session.
struct RoomMessage: Codable, Sendable {
    static let currentVersion = 1

    enum Kind: String, Codable, Sendable {
        case hello, snapshot, addCard, moveCard, editCard, removeCard, memberLeft, ended
    }

    var version = RoomMessage.currentVersion
    let kind: Kind
    var member: RoomMember?
    var state: RoomState?
    var card: RoomCard?
    var cardID: UUID?
    var x: Double?
    var y: Double?
    var text: String?
    var stamp: Date?
    var memberID: String?

    static func hello(_ member: RoomMember) -> RoomMessage { RoomMessage(kind: .hello, member: member) }
    static func snapshot(_ state: RoomState) -> RoomMessage { RoomMessage(kind: .snapshot, state: state) }
    static func addCard(_ card: RoomCard) -> RoomMessage { RoomMessage(kind: .addCard, card: card) }
    static func moveCard(_ id: UUID, x: Double, y: Double, stamp: Date) -> RoomMessage {
        RoomMessage(kind: .moveCard, cardID: id, x: x, y: y, stamp: stamp)
    }
    static func editCard(_ id: UUID, text: String, stamp: Date) -> RoomMessage {
        RoomMessage(kind: .editCard, cardID: id, text: text, stamp: stamp)
    }
    static func removeCard(_ id: UUID) -> RoomMessage { RoomMessage(kind: .removeCard, cardID: id) }
    static func memberLeft(_ id: String) -> RoomMessage { RoomMessage(kind: .memberLeft, memberID: id) }
    static let ended = RoomMessage(kind: .ended)
}

enum RoomWireError: Error, CustomStringConvertible {
    case payloadTooLarge(Int)
    case unsupportedVersion(Int)
    case missingPayload(RoomMessage.Kind)

    var description: String {
        switch self {
        case .payloadTooLarge(let bytes): "payload too large (\(bytes) bytes)"
        case .unsupportedVersion(let version): "unsupported room protocol version \(version)"
        case .missingPayload(let kind): "missing payload for \(kind.rawValue)"
        }
    }
}

enum RoomCodec {
    static func encode(_ message: RoomMessage) throws -> Data {
        try JSONEncoder().encode(message)
    }

    /// Decodes, validates and size-limits. Throws on anything malformed; never traps.
    static func decode(_ data: Data) throws -> RoomMessage {
        guard data.count <= RoomLimits.maxPayloadBytes else { throw RoomWireError.payloadTooLarge(data.count) }
        var message = try JSONDecoder().decode(RoomMessage.self, from: data)
        guard message.version == RoomMessage.currentVersion else { throw RoomWireError.unsupportedVersion(message.version) }
        let missing = RoomWireError.missingPayload(message.kind)
        switch message.kind {
        case .hello:
            guard let member = message.member?.sanitized(), !member.id.isEmpty else { throw missing }
            message.member = member
        case .snapshot:
            guard let state = message.state else { throw missing }
            message.state = state.sanitized()
        case .addCard:
            guard let card = message.card else { throw missing }
            message.card = card.sanitized()
        case .moveCard:
            guard message.cardID != nil, let x = message.x, let y = message.y, let stamp = message.stamp else { throw missing }
            message.x = RoomLimits.clampX(x)
            message.y = RoomLimits.clampY(y)
            message.stamp = RoomLimits.clampStamp(stamp)
        case .editCard:
            guard message.cardID != nil, let text = message.text, let stamp = message.stamp else { throw missing }
            message.text = String(text.prefix(RoomLimits.maxTextLength))
            message.stamp = RoomLimits.clampStamp(stamp)
        case .removeCard:
            guard message.cardID != nil else { throw missing }
        case .memberLeft:
            guard let id = message.memberID, !id.isEmpty else { throw missing }
            message.memberID = String(id.prefix(RoomLimits.maxNameLength))
        case .ended:
            break
        }
        return message
    }

    static func encodeInvitation(_ invitation: RoomInvitation) -> Data? {
        try? JSONEncoder().encode(RoomInvitationContext(room: invitation.sanitized()))
    }

    /// Nil for anything that is not a room invitation (including share previews, which have no `room` key).
    static func decodeInvitation(_ data: Data?) -> RoomInvitation? {
        guard let data, data.count <= RoomLimits.maxInvitationBytes,
              let context = try? JSONDecoder().decode(RoomInvitationContext.self, from: data) else { return nil }
        return context.room.sanitized()
    }
}
