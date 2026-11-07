import Foundation

/// Versioned wire format for the Multipeer session. One JSON envelope per `send`.
struct WireEnvelope: Codable, Sendable {
    static let currentVersion = 1

    enum Kind: String, Codable, Sendable {
        case share
        case ack
    }

    var version = WireEnvelope.currentVersion
    let kind: Kind
    var share: ShareSummary?
    var ackID: UUID?
}

enum WireError: Error, CustomStringConvertible {
    case payloadTooLarge(Int)
    case unsupportedVersion(Int)
    case missingPayload
    case invalidContent

    var description: String {
        switch self {
        case .payloadTooLarge(let bytes): "payload too large (\(bytes) bytes)"
        case .unsupportedVersion(let v): "unsupported protocol version \(v)"
        case .missingPayload: "missing payload"
        case .invalidContent: "invalid share contents"
        }
    }
}

enum WireCodec {
    static let maxPayloadBytes = 512 * 1024
    static let maxInvitationContextBytes = 6 * 1024

    static func encode(_ envelope: WireEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    /// Decodes and validates. Throws on anything malformed; never traps.
    static func decode(_ data: Data) throws -> WireEnvelope {
        guard data.count <= maxPayloadBytes else { throw WireError.payloadTooLarge(data.count) }
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        guard envelope.version == WireEnvelope.currentVersion else { throw WireError.unsupportedVersion(envelope.version) }
        switch envelope.kind {
        case .share:
            guard let share = envelope.share else { throw WireError.missingPayload }
            guard share.isValid else { throw WireError.invalidContent }
        case .ack:
            guard envelope.ackID != nil else { throw WireError.missingPayload }
        }
        return envelope
    }

    static func encodePreview(_ preview: SharePreview) -> Data? {
        var preview = preview
        if let data = try? JSONEncoder().encode(preview), data.count <= maxInvitationContextBytes { return data }
        preview.summary = String(preview.summary.prefix(200)) + "…"
        preview.openQuestions = Array(preview.openQuestions.prefix(1))
        return try? JSONEncoder().encode(preview)
    }

    static func decodePreview(_ data: Data?) -> SharePreview? {
        guard let data, data.count <= maxInvitationContextBytes else { return nil }
        return try? JSONDecoder().decode(SharePreview.self, from: data)
    }
}
