import XCTest
@testable import ContextDrop

/// Pins how the JSON lines of `claude` and `codex` become `ProviderEvent`s.
/// The lines are trimmed copies of real output (claude 2.1.x, codex-cli 0.167).
final class CLIParserTests: XCTestCase {
    private let folder = "/Users/me/project"

    // MARK: Claude Code

    private func claude(_ level: PermissionLevel = .ask) -> CLIRunner.LineParser {
        CLIRunner.LineParser(kind: .claudeCode, folder: folder, level: level)
    }

    func testClaudeInitStartsTheTurnAndReportsTheSession() {
        var parser = claude()
        let events = parser.parse(#"{"type":"system","subtype":"init","session_id":"abc12345-6789","model":"claude-opus","tools":["Read","Bash"],"claude_code_version":"2.1.322"}"#)
        XCTAssertTrue(parser.turnStarted)
        XCTAssertEqual(events.sessionIDs, ["abc12345-6789"])
    }

    func testClaudeAssistantTextAndParagraphBreak() {
        var parser = claude()
        let first = parser.parse(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello."}]}}"#)
        let second = parser.parse(#"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"More."}]}}"#)
        XCTAssertEqual(first.texts, ["Hello."])
        XCTAssertEqual(second.texts, ["More."])
        XCTAssertTrue(second.contains { if case .textBlockBreak = $0 { true } else { false } })
        XCTAssertTrue(parser.producedOutput)
    }

    func testClaudeTextThatAlreadyStreamedIsNotRepeated() {
        var parser = claude()
        _ = parser.parse(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#)
        let streamed = parser.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#)
        let whole = parser.parse(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello"}]}}"#)
        let again = parser.parse(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello"}]}}"#)
        XCTAssertEqual(streamed.texts, ["Hel"])
        XCTAssertEqual(whole.texts, ["lo"], "only the part that had not streamed yet")
        XCTAssertEqual(again.texts, [])
    }

    func testClaudeToolUseBecomesAStepThatFinishes() {
        var parser = claude()
        let started = parser.parse(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/Users/me/project/Sources/App.swift"}}]}}"#)
        let step = started.steps.first
        XCTAssertEqual(step?.id, "t1")
        XCTAssertEqual(step?.kind, .read)
        XCTAssertEqual(step?.detail, "Sources/App.swift", "paths are shown relative to the folder")

        let finished = parser.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#)
        XCTAssertTrue(finished.contains { if case .stepFinished(id: "t1", failed: false) = $0 { true } else { false } })
    }

    func testClaudeTaskToolStartsAndFinishesASubagent() {
        var parser = claude()
        let started = parser.parse(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t9","name":"Task","input":{"description":"Find usages","subagent_type":"Explore"}}]}}"#)
        guard case .subagentStarted(let subagent)? = started.first(where: { if case .subagentStarted = $0 { true } else { false } }) else {
            return XCTFail("no subagent")
        }
        XCTAssertEqual(subagent.type, "Explore")
        XCTAssertEqual(subagent.task, "Find usages")
        let finished = parser.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","content":"done"}]}}"#)
        XCTAssertTrue(finished.contains { if case .subagentFinished(id: "t9", failed: false) = $0 { true } else { false } })
    }

    func testClaudeTodoWriteBecomesThePlan() {
        var parser = claude()
        let events = parser.parse(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t2","name":"TodoWrite","input":{"todos":[{"content":"A","status":"completed"},{"content":"B","status":"in_progress"},{"content":"C","status":"pending"}]}}]}}"#)
        guard case .plan(let plan)? = events.first(where: { if case .plan = $0 { true } else { false } }) else { return XCTFail("no plan") }
        XCTAssertEqual(plan.map(\.status), [.done, .active, .pending])
    }

    func testClaudeControlRequestBecomesALivePermissionRequest() {
        var parser = claude()
        let events = parser.parse(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"}}}"#)
        let request = events.permissions.first
        XCTAssertEqual(request?.id, "r1")
        XCTAssertEqual(request?.tool, "Bash")
        XCTAssertEqual(request?.summary, "rm -rf build")
        XCTAssertEqual(request?.live, true)
        XCTAssertEqual(request?.rule, "Bash:rm")
    }

    func testClaudeAskUserQuestionBecomesAQuestion() {
        var parser = claude()
        let events = parser.parse(#"{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which one?","header":"Pick","options":[{"label":"A","description":"first"},{"label":"B"}],"multiSelect":false}]}}}"#)
        guard case .question(let question)? = events.first(where: { if case .question = $0 { true } else { false } }) else { return XCTFail("no question") }
        XCTAssertEqual(question.id, "q1")
        XCTAssertEqual(question.items.first?.options.map(\.label), ["A", "B"])
    }

    func testClaudeUnknownControlRequestIsRejected() {
        var parser = claude()
        _ = parser.parse(#"{"type":"control_request","request_id":"x1","request":{"subtype":"something_else"}}"#)
        XCTAssertEqual(parser.takeUnsupportedRequests(), ["x1"])
        XCTAssertEqual(parser.takeUnsupportedRequests(), [])
    }

    func testClaudeReadOnlyDenialsBecomeCardsOncePerRequest() {
        var parser = claude(.readOnly)
        let events = parser.parse(#"{"type":"result","subtype":"success","session_id":"s","num_turns":1,"duration_ms":1200,"usage":{"input_tokens":10,"output_tokens":5},"permission_denials":[{"tool_name":"Bash","tool_use_id":"d1","tool_input":{"command":"make"}},{"tool_name":"Bash","tool_use_id":"d2","tool_input":{"command":"make"}}]}"#)
        XCTAssertTrue(parser.finished)
        XCTAssertEqual(events.permissions.count, 1)
        XCTAssertEqual(events.permissions.first?.live, false)
    }

    func testClaudeDenialsAreOnlyLoggedWhenTheChatCanAsk() {
        var parser = claude(.ask)
        let events = parser.parse(#"{"type":"result","subtype":"success","permission_denials":[{"tool_name":"Bash","tool_use_id":"d1","tool_input":{"command":"make"}}]}"#)
        XCTAssertTrue(events.permissions.isEmpty)
    }

    func testClaudeErrorResultWithoutTextIsAFailure() {
        var parser = claude()
        _ = parser.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Credit balance is too low"}"#)
        XCTAssertEqual(parser.failure, "Credit balance is too low")
    }

    func testClaudeMaxTurnsIsAWarning() {
        var parser = claude()
        let events = parser.parse(#"{"type":"result","subtype":"error_max_turns"}"#)
        XCTAssertTrue(events.contains { if case .warning = $0 { true } else { false } })
        XCTAssertNil(parser.failure)
    }

    func testGarbageIsIgnored() {
        var parser = claude()
        XCTAssertTrue(parser.parse("not json").isEmpty)
        XCTAssertTrue(parser.parse(#"{"no":"type"}"#).isEmpty)
    }

    // MARK: Codex

    private func codex() -> CLIRunner.LineParser {
        CLIRunner.LineParser(kind: .codex, folder: folder, level: .readOnly)
    }

    func testCodexSessionIsReportedWhenTheTurnStarts() {
        var parser = codex()
        XCTAssertTrue(parser.parse(#"{"type":"thread.started","thread_id":"thread-1234"}"#).sessionIDs.isEmpty)
        XCTAssertFalse(parser.turnStarted)
        XCTAssertEqual(parser.parse(#"{"type":"turn.started"}"#).sessionIDs, ["thread-1234"])
        XCTAssertTrue(parser.turnStarted)
    }

    func testCodexAgentMessageArrivesAsDeltas() {
        var parser = codex()
        let first = parser.parse(#"{"type":"item.updated","item":{"id":"i1","type":"agent_message","text":"Hel"}}"#)
        let second = parser.parse(#"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Hello"}}"#)
        XCTAssertEqual(first.texts, ["Hel"])
        XCTAssertEqual(second.texts, ["lo"])
    }

    func testCodexCommandBecomesAStepAndFailsOnNonZeroExit() {
        var parser = codex()
        let started = parser.parse(#"{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"/bin/zsh -lc 'rg TODO'"}}"#)
        XCTAssertEqual(started.steps.first?.kind, .search)
        XCTAssertEqual(started.steps.first?.detail, "rg TODO")
        let done = parser.parse(#"{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"/bin/zsh -lc 'rg TODO'","exit_code":2,"aggregated_output":"boom"}}"#)
        XCTAssertEqual(done.steps.first?.failed, true)
        XCTAssertEqual(done.steps.first?.done, true)
    }

    func testCodexRefusedPatchOffersToAllowEditsOnce() {
        var parser = codex()
        let line = #"{"type":"item.completed","item":{"id":"f1","type":"file_change","status":"failed","changes":[{"path":"/Users/me/project/a.swift","kind":"update"}]}}"#
        XCTAssertEqual(parser.parse(line).permissions.map(\.id), ["codex-edits"])
        XCTAssertTrue(parser.parse(line).permissions.isEmpty, "the card is offered once per run")
        XCTAssertTrue(parser.reportedBlockedEdits)
        XCTAssertTrue(parser.takeCodexChanges().isEmpty)
    }

    func testCodexAppliedPatchIsQueuedForItsDiff() {
        var parser = codex()
        let events = parser.parse(#"{"type":"item.completed","item":{"id":"f1","type":"file_change","status":"completed","changes":[{"path":"/Users/me/project/a.swift","kind":"add"}]}}"#)
        XCTAssertEqual(events.steps.first?.label, "Edited")
        XCTAssertEqual(events.steps.first?.detail, "a.swift")
        let changed = parser.takeCodexChanges()
        XCTAssertEqual(changed.map(\.path), ["/Users/me/project/a.swift"])
        XCTAssertEqual(changed.map(\.kind), ["add"])
    }

    func testCodexTurnFailureIsKept() {
        var parser = codex()
        _ = parser.parse(#"{"type":"turn.failed","error":{"message":"rate limited"}}"#)
        XCTAssertEqual(parser.failure, "rate limited")
    }

    // MARK: Command lines

    func testClaudeArgumentsFollowThePermissionLevel() {
        func args(_ level: PermissionLevel, session: String? = nil) -> [String] {
            CLIRunner.arguments(for: .init(kind: .claudeCode, folder: URL(fileURLWithPath: folder), prompt: "hi", sessionID: session, level: level))
        }
        XCTAssertTrue(args(.readOnly).contains("dontAsk"))
        XCTAssertFalse(args(.readOnly).contains("--permission-prompt-tool"))
        XCTAssertTrue(args(.ask).contains("manual"))
        XCTAssertTrue(args(.acceptEdits).contains("acceptEdits"))
        XCTAssertFalse(args(.ask).contains("hi"), "the prompt goes in on stdin")
        XCTAssertEqual(args(.ask, session: "s1").suffix(2), ["--resume", "s1"])
    }

    func testCodexArgumentsFollowThePermissionLevel() {
        func args(_ level: PermissionLevel, session: String? = nil) -> [String] {
            CLIRunner.arguments(for: .init(kind: .codex, folder: URL(fileURLWithPath: folder), prompt: "hi", sessionID: session, level: level))
        }
        XCTAssertEqual(args(.ask), ["exec", "--json", "-C", folder, "--skip-git-repo-check", "--sandbox", "read-only", "--", "hi"])
        XCTAssertTrue(args(.acceptEdits).contains("workspace-write"))
        XCTAssertEqual(args(.acceptEdits, session: "t1").prefix(2), ["exec", "resume"])
        XCTAssertEqual(args(.acceptEdits, session: "t1").suffix(3), ["--", "t1", "hi"])
    }
}

// MARK: - Reading events

extension Array where Element == ProviderEvent {
    var texts: [String] { compactMap { if case .text(let text) = $0 { text } else { nil } } }
    var steps: [ToolStep] { compactMap { if case .step(let step) = $0 { step } else { nil } } }
    var permissions: [PermissionRequest] { compactMap { if case .permissionRequest(let request) = $0 { request } else { nil } } }
    var sessionIDs: [String] { compactMap { if case .session(let id) = $0 { id } else { nil } } }
}
