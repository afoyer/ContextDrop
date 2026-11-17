import Foundation

/// Something that can answer a chat: an API (`OpenAIProvider`) or a coding agent's CLI (`CLIProvider`).
///
/// `ChatStore` knows nothing else about a provider: it hands over a `ProviderRequest`, applies the
/// `ProviderEvent`s that come back, and uses the `RunHandle` to stop the run or answer what it asked.
///
/// To add one: add a `ProviderKind` case (its descriptors drive the menus, slash commands and views),
/// write the `ChatProvider`, and list it in `Providers.all`.
protocol ChatProvider: Sendable {
    var kind: ProviderKind { get }

    /// Can it answer right now (key present, CLI installed and signed in)?
    func status() async -> ProviderStatus

    /// Answers the latest question. Finishing the stream ends the answer; throwing shows the error card.
    /// Cancelling the consuming task must stop the work.
    func run(_ request: ProviderRequest, handle: RunHandle) -> AsyncThrowingStream<ProviderEvent, Error>

    /// How to run again after the user allowed something a run refused without asking.
    /// Nil when this provider never refuses anything.
    func retry(afterApproving what: String) -> ApprovedRetry?
}

extension ChatProvider {
    func retry(afterApproving what: String) -> ApprovedRetry? { nil }
}

/// The handle `ChatStore` keeps for a running answer.
/// Provider-neutral controls for the active run. Adapters bind their native implementation.
final class RunHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelAction: (@Sendable () -> Void)?
    private var permissionAction: (@Sendable (PermissionRequest, Bool, String?) -> Void)?
    private var questionAction: (@Sendable (AgentQuestion) -> Void)?

    func bind(cancel: @escaping @Sendable () -> Void,
              permission: (@Sendable (PermissionRequest, Bool, String?) -> Void)? = nil,
              question: (@Sendable (AgentQuestion) -> Void)? = nil) {
        let shouldCancel = lock.withLock { () -> Bool in
            cancelAction = cancel
            permissionAction = permission
            questionAction = question
            return cancelled
        }
        if shouldCancel { cancel() }
    }

    func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            cancelled = true
            return cancelAction
        }
        action?()
    }
    @discardableResult func answerPermission(_ request: PermissionRequest, allow: Bool, reason: String? = nil) -> Bool {
        guard let action = lock.withLock({ permissionAction }) else { return false }
        action(request, allow, reason)
        return true
    }
    @discardableResult func answerQuestion(_ question: AgentQuestion) -> Bool {
        guard let action = lock.withLock({ questionAction }) else { return false }
        action(question)
        return true
    }
}

/// Everything a provider gets to answer with.
struct ProviderRequest: Sendable {
    /// The chat as it is now: history, folder, session id, a picked-up share. The last user message is the question.
    var conversation: Conversation
    /// The question as typed (or the follow-up instruction of an approved retry).
    var prompt: String
    var attachments: [Attachment]
    /// Skills picked for this question (only providers with `supportsSkills` use them).
    var skills: [String]
    var level: PermissionLevel
    /// The provider's `delegatePartner` is ready and the user lets agents hand side tasks to each other.
    var delegate: Bool
}

/// A second run that does what the user just allowed.
struct ApprovedRetry: Sendable {
    var prompt: String
    var level: PermissionLevel
    /// The agent will ask for the same thing again; that request is answered "yes" for the user.
    var asksAgain: Bool
}

/// The providers the app knows.
enum Providers {
    static let all: [any ChatProvider] = [
        OpenAIProvider(),
        CLIProvider(agent: ClaudeCodeAgent()),
        CLIProvider(agent: CodexAgent()),
    ]

    static subscript(kind: ProviderKind) -> any ChatProvider {
        guard let provider = all.first(where: { $0.kind == kind }) else {
            preconditionFailure("No ChatProvider registered for \(kind). Add it to Providers.all.")
        }
        return provider
    }
}

/// Collects streamed text so the UI updates about 20 times a second, not once per token.
struct TextBatcher {
    private var buffer = ""
    private var lastFlush = Date.distantPast

    /// Adds a piece of text. Returns what to show now, or nil while it is still collecting.
    mutating func add(_ delta: String) -> String? {
        buffer += delta
        guard Date().timeIntervalSince(lastFlush) >= 0.05 || buffer.count >= 200 else { return nil }
        return flush()
    }

    /// Whatever is left (call before any other event, and at the end).
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer {
            buffer = ""
            lastFlush = Date()
        }
        return buffer
    }
}
