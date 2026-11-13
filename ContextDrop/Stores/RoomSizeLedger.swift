import Foundation

/// Conservative snapshot admission for the host. A tile is encoded only when it changes.
/// The 4 MiB gap below the wire limit leaves room for JSON envelope and status updates.
struct RoomSizeLedger {
    static let defaultBudgetBytes = 12 * 1024 * 1024
    private(set) var estimatedBytes: Int
    private var tileBytes: [UUID: Int]
    private let budgetBytes: Int

    init(room: RoomState, budgetBytes: Int = defaultBudgetBytes) throws {
        self.budgetBytes = budgetBytes
        tileBytes = try Dictionary(uniqueKeysWithValues: room.tiles.map { ($0.id, try JSONEncoder().encode($0).count) })
        estimatedBytes = try Self.estimate(room, tileBytes: tileBytes)
    }

    func admitting(_ candidate: RoomState, change: RoomMessage? = nil, terminal: Bool = false) throws -> RoomSizeLedger? {
        var next = self
        let ids = Set(candidate.tiles.map(\.id))
        next.tileBytes = next.tileBytes.filter { ids.contains($0.key) }
        for tile in candidate.tiles where next.tileBytes[tile.id] == nil || tileChanged(tile, by: change) {
            next.tileBytes[tile.id] = try JSONEncoder().encode(tile).count
        }
        next.estimatedBytes = try Self.estimate(candidate, tileBytes: next.tileBytes)
        let limit = terminal ? RoomLimits.maxPayloadBytes - 64 * 1024 : budgetBytes
        guard next.estimatedBytes <= limit || next.estimatedBytes <= estimatedBytes else { return nil }
        return next
    }

    private func tileChanged(_ tile: RoomTile, by change: RoomMessage?) -> Bool {
        guard let change else { return true }
        switch change {
        case .addTile(let changed): return changed.id == tile.id
        case .moveTile(let id, _, _), .editTile(let id, _), .removeTile(let id),
             .setCollapsed(let id, _), .chatMessage(let id, _), .chatDelta(let id, _),
             .addFile(let id, _), .fileStatus(let id, _, _), .removeFile(let id, _, _, _),
             .runUpdate(let id, _), .runNote(let id, _), .runRequest(let id, _),
             .runRequestStatus(let id, _, _): return id == tile.id
        case .attachRun(_, let id, _, _): return id == tile.id
        default: return false
        }
    }

    private static func estimate(_ room: RoomState, tileBytes: [UUID: Int]) throws -> Int {
        var shell = room
        shell.tiles = []
        // A snapshot with no tiles measures members, room metadata, and the wire envelope.
        return try RoomCodec.encode(.snapshot(shell)).count
            + tileBytes.values.reduce(0, +) + max(0, tileBytes.count - 1)
    }
}
