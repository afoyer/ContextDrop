import Foundation

extension RoomStore {
    /// "New Claude Code run" / "New Codex run" in the ask bar: starts a run on this Mac in `folder` at `level`,
    /// with `prompt` plus the context of the `selected` tiles, and puts it in the room beside them.
    /// Returns the new run tile's id, or nil if it couldn't start.
    @discardableResult
    func startRun(provider: ProviderKind, prompt: String, selected: Set<UUID>, folder: URL, level: PermissionLevel) -> UUID? {
        // TODO(run-start): build the prompt with RoomRunStart, create the chat, ask, share the run and place it.
        nil
    }
}
