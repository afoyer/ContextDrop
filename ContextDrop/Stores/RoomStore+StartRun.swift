import Foundation

extension RoomStore {
    /// "New Claude Code run" / "New Codex run" in the ask bar: starts a run on this Mac in `folder` at `level`,
    /// with `prompt` plus the context of the `selected` tiles, and puts it in the room beside them.
    /// Returns the new run tile's id, or nil if it couldn't start.
    ///
    /// The run is an ordinary chat on this Mac (so it is also in Quick Chat); the room gets a live tile for it,
    /// as if it had been shared by hand. Files of the selected chats that this Mac already holds go with the
    /// prompt; the others are named in it as not attached.
    @discardableResult
    func startRun(provider: ProviderKind, prompt: String, selected: Set<UUID>, folder: URL, level: PermissionLevel) -> UUID? {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !question.isEmpty else { return nil }
        guard provider.roomShare == .liveRun else {
            notice = "Only Claude Code and Codex runs can be started here."
            return nil
        }
        guard let chats else {
            notice = "Your chats aren’t available, so the run couldn’t start."
            return nil
        }
        // Checked first, so a run never starts without a tile to show it.
        guard tiles.count < RoomLimits.maxTiles else {
            notice = "The canvas is full (\(RoomLimits.maxTiles) tiles). Remove some to start a run here."
            return nil
        }

        // The same tiles, in the same order, as a chat spawned from this selection.
        let sources = Array(tiles.filter { selected.contains($0.id) }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .prefix(RoomLimits.maxSpawnSources))

        // Beside the selection; otherwise wherever a shared run lands.
        var spot: CGPoint?
        if let right = sources.map({ $0.x + RoomMetrics.width(for: $0) }).max(), let top = sources.map(\.y).min() {
            spot = freeSpot(near: CGPoint(x: right + 70, y: top))
        }

        // The prompt decides which files it names as attached; only those are copied and given to the agent.
        let held = Set(heldFileIDs(of: sources))
        var built = RoomRunStart.build(question: question, sources: sources, localFileIDs: held)
        var attachments: [Attachment] = []
        var copied = Set<UUID>()
        for fileID in built.attachedFileIDs {
            guard let file = sources.compactMap(\.chat).flatMap(\.files).first(where: { $0.id == fileID }),
                  let source = engine.localCopy(of: fileID),
                  let attachment = Self.attachmentCopy(of: source, name: file.name) else { continue }
            attachments.append(attachment)
            copied.insert(fileID)
        }
        // A copy failed: name that file as not attached instead.
        if copied.count < built.attachedFileIDs.count {
            built = RoomRunStart.build(question: question, sources: sources, localFileIDs: copied)
        }

        let id = chats.newConversation(provider: provider)
        chats.setFolder(folder, for: id)
        chats.setPermissionLevel(level, for: id)
        // Room content was written by other people (or their models), so this first answer runs at most at
        // "Ask before editing": every edit or command comes back to me, as with someone else's follow-up.
        chats.ask(built.text, attachments: attachments, levelCap: sources.isEmpty ? nil : .ask, in: id)

        guard let conversation = chats.conversation(id), let tileID = shareRun(conversation) else {
            notice = "The run started on your Mac, but it couldn’t be put in the room. Share it from its tab."
            return nil
        }
        if let spot { moveTile(tileID, to: spot) }
        return tileID
    }

    /// Files of the selected chats that this Mac holds a copy of, so they can go with the prompt.
    private func heldFileIDs(of sources: [RoomTile]) -> [UUID] {
        sources.compactMap(\.chat).flatMap(\.files).map(\.id).filter { fileID in
            engine.localCopy(of: fileID).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    /// Copies a file into its own folder in the Attachments folder (the same place `RoomRunInbox` keeps a
    /// follow-up's files), so it keeps its name for the agent. Images go as images, everything else as a file
    /// the agent reads itself.
    private static func attachmentCopy(of source: URL, name: String) -> Attachment? {
        let id = UUID()
        guard let copy = RoomRunInbox.destination(for: id, name: name) else { return nil }
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else {
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            return nil
        }
        return Attachment(id: id, path: copy.path, name: name, isReference: Attachments.isImage(copy) ? nil : true)
    }
}
