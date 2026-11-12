import Foundation

/// Quick answers from the OpenAI API (Chat Completions): text and images in, streamed text out.
/// No tools, no folder, nothing to approve.
struct OpenAIProvider: ChatProvider {
    let kind = ProviderKind.openAI

    func status() async -> ProviderStatus {
        await OpenAISettings.preload()
        return OpenAISettings.apiKey() == nil ? .missingKey : .ready("API key · fast, no file access")
    }

    func run(_ request: ProviderRequest, handle: RunHandle) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await OpenAISettings.preload()
                    let client = try OpenAIClient.fromSettings()
                    for try await delta in client.stream(Self.turns(for: request.conversation)) {
                        continuation.yield(.text(delta))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let baseSystemPrompt = """
    You are ContextDrop, a concise assistant summoned from a floating panel on a Mac. \
    Answer directly and briefly; use short paragraphs or lists. Plain text with light Markdown only.
    """

    /// The chat so far as OpenAI turns: the system prompt (with a picked-up share's context), then the history.
    static func turns(for conversation: Conversation) -> [ChatTurn] {
        var system = Self.baseSystemPrompt
        if let picked = conversation.pickedUp { system += "\n\n" + picked.contextPrompt() }
        var turns = [ChatTurn(role: "system", content: system)]
        // Images: only the 4 most recent ones travel (they are large); handoff screenshots ride on the first question.
        var imageBudget = 4
        var history: [ChatTurn] = []
        let messages = conversation.messages.filter { $0.error == nil && !$0.text.isEmpty }
        for (index, message) in messages.enumerated().reversed() {
            var content = message.text
            // Files attached by reference: OpenAI can't open them, so small text files travel inline.
            for file in message.attachments where message.role == .user && !file.isImage {
                if let link = file.link {
                    content += "\n\nLink: \(link)"
                } else if let text = Attachments.inlineText(file) {
                    content += "\n\n\(file.isPastedText == true ? "Pasted text" : "Attached file \(file.name)"):\n```\n\(text)\n```"
                } else {
                    content += "\n\n(Attached file \(file.name) could not be included. A coding agent can read it.)"
                }
            }
            var turn = ChatTurn(role: message.role == .user ? "user" : "assistant", content: content)
            if message.role == .user {
                var images = message.attachments.filter(\.isImage).map(\.url)
                if index == messages.firstIndex(where: { $0.role == .user }) { images = conversation.pickedUpAttachments.map(\.url) + images }
                images = Array(images.suffix(imageBudget))
                imageBudget -= images.count
                turn.images = images
            }
            history.insert(turn, at: 0)
        }
        turns += history
        return turns
    }
}
