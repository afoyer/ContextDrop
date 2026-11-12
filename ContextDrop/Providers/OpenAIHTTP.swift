import Foundation

/// What every OpenAI call shares: the authorized request, error mapping, and reading a streamed reply.
struct OpenAIHTTP: Sendable {
    /// What one event of a streamed reply means to the caller.
    enum StreamStep: Sendable { case text(String), skip, done }

    let apiKey: String

    static func fromSettings() throws -> OpenAIHTTP {
        guard let key = OpenAISettings.apiKey() else { throw ProviderError.missingKey }
        return OpenAIHTTP(apiKey: key)
    }

    func request(_ url: URL, method: String = "POST", timeout: TimeInterval, json body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Sends a request (uploading `body` when given) and returns the reply. Anything but 200 is thrown.
    func data(for request: URLRequest, uploading body: Data? = nil) async throws -> Data {
        let (data, response) = if let body {
            try await URLSession.shared.upload(for: request, from: body)
        } else {
            try await URLSession.shared.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard http.statusCode == 200 else {
            throw ProviderError.http(http.statusCode, Self.errorMessage(String(decoding: data.prefix(4_000), as: UTF8.self)))
        }
        return data
    }

    /// A streamed reply (server-sent events) as text. `read` is given each event's JSON and says what it is.
    func textStream(_ request: @escaping @Sendable () throws -> URLRequest,
                    read: @escaping @Sendable ([String: Any]) throws -> StreamStep) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try request())
                    guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
                    if http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4_000 { break }
                        }
                        throw ProviderError.http(http.statusCode, Self.errorMessage(body))
                    }
                    events: for try await line in bytes.lines {
                        // SSE: "data: {...}"; "event:" lines repeat what is in the JSON, and ":" lines are keep-alives.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        switch try read(object) {
                        case .text(let text): continuation.yield(text)
                        case .skip: continue
                        case .done: break events
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

    /// The message inside an OpenAI error body, or the start of the body.
    static func errorMessage(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(body.prefix(200))
    }
}
