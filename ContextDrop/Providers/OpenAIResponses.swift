import Foundation

/// How closely the model looks at images and PDF pages. Higher costs more tokens.
enum OpenAIDetail: String, CaseIterable, Sendable, Identifiable {
    case auto, low, high

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .low: "Low (cheaper)"
        case .high: "High (reads small text)"
        }
    }
}

/// What a model can be given besides text.
enum OpenAIModelCaps {
    /// A model to suggest when the current one can't take images or documents.
    static let suggested = "gpt-4.1"

    /// Images, and PDFs / documents (which are read with their page images on these models).
    static func takesFiles(_ model: String) -> Bool {
        let id = model.lowercased()
        if id.hasPrefix("gpt-3.5") || id.hasPrefix("gpt-4-") || id == "gpt-4" { return false }
        if id.hasPrefix("o1-mini") || id.hasPrefix("o1-preview") || id.hasPrefix("o3-mini") { return false }
        return true
    }
}

/// OpenAI Responses API (streamed answers with images and files) and the Files API.
/// Room chats use this; Chat Completions (`OpenAIClient`) only accepts PDFs as files.
struct OpenAIResponses: Sendable {
    static let responsesEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let filesEndpoint = URL(string: "https://api.openai.com/v1/files")!

    enum Part: Sendable {
        case text(String)
        /// An image uploaded through the Files API.
        case image(fileID: String)
        /// A PDF or document uploaded through the Files API.
        case file(fileID: String)
    }

    struct Turn: Sendable {
        /// "user" or "assistant".
        let role: String
        var parts: [Part]
    }

    let apiKey: String
    let model: String
    var detail: OpenAIDetail = AppDefaults.openAIDetail

    static func fromSettings() throws -> OpenAIResponses {
        guard let key = OpenAISettings.apiKey() else { throw ProviderError.missingKey }
        return OpenAIResponses(apiKey: key, model: OpenAISettings.model)
    }

    // MARK: Files

    /// Uploads a file once and returns its id, to reuse on every later request.
    /// `purpose` is "vision" for images and "user_data" for everything else.
    func upload(_ data: Data, name: String, mimeType: String, purpose: String) async throws -> String {
        let boundary = "ctxdrop-\(UUID().uuidString)"
        var request = URLRequest(url: Self.filesEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Quotes and line breaks would break the part header.
        let safeName = name.replacingOccurrences(of: "\"", with: "'").components(separatedBy: .newlines).joined(separator: " ")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\n\(purpose)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (reply, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode, OpenAIClient.errorMessage(String(decoding: reply.prefix(4_000), as: UTF8.self)))
        }
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else { throw ProviderError.badResponse }
        return id
    }

    /// Best effort: removes an uploaded file from the account.
    func delete(fileID: String) async {
        var request = URLRequest(url: Self.filesEndpoint.appendingPathComponent(fileID))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: Responses

    private func payload(_ part: Part) -> [String: Any] {
        switch part {
        case .text(let text): ["type": "input_text", "text": text]
        case .image(let fileID): ["type": "input_image", "file_id": fileID, "detail": detail.rawValue]
        case .file(let fileID): ["type": "input_file", "file_id": fileID, "detail": detail.rawValue]
        }
    }

    private func payload(_ turn: Turn) -> [String: Any] {
        if turn.role == "assistant" {
            // Earlier answers go back as plain text.
            let text = turn.parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
            return ["role": "assistant", "content": text]
        }
        return ["role": turn.role, "content": turn.parts.map(payload)]
    }

    func stream(instructions: String, turns: [Turn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: Self.responsesEndpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 180
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "store": false,
                        "instructions": instructions,
                        "input": turns.map(payload),
                    ]
                    if OpenAIClient.isReasoningModel(model) { body["reasoning"] = ["effort": "low"] }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
                    if http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines {
                            text += line
                            if text.count > 4_000 { break }
                        }
                        throw ProviderError.http(http.statusCode, OpenAIClient.errorMessage(text))
                    }
                    events: for try await line in bytes.lines {
                        // SSE: "event: <type>" then "data: {...}"; the type is also inside the JSON.
                        guard line.hasPrefix("data:") else { continue }
                        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if raw == "[DONE]" { break }
                        guard let data = raw.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = object["type"] as? String else { continue }
                        switch type {
                        case "response.output_text.delta":
                            if let delta = object["delta"] as? String, !delta.isEmpty { continuation.yield(delta) }
                        case "response.completed", "response.incomplete":
                            break events
                        case "response.failed":
                            let error = (object["response"] as? [String: Any])?["error"] as? [String: Any]
                            throw ProviderError.http(0, (error?["message"] as? String) ?? "The request failed.")
                        case "error":
                            throw ProviderError.http(0, (object["message"] as? String) ?? "Stream error")
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
