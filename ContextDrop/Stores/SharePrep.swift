import Foundation
import Observation

struct Toggled<Value: Hashable>: Identifiable, Hashable {
    let id = UUID()
    var value: Value
    var included: Bool
}

/// State of the "Keep the important stuff" step (board 2).
@MainActor
@Observable
final class SharePrep {
    enum Phase: Equatable { case summarizing, ready, failed(String) }

    /// One focusable row of the checklist, in display order, for ↑↓ / space.
    enum Row: Hashable {
        case summary, kept(UUID), fact(UUID), decision(UUID), nextStep(UUID), question(UUID), note(UUID)
        case screenshots, fileNames, transcript
    }

    let conversationID: UUID
    /// Identity of the "What they will get" preview (a real share gets its own id when sent).
    let previewID = UUID()
    let startedAt = Date()
    var phase: Phase = .summarizing
    var title: String
    var summary = ""
    var isEditingSummary = false
    var kept: [KeptItem]
    var detail = ShareDetail.preferred
    var facts: [Toggled<String>] = []
    var decisions: [Toggled<String>] = []
    var nextSteps: [Toggled<String>] = []
    var questions: [Toggled<String>] = []
    var notes: [Toggled<ShareNote>] = []
    var includeTranscript = false
    var includeFileNames = true
    let transcriptCount: Int
    let fileNames: [String]
    /// Screenshots in the chat. Off by default: they may show more than the user means to share.
    let screenshots: [Attachment]
    var includeScreenshots = false
    private(set) var sharedImages: [SharedImage] = []
    static let maxSharedImages = 4
    var focused: Row = .summary
    var newNoteTitle = ""

    init(conversation: Conversation) {
        conversationID = conversation.id
        title = conversation.title
        transcriptCount = conversation.messages.filter { $0.error == nil && !$0.text.isEmpty }.count
        fileNames = conversation.referencedFileNames
        screenshots = Array(conversation.allAttachments.suffix(Self.maxSharedImages))
        // Kept answers always travel. Pair each with the question right before it.
        var items: [KeptItem] = []
        for (index, message) in conversation.messages.enumerated() where message.kept {
            let question = conversation.messages[..<index].last(where: { $0.role == .user })?.text
            items.append(KeptItem(id: message.id, question: question, text: message.text, author: message.author))
        }
        kept = items
    }

    func apply(_ draft: SummaryDraft) {
        if !draft.title.isEmpty { title = draft.title }
        summary = draft.summary
        facts = draft.keyFacts.map { Toggled(value: $0, included: true) }
        decisions = draft.decisions.map { Toggled(value: $0, included: true) }
        nextSteps = draft.nextSteps.map { Toggled(value: $0, included: true) }
        questions = draft.openQuestions.map { Toggled(value: $0, included: true) }
        phase = .ready
    }

    var rows: [Row] {
        var rows: [Row] = [.summary]
        rows += kept.map { .kept($0.id) }
        rows += facts.map { .fact($0.id) }
        rows += decisions.map { .decision($0.id) }
        rows += nextSteps.map { .nextStep($0.id) }
        rows += questions.map { .question($0.id) }
        rows += notes.map { .note($0.id) }
        if !screenshots.isEmpty { rows.append(.screenshots) }
        if !fileNames.isEmpty { rows.append(.fileNames) }
        rows.append(.transcript)
        return rows
    }

    func move(_ delta: Int) {
        let rows = rows
        guard let index = rows.firstIndex(of: focused) else { focused = rows.first ?? .summary; return }
        focused = rows[max(0, min(rows.count - 1, index + delta))]
    }

    func toggleFocused() { toggle(focused) }

    func toggle(_ row: Row) {
        switch row {
        case .summary, .kept: break // always included
        case .fact(let id): if let i = facts.firstIndex(where: { $0.id == id }) { facts[i].included.toggle() }
        case .decision(let id): if let i = decisions.firstIndex(where: { $0.id == id }) { decisions[i].included.toggle() }
        case .nextStep(let id): if let i = nextSteps.firstIndex(where: { $0.id == id }) { nextSteps[i].included.toggle() }
        case .screenshots:
            includeScreenshots.toggle()
            if includeScreenshots && sharedImages.isEmpty {
                // Compressed once, when first included: ≤1280 px JPEG keeps a share at a few hundred KB.
                sharedImages = screenshots.compactMap { a in
                    Attachments.jpegData(a.url, maxPixels: 1280, quality: 0.6).map { SharedImage(id: a.id, name: a.name, jpeg: $0) }
                }
            }
        case .question(let id): if let i = questions.firstIndex(where: { $0.id == id }) { questions[i].included.toggle() }
        case .note(let id): if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].included.toggle() }
        case .fileNames: includeFileNames.toggle()
        case .transcript: includeTranscript.toggle()
        }
    }

    func addNote() {
        let title = newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        notes.append(Toggled(value: ShareNote(id: UUID(), title: String(title.prefix(80)), body: ""), included: true))
        newNoteTitle = ""
    }

    var countsLine: String {
        var parts = ["Summary"]
        func add(_ n: Int, _ one: String, _ many: String) { if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") } }
        add(kept.count, "kept", "kept")
        add(facts.filter(\.included).count, "fact", "facts")
        add(decisions.filter(\.included).count, "decision", "decisions")
        add(nextSteps.filter(\.included).count, "next step", "next steps")
        add(questions.filter(\.included).count, "question", "questions")
        add(notes.filter(\.included).count, "note", "notes")
        if includeScreenshots { add(sharedImages.count, "screenshot", "screenshots") }
        if includeTranscript { parts.append("full chat") }
        return parts.joined(separator: " · ")
    }

    var canContinue: Bool { phase == .ready && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// "Share tabs": which open tabs go out together, and progress writing their summaries (R3 board 4).
@MainActor
@Observable
final class MultiSharePrep {
    struct Item: Identifiable, Hashable {
        let id: UUID
        var included: Bool
    }

    enum Phase: Equatable {
        case choosing
        case summarizing(done: Int, total: Int)
        case failed(String)

        var canStart: Bool { if case .summarizing = self { false } else { true } }
    }

    var items: [Item]
    var phase: Phase = .choosing
    var focused = 0
    @ObservationIgnored var task: Task<Void, Never>?

    init(items: [Item]) { self.items = items }

    var includedCount: Int { items.filter(\.included).count }

    func toggle(_ id: UUID) {
        guard phase.canStart, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].included.toggle()
    }
}
