import CoreGraphics
import Foundation

/// Hard limits for everything in a room. Applied to local input and to everything decoded from the network.
enum RoomLimits {
    static let maxTextLength = 8_000
    static let maxTiles = 300
    static let maxMembers = 16
    static let maxNameLength = 63
    static let maxRoomNameLength = 60
    static let maxCaptionLength = 120
    static let maxTitleLength = 80
    static let maxQuestionLength = 4_000
    static let maxChatMessages = 200
    static let maxFilesPerChat = 24
    static let maxFileNameLength = 120
    static let maxFileBytes = 20 * 1024 * 1024
    static let maxThumbnailBytes = 24 * 1024
    static let maxRunsPerChat = 6
    static let maxSpawnSources = 12
    static let maxPlanSteps = 30
    static let maxSubagents = 12
    static let maxChanges = 40
    /// Log lines carried in one run update. The tile shows the last 6; "Watch" keeps what it has seen.
    static let maxLogLines = 40
    static let maxLogLineLength = 240
    static let maxRunNotes = 20
    static let maxNoteLength = 400
    /// The canvas has no edges; this only keeps numbers sane.
    static let coordinateLimit: Double = 1_000_000
    static let maxPayloadBytes = 16 * 1024 * 1024
    static let maxInvitationBytes = 2 * 1024
    /// How far ahead of our clock a remote timestamp may be before it is pulled back.
    static let maxClockSkew: TimeInterval = 2

    static func clampCoordinate(_ v: Double) -> Double { v.isFinite ? min(max(v, -coordinateLimit), coordinateLimit) : 0 }
    static func clampStamp(_ stamp: Date) -> Date { min(stamp, Date().addingTimeInterval(maxClockSkew)) }
    static func name(_ raw: String) -> String { String(raw.prefix(maxNameLength)) }
}

// MARK: - Cards (thought, kept answer, note)

struct RoomCardBody: Codable, Sendable, Equatable {
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

    var kind: Kind
    var text: String
    /// Small provenance line, e.g. the title of the chat a kept answer came from.
    var caption: String?

    func sanitized() -> RoomCardBody {
        RoomCardBody(kind: kind, text: String(text.prefix(RoomLimits.maxTextLength)),
                     caption: caption.map { String($0.prefix(RoomLimits.maxCaptionLength)) })
    }
}

// MARK: - Chat tiles

/// A file that belongs to a chat tile. The bytes live only on the chat owner's Mac (and at OpenAI under the
/// owner's key); everyone else gets this description and a small thumbnail.
struct RoomFile: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case image, pdf, text, document, other }

    enum Status: Codable, Sendable, Equatable {
        /// On its way to the owner's Mac, or being uploaded there.
        case sending
        case ready
        /// The chat's model can't take this kind of file; the associated value is a model that can.
        case unsupported(String)
        case failed(String)

        func sanitized() -> Status {
            switch self {
            case .unsupported(let model): .unsupported(String(model.prefix(40)))
            case .failed(let reason): .failed(String(reason.prefix(160)))
            default: self
            }
        }
    }

    let id: UUID
    var name: String
    var kind: Kind
    var size: Int
    var addedBy: String
    /// A small JPEG for the file strip (images only).
    var thumbnail: Data?
    var status: Status

    func sanitized() -> RoomFile {
        RoomFile(id: id,
                 name: String(name.prefix(RoomLimits.maxFileNameLength)),
                 kind: kind,
                 size: min(max(size, 0), RoomLimits.maxFileBytes),
                 addedBy: RoomLimits.name(addedBy),
                 thumbnail: (thumbnail?.count ?? 0) <= RoomLimits.maxThumbnailBytes ? thumbnail : nil,
                 status: status.sanitized())
    }
}

struct RoomChatMessage: Codable, Sendable, Equatable, Identifiable {
    /// `event` is a line such as "Camille added notes.pdf".
    enum Kind: String, Codable, Sendable { case user, assistant, event }

    let id: UUID
    var kind: Kind
    var author: String
    var text: String
    /// Assistant replies: the files the model was given for this answer.
    var sawFiles: [String] = []
    /// Assistant replies: also read the progress of a Claude Code run.
    var sawRuns = false
    var streaming = false
    var failed = false
    var createdAt = Date()

    func sanitized() -> RoomChatMessage {
        var m = self
        m.author = RoomLimits.name(author)
        m.text = String(text.prefix(RoomLimits.maxTextLength))
        m.sawFiles = sawFiles.prefix(RoomLimits.maxFilesPerChat).map { String($0.prefix(RoomLimits.maxFileNameLength)) }
        m.createdAt = RoomLimits.clampStamp(createdAt)
        return m
    }
}

/// A live conversation on the canvas. It runs on `ownerName`'s Mac with their OpenAI key.
struct RoomChatTile: Codable, Sendable, Equatable {
    var title: String
    var ownerName: String
    /// The owner's OpenAI model, for display.
    var model: String
    var messages: [RoomChatMessage] = []
    var files: [RoomFile] = []
    /// Claude Code run tiles given to this chat as context.
    var runIDs: [UUID] = []
    var spawnedFrom: [UUID] = []
    /// What it started from, in words ("pane chat", "thought"), so the labels survive their tiles.
    var spawnedLabels: [String] = []

    var lastReply: RoomChatMessage? { messages.last { $0.kind == .assistant } }
    var isStreaming: Bool { messages.contains { $0.streaming } }

    /// What was said, one line per message ("Name: text"), without event lines or replies that failed.
    var transcript: String {
        messages.filter { $0.kind != .event && !$0.text.isEmpty && !$0.failed }
            .map { "\($0.author): \($0.text)" }.joined(separator: "\n")
    }

    /// Nothing streams any more (the room ended, or the owner left).
    mutating func stopStreaming() {
        for i in messages.indices where messages[i].streaming { messages[i].streaming = false }
    }

    func sanitized() -> RoomChatTile {
        var seenMessages = Set<UUID>(), seenFiles = Set<UUID>()
        var t = self
        t.title = String(title.prefix(RoomLimits.maxTitleLength))
        t.ownerName = RoomLimits.name(ownerName)
        t.model = String(model.prefix(60))
        t.messages = messages.suffix(RoomLimits.maxChatMessages).map { $0.sanitized() }.filter { seenMessages.insert($0.id).inserted }
        t.files = files.prefix(RoomLimits.maxFilesPerChat).map { $0.sanitized() }.filter { seenFiles.insert($0.id).inserted }
        t.runIDs = Array(runIDs.prefix(RoomLimits.maxRunsPerChat))
        t.spawnedFrom = Array(spawnedFrom.prefix(RoomLimits.maxSpawnSources))
        t.spawnedLabels = spawnedLabels.prefix(RoomLimits.maxSpawnSources).map { String($0.prefix(40)) }
        return t
    }
}

// MARK: - Claude Code run tiles

struct RunPlanStep: Codable, Sendable, Equatable, Hashable {
    enum Status: String, Codable, Sendable { case pending, active, done }
    var text: String
    var status: Status
}

struct RunSubagentInfo: Codable, Sendable, Equatable, Hashable {
    var type: String
    var task: String
    var running: Bool
}

struct RunChangeInfo: Codable, Sendable, Equatable, Hashable {
    var path: String
    var added: Int
    var removed: Int
}

struct RunLogLine: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Position in the owner's log, so watchers can stitch updates together.
    var seq: Int
    var text: String
    var id: Int { seq }
}

struct RunNote: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var from: String
    var text: String
}

/// A Claude Code run someone put in the room. It stays on `ownerName`'s Mac; the room only gets these summaries.
struct RoomRunTile: Codable, Sendable, Equatable {
    enum State: Codable, Sendable, Equatable {
        case running
        /// Stopped until its owner does something; the associated value says what.
        case waiting(String)
        case done
        case failed
    }

    var ownerName: String
    var title: String
    var folder: String
    var state: State = .running
    var startedAt: Date?
    var endedAt: Date?
    var plan: [RunPlanStep] = []
    var subagents: [RunSubagentInfo] = []
    var changes: [RunChangeInfo] = []
    var log: [RunLogLine] = []
    /// Notes people sent the owner ("Ask Camille…").
    var notes: [RunNote] = []
    /// The run's final answer, once done.
    var summary: String?

    var isLive: Bool {
        switch state {
        case .running, .waiting: true
        case .done, .failed: false
        }
    }

    var planDone: Int { plan.filter { $0.status == .done }.count }
    var added: Int { changes.reduce(0) { $0 + $1.added } }
    var removed: Int { changes.reduce(0) { $0 + $1.removed } }

    /// What a chat is told about this run when it is used as context.
    var contextText: String {
        var lines = ["Claude Code run \"\(title)\" on \(ownerName)'s Mac."]
        switch state {
        case .running: lines.append("Status: running.")
        case .waiting(let reason): lines.append("Status: paused. \(reason)")
        case .done: lines.append("Status: finished.")
        case .failed: lines.append("Status: stopped with an error.")
        }
        if !plan.isEmpty {
            lines.append("Plan (\(planDone) of \(plan.count) done):")
            for step in plan {
                let mark = step.status == .done ? "[x]" : step.status == .active ? "[>]" : "[ ]"
                lines.append("\(mark) \(step.text)")
            }
        }
        if !changes.isEmpty {
            lines.append("Files changed:")
            for change in changes { lines.append("\(change.path) +\(change.added) -\(change.removed)") }
        }
        if let summary, !summary.isEmpty { lines.append("Final summary: \(summary)") }
        return lines.joined(separator: "\n")
    }

    func sanitized() -> RoomRunTile {
        var t = self
        t.ownerName = RoomLimits.name(ownerName)
        t.title = String(title.prefix(RoomLimits.maxTitleLength))
        t.folder = String(folder.prefix(120))
        if case .waiting(let reason) = state { t.state = .waiting(String(reason.prefix(200))) }
        t.startedAt = startedAt.map(RoomLimits.clampStamp)
        t.endedAt = endedAt.map(RoomLimits.clampStamp)
        t.plan = plan.prefix(RoomLimits.maxPlanSteps).map { RunPlanStep(text: String($0.text.prefix(160)), status: $0.status) }
        t.subagents = subagents.prefix(RoomLimits.maxSubagents).map {
            RunSubagentInfo(type: String($0.type.prefix(40)), task: String($0.task.prefix(120)), running: $0.running)
        }
        t.changes = changes.prefix(RoomLimits.maxChanges).map {
            RunChangeInfo(path: String($0.path.suffix(160)), added: min(max($0.added, 0), 1_000_000), removed: min(max($0.removed, 0), 1_000_000))
        }
        t.log = log.suffix(RoomLimits.maxLogLines).map { RunLogLine(seq: $0.seq, text: String($0.text.prefix(RoomLimits.maxLogLineLength))) }
        t.notes = notes.suffix(RoomLimits.maxRunNotes).map { $0.sanitized() }
        t.summary = summary.map { String($0.prefix(RoomLimits.maxTextLength)) }
        return t
    }
}

extension RunNote {
    func sanitized() -> RunNote {
        RunNote(id: id, from: RoomLimits.name(from), text: String(text.prefix(RoomLimits.maxNoteLength)))
    }
}

// MARK: - Tiles

enum RoomTileContent: Codable, Sendable, Equatable {
    case card(RoomCardBody)
    case chat(RoomChatTile)
    case run(RoomRunTile)

    func sanitized() -> RoomTileContent {
        switch self {
        case .card(let body): .card(body.sanitized())
        case .chat(let chat): .chat(chat.sanitized())
        case .run(let run): .run(run.sanitized())
        }
    }
}

/// One thing on the canvas. `x`/`y` are the top-left corner in unscaled canvas points; the canvas has no edges.
struct RoomTile: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var x: Double
    var y: Double
    var addedBy: String
    var collapsed = false
    /// Last position change (last-write-wins for moves).
    var movedAt: Date
    /// Last text or collapse change (last-write-wins).
    var updatedAt: Date
    var content: RoomTileContent

    var position: CGPoint { CGPoint(x: x, y: y) }

    var card: RoomCardBody? { if case .card(let body) = content { body } else { nil } }
    var chat: RoomChatTile? { if case .chat(let chat) = content { chat } else { nil } }
    var run: RoomRunTile? { if case .run(let run) = content { run } else { nil } }

    /// Whose Mac does the work behind this tile (chats and runs), or who wrote it (cards).
    var ownerName: String {
        switch content {
        case .card: addedBy
        case .chat(let chat): chat.ownerName
        case .run(let run): run.ownerName
        }
    }

    /// Short label for selection chips and "started from" lists.
    var shortLabel: String {
        switch content {
        case .card(let body): body.kind.label.lowercased()
        case .chat(let chat): chat.title.isEmpty ? "chat" : String(chat.title.prefix(24))
        case .run(let run): run.title.isEmpty ? "run" : String(run.title.prefix(24))
        }
    }

    /// The tile as plain text, for a model's context (spawned chats, take-home, summaries).
    func contextText(limit: Int) -> String {
        switch content {
        case .card(let body): String(body.text.prefix(limit))
        case .chat(let chat): String(chat.transcript.suffix(limit))
        case .run(let run): String(run.contextText.prefix(limit))
        }
    }

    func sanitized() -> RoomTile {
        RoomTile(id: id,
                 x: RoomLimits.clampCoordinate(x),
                 y: RoomLimits.clampCoordinate(y),
                 addedBy: RoomLimits.name(addedBy),
                 collapsed: collapsed,
                 movedAt: RoomLimits.clampStamp(movedAt),
                 updatedAt: RoomLimits.clampStamp(updatedAt),
                 content: content.sanitized())
    }
}

/// Someone at the table. `id` is the peer's display name (unique enough for a hackathon room).
struct RoomMember: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var isHost: Bool

    func sanitized() -> RoomMember {
        RoomMember(id: RoomLimits.name(id), name: RoomLimits.name(name), isHost: isHost)
    }
}

struct RoomState: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var hostName: String
    var members: [RoomMember]
    var tiles: [RoomTile]

    func sanitized() -> RoomState {
        var seenMembers = Set<String>()
        var seenTiles = Set<UUID>()
        return RoomState(
            id: id,
            name: String(name.prefix(RoomLimits.maxRoomNameLength)),
            hostName: RoomLimits.name(hostName),
            members: members.prefix(RoomLimits.maxMembers).map { $0.sanitized() }.filter { !$0.id.isEmpty && seenMembers.insert($0.id).inserted },
            tiles: tiles.prefix(RoomLimits.maxTiles).map { $0.sanitized() }.filter { seenTiles.insert($0.id).inserted })
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
                       hostName: RoomLimits.name(hostName),
                       memberCount: min(max(memberCount, 1), RoomLimits.maxMembers))
    }
}

/// Invitation context on the wire: `{"room": {...}}`. The `room` key is what tells it apart from a share preview.
struct RoomInvitationContext: Codable, Sendable {
    let room: RoomInvitation
}

// MARK: - Wire

/// One JSON message per `send` on the room session.
struct RoomMessage: Codable, Sendable {
    static let currentVersion = 2

    enum Kind: String, Codable, Sendable {
        case hello, snapshot, memberLeft, ended
        case addTile, moveTile, editTile, removeTile, setCollapsed
        case chatMessage, chatDelta
        case addFile, fileStatus, removeFile, requestFiles
        case attachRun, runUpdate, runNote
    }

    var version = RoomMessage.currentVersion
    let kind: Kind
    /// Who made the change. Stamped by the host from the peer's name, never taken from the sender's word.
    var from: String?
    var member: RoomMember?
    var state: RoomState?
    var tile: RoomTile?
    var tileID: UUID?
    /// requestFiles: the new chat tile the files should go to.
    var targetTileID: UUID?
    var x: Double?
    var y: Double?
    var text: String?
    var stamp: Date?
    var memberID: String?
    var flag: Bool?
    var chat: RoomChatMessage?
    var messageID: UUID?
    var file: RoomFile?
    var fileID: UUID?
    var fileStatus: RoomFile.Status?
    var runID: UUID?
    var run: RoomRunTile?
    var note: RunNote?

    static func hello(_ member: RoomMember) -> RoomMessage { RoomMessage(kind: .hello, member: member) }
    static func snapshot(_ state: RoomState) -> RoomMessage { RoomMessage(kind: .snapshot, state: state) }
    static func memberLeft(_ id: String) -> RoomMessage { RoomMessage(kind: .memberLeft, memberID: id) }
    static let ended = RoomMessage(kind: .ended)

    static func addTile(_ tile: RoomTile) -> RoomMessage { RoomMessage(kind: .addTile, tile: tile) }
    static func moveTile(_ id: UUID, x: Double, y: Double, stamp: Date) -> RoomMessage {
        RoomMessage(kind: .moveTile, tileID: id, x: x, y: y, stamp: stamp)
    }
    static func editTile(_ id: UUID, text: String, stamp: Date) -> RoomMessage {
        RoomMessage(kind: .editTile, tileID: id, text: text, stamp: stamp)
    }
    static func removeTile(_ id: UUID) -> RoomMessage { RoomMessage(kind: .removeTile, tileID: id) }
    static func setCollapsed(_ id: UUID, _ collapsed: Bool, stamp: Date) -> RoomMessage {
        RoomMessage(kind: .setCollapsed, tileID: id, stamp: stamp, flag: collapsed)
    }

    static func chatMessage(_ tileID: UUID, _ message: RoomChatMessage) -> RoomMessage {
        RoomMessage(kind: .chatMessage, tileID: tileID, chat: message)
    }
    /// The reply as it stands (the whole text so far, not an increment), so a lost or reordered batch
    /// can't corrupt it. `streaming` is false on the last one.
    static func chatDelta(_ tileID: UUID, _ reply: RoomChatMessage) -> RoomMessage {
        RoomMessage(kind: .chatDelta, tileID: tileID, chat: reply)
    }

    static func addFile(_ tileID: UUID, _ file: RoomFile) -> RoomMessage { RoomMessage(kind: .addFile, tileID: tileID, file: file) }
    static func fileStatus(_ tileID: UUID, fileID: UUID, _ status: RoomFile.Status) -> RoomMessage {
        RoomMessage(kind: .fileStatus, tileID: tileID, fileID: fileID, fileStatus: status)
    }
    /// `messageID` names the "x left the chat" line every Mac adds, so it is the same line everywhere.
    static func removeFile(_ tileID: UUID, fileID: UUID, messageID: UUID) -> RoomMessage {
        RoomMessage(kind: .removeFile, tileID: tileID, messageID: messageID, fileID: fileID)
    }
    /// Asks the owner of chat `source` to send its files to the owner of the new chat `target`.
    static func requestFiles(from source: UUID, to target: UUID) -> RoomMessage {
        RoomMessage(kind: .requestFiles, tileID: source, targetTileID: target)
    }

    /// `messageID` names the "run was added" line, as for `removeFile`.
    static func attachRun(_ runID: UUID, to chatID: UUID, messageID: UUID) -> RoomMessage {
        RoomMessage(kind: .attachRun, tileID: chatID, messageID: messageID, runID: runID)
    }
    static func runUpdate(_ tileID: UUID, _ run: RoomRunTile) -> RoomMessage { RoomMessage(kind: .runUpdate, tileID: tileID, run: run) }
    static func runNote(_ tileID: UUID, _ note: RunNote) -> RoomMessage { RoomMessage(kind: .runNote, tileID: tileID, note: note) }
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
        message.from = message.from.map(RoomLimits.name)
        switch message.kind {
        case .hello:
            guard let member = message.member?.sanitized(), !member.id.isEmpty else { throw missing }
            message.member = member
        case .snapshot:
            guard let state = message.state else { throw missing }
            message.state = state.sanitized()
        case .memberLeft:
            guard let id = message.memberID, !id.isEmpty else { throw missing }
            message.memberID = RoomLimits.name(id)
        case .ended:
            break
        case .addTile:
            guard let tile = message.tile else { throw missing }
            message.tile = tile.sanitized()
        case .moveTile:
            guard message.tileID != nil, let x = message.x, let y = message.y, let stamp = message.stamp else { throw missing }
            message.x = RoomLimits.clampCoordinate(x)
            message.y = RoomLimits.clampCoordinate(y)
            message.stamp = RoomLimits.clampStamp(stamp)
        case .editTile:
            guard message.tileID != nil, let text = message.text, let stamp = message.stamp else { throw missing }
            message.text = String(text.prefix(RoomLimits.maxTextLength))
            message.stamp = RoomLimits.clampStamp(stamp)
        case .removeTile:
            guard message.tileID != nil else { throw missing }
        case .setCollapsed:
            guard message.tileID != nil, message.flag != nil, let stamp = message.stamp else { throw missing }
            message.stamp = RoomLimits.clampStamp(stamp)
        case .chatMessage, .chatDelta:
            guard message.tileID != nil, let chat = message.chat else { throw missing }
            message.chat = chat.sanitized()
        case .addFile:
            guard message.tileID != nil, let file = message.file else { throw missing }
            message.file = file.sanitized()
        case .fileStatus:
            guard message.tileID != nil, message.fileID != nil, let status = message.fileStatus else { throw missing }
            message.fileStatus = status.sanitized()
        case .removeFile:
            guard message.tileID != nil, message.fileID != nil, message.messageID != nil else { throw missing }
        case .requestFiles:
            guard message.tileID != nil, message.targetTileID != nil else { throw missing }
        case .attachRun:
            guard message.tileID != nil, message.runID != nil, message.messageID != nil else { throw missing }
        case .runUpdate:
            guard message.tileID != nil, let run = message.run else { throw missing }
            message.run = run.sanitized()
        case .runNote:
            guard message.tileID != nil, let note = message.note else { throw missing }
            message.note = note.sanitized()
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
