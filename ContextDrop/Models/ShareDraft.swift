import Foundation

/// How much the share brief should carry.
enum ShareDetail: String, CaseIterable, Sendable {
    case brief, detailed

    var label: String { self == .brief ? "Brief" : "Detailed" }
}

/// What OpenAI extracts for the share sheet.
struct SummaryDraft: Decodable, Sendable {
    var title: String
    var summary: String
    var decisions: [String]
    var openQuestions: [String]
    var keyFacts: [String] = []
    var nextSteps: [String] = []

    private enum CodingKeys: String, CodingKey {
        case title, summary, decisions, openQuestions, open_questions, keyFacts, key_facts, nextSteps, next_steps
    }

    init(title: String, summary: String, decisions: [String], openQuestions: [String]) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.openQuestions = openQuestions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        decisions = (try? c.decode([String].self, forKey: .decisions)) ?? []
        openQuestions = (try? c.decode([String].self, forKey: .openQuestions))
            ?? (try? c.decode([String].self, forKey: .open_questions)) ?? []
        keyFacts = (try? c.decode([String].self, forKey: .keyFacts)) ?? (try? c.decode([String].self, forKey: .key_facts)) ?? []
        nextSteps = (try? c.decode([String].self, forKey: .nextSteps)) ?? (try? c.decode([String].self, forKey: .next_steps)) ?? []
    }
}
