import Foundation

/// Owns a conversation's active execution resources. A generation prevents an older
/// provider completion from clearing a newer run after stop/retry/provider switch.
@MainActor
final class ChatRunCoordinator {
    private(set) var generations: [UUID: UUID] = [:]
    var tasks: [UUID: Task<Void, Never>] = [:]
    var handles: [UUID: RunHandle] = [:]
    var routingTokens: [UUID: UUID] = [:]
    var retryApprovals: [UUID: PermissionRequest] = [:]

    func begin(_ conversationID: UUID) -> UUID {
        handles[conversationID]?.cancel()
        tasks[conversationID]?.cancel()
        let generation = UUID()
        generations[conversationID] = generation
        return generation
    }

    func isCurrent(_ conversationID: UUID, generation: UUID) -> Bool {
        generations[conversationID] == generation
    }

    func stop(_ conversationID: UUID) -> Task<Void, Never>? {
        handles[conversationID]?.cancel()
        let task = tasks[conversationID]
        task?.cancel()
        retryApprovals[conversationID] = nil
        return task
    }

    func finish(_ conversationID: UUID, generation: UUID) {
        guard isCurrent(conversationID, generation: generation) else { return }
        tasks[conversationID] = nil
        handles[conversationID] = nil
        retryApprovals[conversationID] = nil
    }

    /// Runs a provider and batches its text. Every event is checked against the current
    /// generation before it reaches chat state, including the final buffered text.
    func execute(_ provider: any ChatProvider, request: ProviderRequest, handle: RunHandle,
                 conversationID: UUID, generation: UUID,
                 receive: @MainActor (ProviderEvent) -> Void) async throws {
        var text = TextBatcher()
        for try await event in provider.run(request, handle: handle) {
            guard !Task.isCancelled, isCurrent(conversationID, generation: generation) else { return }
            if case .text(let delta) = event {
                if let chunk = text.add(delta) { receive(.text(chunk)) }
                continue
            }
            if let rest = text.flush() { receive(.text(rest)) }
            receive(event)
        }
        guard !Task.isCancelled, isCurrent(conversationID, generation: generation) else { return }
        if let rest = text.flush() { receive(.text(rest)) }
    }
}
