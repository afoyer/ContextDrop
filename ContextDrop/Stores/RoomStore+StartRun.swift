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

        let files = heldFiles(of: sources)
        let text = RoomRunStart.prompt(question: question, sources: sources, localFileIDs: Set(files.map(\.fileID)))

        let id = chats.newConversation(provider: provider)
        chats.setFolder(folder, for: id)
        chats.setPermissionLevel(level, for: id)
        chats.ask(text, attachments: files.map(\.attachment), in: id)

        guard let conversation = chats.conversation(id), let tileID = shareRun(conversation) else {
            notice = "The run started on your Mac, but it couldn’t be put in the room. Share it from its tab."
            return nil
        }
        if let spot { moveTile(tileID, to: spot) }
        return tileID
    }

    /// Files of the selected chats that this Mac already holds, copied into the Attachments folder (which the
    /// agents may read) under their own names, the way `RoomRunInbox` keeps a follow-up's files. Each copy
    /// belongs to the run's chat from then on, so leaving the room doesn't delete it.
    private func heldFiles(of sources: [RoomTile]) -> [(fileID: UUID, attachment: Attachment)] {
        var held: [(fileID: UUID, attachment: Attachment)] = []
        // The same files, in the same order, that the prompt lists (so every attached file is named in it).
        var seen = Set<UUID>()
        for chat in sources.compactMap(\.chat) {
            for file in chat.files where !seen.contains(file.id) {
                guard seen.count < RoomRunStart.maxListedFiles else { return held }
                seen.insert(file.id)
                guard engine.holds(file.id), let source = localCopy(of: file),
                      let attachment = Self.attachmentCopy(of: source, name: file.name) else { continue }
                held.append((file.id, attachment))
            }
        }
        return held
    }

    /// Where `RoomChatEngine` keeps a file it holds for this room: Application Support/ContextDrop/RoomFiles/
    /// <room>/<file id>.<ext>. Nil when it isn't there.
    private func localCopy(of file: RoomFile) -> URL? {
        guard let roomID = room?.id,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("ContextDrop/RoomFiles/\(roomID.uuidString)", isDirectory: true)
            .appendingPathComponent(file.id.uuidString).appendingPathExtension((file.name as NSString).pathExtension)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies a file into its own folder in the Attachments folder (Attachments/Room/<id>/<name>), so it keeps
    /// its name for the agent. Images go as images, everything else as a file the agent reads itself.
    private static func attachmentCopy(of source: URL, name: String) -> Attachment? {
        let id = UUID()
        let dir = Attachments.directory.appendingPathComponent("Room/\(id.uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let copy = dir.appendingPathComponent(safe.isEmpty || safe.hasPrefix(".") ? "file" + safe : safe)
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return Attachment(id: id, path: copy.path, name: name, isReference: Attachments.isImage(copy) ? nil : true)
    }
}
