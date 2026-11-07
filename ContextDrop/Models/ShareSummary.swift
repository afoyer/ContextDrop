import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let contextDrop = UTType(exportedAs: "edu.cmu.hackathon.contextdrop", conformingTo: .json)
}

struct KeptItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var question: String?
    var text: String
    var author: String
}

struct ShareNote: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var body: String
}

struct TranscriptLine: Codable, Hashable, Sendable {
    var author: String
    var text: String
}

/// The only thing that ever leaves the Mac: a curated handoff brief.
struct ShareSummary: Codable, Hashable, Identifiable, Sendable {
    static let currentVersion = 1

    var version = ShareSummary.currentVersion
    let id: UUID
    var title: String
    var senderName: String
    var senderDevice: String
    var createdAt: Date
    var summary: String
    var kept: [KeptItem]
    var decisions: [String]
    var openQuestions: [String]
    var notes: [ShareNote]
    var fileNames: [String]
    var transcript: [TranscriptLine]?

    var countsLine: String {
        var parts = ["Summary"]
        func add(_ n: Int, _ one: String, _ many: String) { if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") } }
        add(kept.count, "kept", "kept")
        add(decisions.count, "decision", "decisions")
        add(openQuestions.count, "question", "questions")
        add(notes.count, "note", "notes")
        add(fileNames.count, "file name", "file names")
        if let transcript { parts.append("full chat (\(transcript.count))") }
        return parts.joined(separator: " · ")
    }

    /// Exactly what the receiving AI gets as its system context. The "Picked up from" block shows this text.
    func contextPrompt() -> String {
        var out = """
        You are continuing a chat that \(senderName) handed over from their Mac with ContextDrop. \
        You only know what is written below; nothing else from their chat was shared. \
        Build on it, and say so if something you need was not included.

        Title: \(title)

        Summary:
        \(summary)
        """
        if !kept.isEmpty {
            out += "\n\nAnswers \(senderName) kept as important:"
            for item in kept {
                if let q = item.question, !q.isEmpty { out += "\n- Q: \(q)\n  A: \(item.text)" } else { out += "\n- \(item.text)" }
            }
        }
        if !decisions.isEmpty { out += "\n\nDecided:" + decisions.map { "\n- \($0)" }.joined() }
        if !openQuestions.isEmpty { out += "\n\nStill open:" + openQuestions.map { "\n- \($0)" }.joined() }
        if !notes.isEmpty { out += "\n\nNotes:" + notes.map { "\n- \($0.title)\($0.body.isEmpty ? "" : ": \($0.body)")" }.joined() }
        if !fileNames.isEmpty { out += "\n\nFiles mentioned (names only, contents not shared): " + fileNames.joined(separator: ", ") }
        if let transcript, !transcript.isEmpty {
            out += "\n\nFull conversation:" + transcript.map { "\n[\($0.author)] \($0.text)" }.joined()
        }
        return out
    }

    func markdown() -> String {
        var md = "# \(title)\n\n_Shared by \(senderName) with ContextDrop_\n\n\(summary)\n"
        if !kept.isEmpty { md += "\n## Kept\n" + kept.map { "\n> \($0.text)\n" }.joined() }
        if !decisions.isEmpty { md += "\n## Decided\n" + decisions.map { "- \($0)\n" }.joined() }
        if !openQuestions.isEmpty { md += "\n## Still open\n" + openQuestions.map { "- \($0)\n" }.joined() }
        if !notes.isEmpty { md += "\n## Notes\n" + notes.map { "- **\($0.title)** \($0.body)\n" }.joined() }
        return md
    }

    var preview: SharePreview {
        SharePreview(
            id: id,
            title: String(title.prefix(120)),
            senderName: senderName,
            senderDevice: senderDevice,
            summary: summary.count > 600 ? String(summary.prefix(597)) + "…" : summary,
            openQuestions: openQuestions.prefix(3).map { String($0.prefix(200)) },
            noteTitles: notes.prefix(6).map { String($0.title.prefix(60)) },
            countsLine: countsLine
        )
    }

    /// Validates a package received from another Mac or opened from a file.
    var isValid: Bool {
        version == Self.currentVersion
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && summary.count <= 8_000 && kept.count <= 50 && decisions.count <= 50
            && openQuestions.count <= 50 && notes.count <= 50
    }

    // MARK: File (.contextdrop)

    func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func fromFile(_ data: Data) throws -> ShareSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let share = try decoder.decode(ShareSummary.self, from: data)
        guard share.isValid else { throw WireError.invalidContent }
        return share
    }
}

/// Small teaser carried in the Multipeer invitation so the receiver can Preview before accepting.
struct SharePreview: Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var senderName: String
    var senderDevice: String
    var summary: String
    var openQuestions: [String]
    var noteTitles: [String]
    var countsLine: String
}
