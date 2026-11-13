import Foundation

/// Stable room-chat input independent of a provider's request JSON.
enum RoomAnswerPart: Sendable {
    case text(String)
    case image(fileID: String)
    case file(fileID: String)
}

struct RoomAnswerTurn: Sendable {
    var role: String
    var parts: [RoomAnswerPart]
}

protocol RoomAnswerProvider: Sendable {
    func stream(instructions: String, turns: [RoomAnswerTurn]) -> AsyncThrowingStream<String, Error>
    func upload(_ data: Data, name: String, mimeType: String, purpose: String) async throws -> String
    func delete(fileID: String) async
}

/// Responses and Files API details stay on the provider side of the room boundary.
struct OpenAIRoomAnswerProvider: RoomAnswerProvider {
    func stream(instructions: String, turns: [RoomAnswerTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await OpenAISettings.preload()
                    let client = try OpenAIResponses.fromSettings()
                    let native = turns.map { turn in
                        OpenAIResponses.Turn(role: turn.role, parts: turn.parts.map { part in
                            switch part {
                            case .text(let text): .text(text)
                            case .image(let id): .image(fileID: id)
                            case .file(let id): .file(fileID: id)
                            }
                        })
                    }
                    for try await delta in client.stream(instructions: instructions, turns: native) {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func upload(_ data: Data, name: String, mimeType: String, purpose: String) async throws -> String {
        await OpenAISettings.preload()
        return try await OpenAIResponses.fromSettings().upload(data, name: name, mimeType: mimeType, purpose: purpose)
    }

    func delete(fileID: String) async {
        guard let client = try? OpenAIResponses.fromSettings() else { return }
        await client.delete(fileID: fileID)
    }
}
