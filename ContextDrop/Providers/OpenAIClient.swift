import Foundation

struct ChatTurn: Sendable {
    let role: String
    let content: String
    /// Local image files sent with this turn (as JPEG data URLs; needs a vision-capable model).
    var images: [URL] = []

    var payload: [String: Any] {
        guard !images.isEmpty else { return ["role": role, "content": content] }
        var parts: [[String: Any]] = [["type": "text", "text": content.isEmpty ? "(see image)" : content]]
        for url in images {
            if let dataURL = Attachments.dataURL(url) { parts.append(["type": "image_url", "image_url": ["url": dataURL]]) }
        }
        return ["role": role, "content": parts]
    }
}

/// OpenAI Chat Completions: streamed answers and one-shot replies.
struct OpenAIClient: Sendable {
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    let http: OpenAIHTTP
    let model: String

    static func fromSettings() throws -> OpenAIClient {
        OpenAIClient(http: try .fromSettings(), model: OpenAISettings.model)
    }

    private func request(_ turns: [ChatTurn], stream: Bool, jsonMode: Bool, maxTokens: Int? = nil, timeout: TimeInterval = 120) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": turns.map(\.payload),
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        if OpenAIModelCaps.reasons(model) {
            // Reasoning models spend hidden tokens before answering; keep that short so the
            // decision call stays inside its timeout, and do not cap output with a tiny budget.
            body["reasoning_effort"] = "low"
        } else if let maxTokens {
            body["max_completion_tokens"] = maxTokens
        }
        return try http.request(Self.endpoint, timeout: timeout, json: body)
    }

    func stream(_ turns: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        http.textStream({ try request(turns, stream: true, jsonMode: false) }) { event in
            if let error = event["error"] as? [String: Any] {
                throw ProviderError.http((error["code"] as? Int) ?? 0, (error["message"] as? String) ?? "Stream error")
            }
            if let choices = event["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                return .text(content)
            }
            return .skip
        }
    }

    func complete(_ turns: [ChatTurn], jsonMode: Bool, maxTokens: Int? = nil, timeout: TimeInterval = 120) async throws -> String {
        let data = try await http.data(for: try request(turns, stream: false, jsonMode: jsonMode, maxTokens: maxTokens, timeout: timeout))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw ProviderError.badResponse }
        return content
    }
}
