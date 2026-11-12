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

        // The same tiles, in the same order and beside them, as a chat spawned from this selection.
        let (sources, spot) = spawnSources(selected)

        // The prompt decides which files it names as attached; only those are copied and given to the agent.
        let held = Set(sources.compactMap(\.chat).flatMap(\.files).map(\.id).filter(engine.holds))
        var built = RoomRunStart.build(question: question, sources: sources, localFileIDs: held)
        var attachments: [Attachment] = []
        var copied = Set<UUID>()
        for file in built.attached {
            guard let source = engine.localCopy(of: file.id),
                  let attachment = Self.attachmentCopy(of: source, name: file.name) else { continue }
            attachments.append(attachment)
            copied.insert(file.id)
        }
        // A copy failed (or the file is gone): name that file as not attached instead.
        if copied.count < built.attached.count {
            built = RoomRunStart.build(question: question, sources: sources, localFileIDs: copied)
        }

        let id = chats.newConversation(provider: provider)
        chats.setFolder(folder, for: id)
        chats.setPermissionLevel(level, for: id)
        // This Mac's user chose the task, context and permission level. Selected reference material must
        // not override that choice. Requests sent by other members are capped separately in RoomRunInbox.
        chats.ask(built.text, attachments: attachments, in: id)

        guard let conversation = chats.conversation(id), let tileID = shareRun(conversation) else {
            notice = "The run started on your Mac, but it couldn’t be put in the room. Share it from its tab."
            return nil
        }
        if let spot { moveTile(tileID, to: spot) }
        return tileID
    }

    /// Copies a file into its own folder in the Attachments folder (the same place `RoomRunInbox` keeps a
    /// follow-up's files), so it keeps its name for the agent.
    private static func attachmentCopy(of source: URL, name: String) -> Attachment? {
        let id = UUID()
        guard let copy = RoomRunInbox.destination(for: id, name: name) else { return nil }
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else {
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            return nil
        }
        return RoomRunInbox.attachment(id: id, at: copy, name: name)
    }
}
