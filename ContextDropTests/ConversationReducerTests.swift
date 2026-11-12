import XCTest
@testable import ContextDrop

/// How a run's events change a chat's answer and its activity pane.
final class ConversationReducerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func answer() -> Message { Message(role: .assistant, author: "Claude Code", text: "", isStreaming: true) }

    private func applying(_ events: [ProviderEvent], to message: Message? = nil) -> Message {
        var message = message ?? answer()
        for event in events { message.apply(event, now: now) }
        return message
    }

    // MARK: The answer

    func testTextIsAppendedAndABlockBreakOnlySeparatesText() {
        let message = applying([.textBlockBreak, .text("one"), .textBlockBreak, .text("two")])
        XCTAssertEqual(message.text, "one\n\ntwo")
    }

    func testAStepIsInsertedThenUpdatedThenFinished() {
        let step = ToolStep(id: "s1", kind: .read, label: "Reading", detail: "a.swift", done: false)
        var later = step
        later.detail = "b.swift"
        let message = applying([.step(step), .step(later), .stepFinished(id: "s1", failed: true), .stepFinished(id: "unknown", failed: false)])
        XCTAssertEqual(message.steps.count, 1)
        XCTAssertEqual(message.steps[0].detail, "b.swift")
        XCTAssertTrue(message.steps[0].done)
        XCTAssertTrue(message.steps[0].failed)
    }

    func testALivePermissionRequestAsksForTheUser() {
        var message = answer()
        let request = PermissionRequest(id: "p1", tool: "Bash", summary: "git push")
        let effect = message.apply(.permissionRequest(request), now: now)
        XCTAssertEqual(effect, ReducerEffect(needsYou: "Allow Bash: git push?", activityChanged: true))
        message.apply(.permissionRequest(request), now: now)
        XCTAssertEqual(message.permissions.count, 1, "the same request is listed once")

        let edit = PermissionRequest(id: "p2", tool: "Edit", summary: "a.swift", filePath: "/x/a.swift")
        XCTAssertEqual(message.apply(.permissionRequest(edit), now: now).needsYou, "Allow an edit to a.swift?")
    }

    func testARefusedEditTurnsTheFailedStepIntoACard() {
        var step = ToolStep(id: "s1", kind: .edit, label: "Editing", detail: "a.swift", done: true)
        step.failed = true
        var message = applying([.step(step)])
        let refused = PermissionRequest(id: "p1", tool: "Edit", summary: "a.swift", filePath: "/x/a.swift", live: false)
        let effect = message.apply(.permissionRequest(refused), now: now)
        XCTAssertNil(effect.needsYou, "nothing is paused, so nobody is waiting")
        XCTAssertTrue(effect.activityChanged)
        XCTAssertEqual(message.steps[0].label, "Wants to edit")
        XCTAssertFalse(message.steps[0].failed)

        // A later update of the same step keeps the relabel.
        message.apply(.step(step), now: now)
        XCTAssertEqual(message.steps[0].label, "Wants to edit")
        XCTAssertFalse(message.steps[0].failed)
    }

    func testAQuestionAsksForTheUserAndACancelExpiresIt() {
        var message = answer()
        let item = AgentQuestion.Item(question: "Which one?", header: "Pick", options: [], multiSelect: false)
        let effect = message.apply(.question(AgentQuestion(id: "q1", items: [item])), now: now)
        XCTAssertEqual(effect.needsYou, "Which one?")
        message.apply(.permissionRequest(PermissionRequest(id: "p1", tool: "Bash", summary: "ls")), now: now)

        XCTAssertTrue(message.apply(.requestCancelled("q1"), now: now).activityChanged)
        XCTAssertEqual(message.questions[0].status, .expired)
        XCTAssertEqual(message.permissions[0].status, .pending)
        message.apply(.requestCancelled("p1"), now: now)
        XCTAssertEqual(message.permissions[0].status, .expired)
    }

    func testSubagentsStartReportAndFinish() {
        let helper = Subagent(id: "a1", type: "Explore", task: "look around")
        let message = applying([.subagentStarted(helper), .subagentStarted(helper), .subagentActivity(id: "a1", current: "Reading"),
                                .subagentFinished(id: "a1", failed: true)])
        XCTAssertEqual(message.subagents.count, 1)
        XCTAssertEqual(message.subagents[0].current, "Reading")
        XCTAssertEqual(message.subagents[0].status, .failed)
        XCTAssertEqual(message.subagents[0].endedAt, now)
    }

    func testTheSameFileChangeIsReplacedAndAnotherIsAdded() {
        var change = FileChange(id: "c1", path: "/x/a.swift")
        var message = applying([.fileChange(change)])
        change.added = 3
        message = applying([.fileChange(change), .fileChange(FileChange(id: "c2", path: "/x/a.swift"))], to: message)
        XCTAssertEqual(message.changes.map(\.id), ["c1", "c2"])
        XCTAssertEqual(message.changes[0].added, 3)
    }

    func testTelemetryLeavesTheAnswerAlone() {
        let before = answer()
        let after = applying([.log(.info, "x"), .raw("{}"), .plan([RunPlanStep(text: "a", status: .active)])], to: before)
        XCTAssertEqual(after, before)
    }

    func testSettlingExpiresWhatWasWaitingAndFinishesHelpers() {
        var message = applying([
            .permissionRequest(PermissionRequest(id: "live", tool: "Bash", summary: "ls")),
            .permissionRequest(PermissionRequest(id: "refused", tool: "Edit", summary: "a.swift", live: false)),
            .question(AgentQuestion(id: "q1", items: [])),
            .subagentStarted(Subagent(id: "a1", type: "Explore", task: "t")),
        ])
        message.settle(now: now)
        XCTAssertEqual(message.permissions.map(\.status), [.expired, .pending], "a refused request can still be approved with a new run")
        XCTAssertEqual(message.questions[0].status, .expired)
        XCTAssertEqual(message.subagents[0].status, .done)
        XCTAssertEqual(message.subagents[0].endedAt, now)
    }

    // MARK: The chat

    func testTheSessionIsKeptOnTheChatAndEventsReachOnlyTheAnswer() {
        var conversation = Conversation(provider: .claudeCode)
        let question = Message(role: .user, author: "You", text: "hi")
        let reply = answer()
        conversation.messages = [question, reply]
        conversation.apply(.session("abc"), answerID: reply.id)
        conversation.apply(.text("hello"), answerID: reply.id)
        conversation.apply(.text("lost"), answerID: UUID())
        XCTAssertEqual(conversation.cliSessionID, "abc")
        XCTAssertEqual(conversation.messages.map(\.text), ["hi", "hello"])
    }

    // MARK: The activity pane

    func testThePaneTakesTelemetryAndSharedEventsButNotText() {
        var terminal = TerminalState()
        let events: [ProviderEvent] = [
            .text("answer"), .log(.info, "started"), .log(.info, ""), .raw("{}"),
            .plan([RunPlanStep(text: "a", status: .active)]),
            .subagentStarted(Subagent(id: "a1", type: "Explore", task: "t")), .subagentFinished(id: "a1", failed: false),
            .fileChange(FileChange(id: "c1", path: "/x/a.swift")), .fileChange(FileChange(id: "c1", path: "/x/a.swift")),
            .warning("ended early"),
        ]
        for event in events { terminal.apply(event, now: now) }
        XCTAssertEqual(terminal.lines.map(\.text), ["started", "ended early"])
        XCTAssertEqual(terminal.rawLines.count, 1)
        XCTAssertEqual(terminal.plan.count, 1)
        XCTAssertEqual(terminal.subagents.map(\.status), [.done])
        XCTAssertEqual(terminal.changes.count, 1)

        XCTAssertFalse(ProviderEvent.text("x").concernsTerminal)
        XCTAssertFalse(ProviderEvent.log(.info, "").concernsTerminal)
        XCTAssertTrue(ProviderEvent.warning("x").concernsTerminal)
        XCTAssertFalse(ProviderEvent.warning("x").isTelemetry, "a warning shows in both places")
    }

    func testANewRunKeepsTheLogAndTheVersionAndClearsTheRest() {
        var terminal = TerminalState()
        terminal.beginRun(level: .ask, now: now)
        terminal.run.cliVersion = "2.1"
        terminal.apply(.log(.info, "first run"), now: now)
        terminal.apply(.fileChange(FileChange(id: "c1", path: "/x/a.swift")), now: now)
        terminal.finishRun(.finished, now: now)
        XCTAssertEqual(terminal.run.phase, .finished)
        terminal.finishRun(.failed, now: now)
        XCTAssertEqual(terminal.run.phase, .finished, "a finished run is not finished twice")

        terminal.beginRun(level: .readOnly, now: now)
        XCTAssertEqual(terminal.run.phase, .starting)
        XCTAssertEqual(terminal.run.level, .readOnly)
        XCTAssertEqual(terminal.run.cliVersion, "2.1")
        XCTAssertEqual(terminal.lines.map(\.text), ["first run", ""])
        XCTAssertTrue(terminal.changes.isEmpty)
    }

    // MARK: Auto routing

    func testARouteAnswerBecomesADecision() throws {
        let reply = #"{"answers":[{"name":"route","type":"choice","choice":"code","confidence":0.874},{"name":"folder","type":"choice","choice":"App"}]}"#
        let decision = try AutoRouter.decision(from: Data(reply.utf8))
        XCTAssertEqual(decision.route, .code)
        XCTAssertEqual(decision.folder, "app")
        XCTAssertEqual(decision.reason, "needs your files (87% sure)")
        XCTAssertFalse(decision.fellBack)

        let none = #"{"answers":[{"name":"route","type":"choice","choice":"quick"},{"name":"folder","type":"choice","choice":"(none)"}]}"#
        let quick = try AutoRouter.decision(from: Data(none.utf8))
        XCTAssertEqual(quick.route, .quick)
        XCTAssertNil(quick.folder)
    }

    func testARefusedRouteAnswerIsAFailedCall() {
        XCTAssertThrowsError(try AutoRouter.decision(from: Data(#"{"answers":[{"name":"route","type":"refusal"}]}"#.utf8)))
        XCTAssertThrowsError(try AutoRouter.decision(from: Data("{}".utf8)))
    }

    func testFolderIntentOverridesQuickAndSurvivesAPIFailure() {
        let shortcut = FolderShortcut(id: UUID(), name: "contextdrop", path: "/projects/ContextDrop")
        for prediction in [RouteDecision(route: .quick, reason: "general"), .fallback] {
            for question in ["explain ContextDrop", "review /contextdrop", "summarize /projects/ContextDrop"] {
                let result = AutoRouter.resolve(prediction, question: question, shortcuts: [shortcut], selectedFolder: nil,
                    availableCLIs: [.claudeCode, .codex], preferredCLI: .codex, chooseCLIByTask: false)
                XCTAssertEqual(result.route, .code)
                XCTAssertEqual(result.provider, .codex)
                XCTAssertEqual(result.folder, shortcut.name)
                XCTAssertEqual(result.fellBack, prediction.fellBack)
            }
        }
        let selected = AutoRouter.resolve(.fallback, question: "explain this", shortcuts: [], selectedFolder: "/projects/new",
            availableCLIs: [.codex], preferredCLI: .claudeCode, chooseCLIByTask: false)
        XCTAssertEqual(selected.route, .code)
        XCTAssertEqual(selected.provider, .codex)
    }

    func testFolderMatchingDoesNotMatchInsideOtherNamesOrTrustUnknownChoices() {
        let prediction = RouteDecision(route: .quick, folder: "invented", reason: "general")
        let result = AutoRouter.resolve(prediction, question: "what is application design?",
            shortcuts: [FolderShortcut(id: UUID(), name: "app", path: "/projects/app")], selectedFolder: nil,
            availableCLIs: [.codex], preferredCLI: .codex, chooseCLIByTask: false)
        XCTAssertEqual(result.route, .quick)
        XCTAssertNil(result.folder)
        XCTAssertEqual(result.provider, .openAI)
    }

    func testSemanticFolderChoiceAlsoFavorsCodeButNeedsAReadyCLI() {
        let shortcut = FolderShortcut(id: UUID(), name: "app", path: "/projects/app")
        let prediction = RouteDecision(route: .quick, folder: "app", reason: "general")
        for available: [ProviderKind] in [[.codex], []] {
            let result = AutoRouter.resolve(prediction, question: "explain my project", shortcuts: [shortcut], selectedFolder: nil,
                availableCLIs: available, preferredCLI: .codex, chooseCLIByTask: false)
            XCTAssertEqual(result.route, available.isEmpty ? .quick : .code)
            XCTAssertEqual(result.provider, available.isEmpty ? .openAI : .codex)
        }
    }

    func testTaskPreferenceOnlySelectsAnAvailableCLIWhenEnabled() throws {
        let data = Data(#"{"answers":[{"name":"route","type":"choice","choice":"code"},{"name":"cli","type":"choice","choice":"codex"}]}"#.utf8)
        let prediction = try AutoRouter.decision(from: data)
        XCTAssertEqual(prediction.provider, .codex)
        for enabled in [false, true] {
            let result = AutoRouter.resolve(prediction, question: "debug this", shortcuts: [], selectedFolder: nil,
                availableCLIs: [.claudeCode, .codex], preferredCLI: .claudeCode, chooseCLIByTask: enabled)
            XCTAssertEqual(result.provider, enabled ? .codex : .claudeCode)
        }
        let unavailable = AutoRouter.resolve(prediction, question: "debug this", shortcuts: [], selectedFolder: nil,
            availableCLIs: [.claudeCode], preferredCLI: .codex, chooseCLIByTask: true)
        XCTAssertEqual(unavailable.provider, .claudeCode)
        let refused = try AutoRouter.decision(from: Data(#"{"answers":[{"name":"route","type":"choice","choice":"code"},{"name":"cli","type":"refusal"}]}"#.utf8))
        let fallback = AutoRouter.resolve(refused, question: "debug this", shortcuts: [], selectedFolder: nil,
            availableCLIs: [.claudeCode, .codex], preferredCLI: .codex, chooseCLIByTask: true)
        XCTAssertEqual(fallback.provider, .codex)
        XCTAssertThrowsError(try AutoRouter.decision(from: Data(#"{"answers":[{"name":"route","type":"choice","choice":"unknown"}]}"#.utf8)))
    }

    func testTaskPreferencesShareTheRoutingRequestOnlyWhenEnabledAndUseful() {
        for available: [ProviderKind] in [[.codex], [.claudeCode, .codex]] {
            for preferences: String? in [nil, "Codex for debugging"] {
                let body = AutoRouter.body(question: "debug", shortcuts: [], defaultFolder: nil,
                    selectedFolder: "/project", availableCLIs: available, preferredCLI: .codex, workPreferences: preferences)
                let questions = body["questions"] as! [[String: Any]]
                let cli = questions.first { $0["name"] as? String == "cli" }
                XCTAssertEqual(cli != nil, available.count > 1 && preferences != nil)
                XCTAssertTrue((questions[0]["instructions"] as! String).contains("/project"))
                if let cli {
                    XCTAssertTrue((cli["instructions"] as! String).contains(preferences!))
                    XCTAssertEqual((cli["choices"] as! [[String: String]]).map { $0["value"]! }, available.map(\.rawValue))
                }
            }
        }
    }

    func testPreferredCLIMigratesOnceAndStaysIndependentOfManualProvider() {
        let defaults = UserDefaults.standard
        let keys = [AppDefaults.preferredCLIKey, AppDefaults.providerKey,
                    AppDefaults.routeCLIByTaskKey, AppDefaults.cliWorkPreferencesKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: AppDefaults.preferredCLIKey)
        AppDefaults.provider = .codex
        XCTAssertEqual(AppDefaults.preferredCLI, .codex)
        AppDefaults.provider = .openAI
        XCTAssertEqual(AppDefaults.preferredCLI, .codex)
        AppDefaults.preferredCLI = .claudeCode
        AppDefaults.preferredCLI = .openAI
        XCTAssertEqual(AppDefaults.preferredCLI, .claudeCode)
        AppDefaults.routeCLIByTask = true
        AppDefaults.cliWorkPreferences = "Codex for debugging"
        XCTAssertTrue(AppDefaults.routeCLIByTask)
        XCTAssertEqual(AppDefaults.cliWorkPreferences, "Codex for debugging")
    }

    func testFolderChoicesAreOnlyOfferedWhenThereAreShortcuts() {
        let body = AutoRouter.body(question: "why does my build fail", shortcuts: [], defaultFolder: nil)
        XCTAssertEqual((body["questions"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(body["model"] as? String, AutoRouter.model)
    }
}
