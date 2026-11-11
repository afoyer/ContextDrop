import XCTest
@testable import ContextDrop

/// The provider seam: every kind is registered and described, and requests are built the same way as before.
final class ProviderTests: XCTestCase {
    func testEveryKindHasAProvider() {
        XCTAssertEqual(Set(Providers.all.map(\.kind)), Set(ProviderKind.allCases))
        for kind in ProviderKind.allCases { XCTAssertEqual(Providers[kind].kind, kind) }
    }

    func testSlashTokensAreUnique() {
        let tokens = ProviderKind.allCases.flatMap(\.slashTokens)
        XCTAssertEqual(tokens.count, Set(tokens).count)
        for kind in ProviderKind.allCases { XCTAssertFalse(kind.slashTokens.isEmpty) }
    }

    func testStoredProviderNamesStillDecode() {
        XCTAssertEqual(ProviderKind(rawValue: "openRouter"), .openAI)
        XCTAssertEqual(ProviderKind(rawValue: "claudeCode"), .claudeCode)
        XCTAssertEqual(ProviderKind(rawValue: "codex"), .codex)
    }

    func testDeepProvidersNeedAFolderAndOnlyTheyRetry() {
        XCTAssertEqual(ProviderKind.deep, [.claudeCode, .codex])
        XCTAssertNil(Providers[.openAI].retry(afterApproving: "x"))
        let claude = Providers[.claudeCode].retry(afterApproving: "Bash make")
        XCTAssertEqual(claude?.level, .ask)
        XCTAssertEqual(claude?.asksAgain, true)
        let codex = Providers[.codex].retry(afterApproving: "a.swift")
        XCTAssertEqual(codex?.level, .acceptEdits)
        XCTAssertEqual(codex?.asksAgain, false)
    }

    func testSkillsOnlyChangeTheClaudePrompt() {
        XCTAssertEqual(ClaudeCodeAgent().prompt("hi", skills: []), "hi")
        XCTAssertTrue(ClaudeCodeAgent().prompt("hi", skills: ["pdf"]).hasPrefix("Use the `pdf` skill for this request"))
        XCTAssertTrue(ClaudeCodeAgent().prompt("hi", skills: ["pdf", "xlsx"]).hasPrefix("Use the `pdf`, `xlsx` skills"))
        XCTAssertEqual(CodexAgent().prompt("hi", skills: ["pdf"]), "hi")
    }

    func testDelegationRules() {
        XCTAssertNotNil(ClaudeCodeAgent().delegateInstructions(level: .readOnly))
        XCTAssertNil(CodexAgent().delegateInstructions(level: .ask), "Codex's read-only sandbox can't reach Claude Code")
        XCTAssertNotNil(CodexAgent().delegateInstructions(level: .acceptEdits))
        let request = CLIRunner.Request(folder: URL(fileURLWithPath: "/p"), prompt: "hi", level: .ask, delegate: true)
        XCTAssertTrue(ClaudeCodeAgent().arguments(for: request).contains("Bash(\(ClaudeCodeAgent.codexDelegatePrefix):*)"))
    }

    func testCLIPromptListsLinksAndFiles() {
        let file = Attachment(id: UUID(), path: "/tmp/notes.txt", name: "notes.txt", isReference: true)
        let prompt = CLIProvider.prompt("Summarise", files: [file])
        XCTAssertTrue(prompt.hasPrefix("Summarise\n\nAttached file(s), read them as needed:\n- /tmp/notes.txt"))
        XCTAssertEqual(CLIProvider.prompt("Summarise", files: []), "Summarise")
    }

    func testOpenAITurnsStartWithTheSystemPromptAndSkipFailedAnswers() {
        var conversation = Conversation(provider: .openAI)
        conversation.messages = [
            Message(role: .user, author: "You", text: "first"),
            Message(role: .assistant, author: "OpenAI", text: "answer"),
            Message(role: .user, author: "You", text: "second"),
            Message(role: .assistant, author: "OpenAI", text: "", isStreaming: true),
        ]
        var failed = Message(role: .assistant, author: "OpenAI", text: "partial")
        failed.error = "boom"
        conversation.messages.insert(failed, at: 2)
        let turns = OpenAIProvider.turns(for: conversation)
        XCTAssertEqual(turns.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertEqual(turns.dropFirst().map(\.content), ["first", "answer", "second"])
    }

    func testFailuresDriveTheErrorCard() {
        XCTAssertEqual(ProviderError.http(401, "bad").failure, .rejectedKey)
        XCTAssertEqual(ProviderError.http(500, "down").failure, .noResponse)
        XCTAssertEqual(ProviderError.noFolder.failure, .noFolder)
        XCTAssertTrue(ProviderFailure.notInstalled.settingsHelp)
        XCTAssertFalse(ProviderFailure.agentStopped.settingsHelp)
    }

    func testTextBatcherHoldsSmallPiecesAndFlushesTheRest() {
        var batcher = TextBatcher()
        XCTAssertEqual(batcher.add("a"), "a", "the first piece shows at once")
        XCTAssertNil(batcher.add("b"))
        XCTAssertNil(batcher.add("c"))
        XCTAssertEqual(batcher.flush(), "bc")
        XCTAssertNil(batcher.flush())
        XCTAssertEqual(batcher.add(String(repeating: "x", count: 200))?.count, 200, "a large piece doesn't wait")
    }
}
