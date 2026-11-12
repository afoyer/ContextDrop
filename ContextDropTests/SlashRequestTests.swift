import XCTest
@testable import ContextDrop

/// What a chain of slash commands asks for, read the same way from the home input and from a chat.
final class SlashRequestTests: XCTestCase {
    private let here = FolderShortcut(id: UUID(), name: "tmp", path: NSTemporaryDirectory())
    private let gone = FolderShortcut(id: UUID(), name: "gone", path: "/nowhere/\(UUID().uuidString)")

    func testNoCommandsIsEmptyAndKeepsTheQuestion() {
        let request = SlashRequest(commands: [], rest: "why?")
        XCTAssertTrue(request.isEmpty)
        XCTAssertEqual(request.rest, "why?")
        XCTAssertNil(request.stop)
    }

    func testSkillsAreCollectedOnceInOrder() {
        let request = SlashRequest(commands: [.skill("pdf"), .skill("xlsx"), .skill("pdf")], rest: "")
        XCTAssertEqual(request.skills, ["pdf", "xlsx"])
        XCTAssertFalse(request.isEmpty)
    }

    func testTheLastProviderWinsAndAutoOnlyCountsAfterIt() {
        XCTAssertEqual(SlashRequest(commands: [.provider(.codex), .provider(.claudeCode)], rest: "").provider, .claudeCode)

        let autoLast = SlashRequest(commands: [.provider(.codex), .auto], rest: "")
        XCTAssertTrue(autoLast.auto)
        XCTAssertEqual(autoLast.provider, .codex)

        let providerLast = SlashRequest(commands: [.auto, .provider(.openAI)], rest: "")
        XCTAssertFalse(providerLast.auto)
        XCTAssertEqual(providerLast.provider, .openAI)
    }

    func testTheLastFolderWins() {
        let other = FolderShortcut(id: UUID(), name: "root", path: "/")
        XCTAssertEqual(SlashRequest(commands: [.folder(here), .folder(other)], rest: "q").folder, other)
    }

    func testAMissingFolderStopsTheChain() {
        let request = SlashRequest(commands: [.skill("pdf"), .folder(gone), .provider(.codex)], rest: "q")
        XCTAssertEqual(request.stop, .missingFolder(gone))
        XCTAssertEqual(request.skills, ["pdf"])
        XCTAssertNil(request.provider, "nothing after the stop counts")
        XCTAssertNil(request.folder)
    }

    func testAnActionStopsTheChainAndKeepsWhatCameBefore() {
        let request = SlashRequest(commands: [.folder(here), .action(.share), .skill("pdf")], rest: "")
        XCTAssertEqual(request.stop, .action(.share))
        XCTAssertEqual(request.folder, here)
        XCTAssertTrue(request.skills.isEmpty)

        XCTAssertEqual(SlashRequest(commands: [.addFolder], rest: "").stop, .addFolder)
    }

    @MainActor
    func testADraftIsParsedIntoARequest() {
        let request = SlashRequest(draft: "  /codex /share later", folders: FolderShortcutStore())
        XCTAssertEqual(request.provider, .codex)
        XCTAssertEqual(request.stop, .action(.share))
        XCTAssertEqual(request.rest, "later")

        let plain = SlashRequest(draft: "what is /usr/bin?", folders: FolderShortcutStore())
        XCTAssertTrue(plain.isEmpty)
        XCTAssertEqual(plain.rest, "what is /usr/bin?")
    }

    @MainActor
    func testAgentCommandAloneRequiresFolderSelection() {
        for provider in ProviderKind.deep {
            withPanel { model in
                var requested: UUID?
                model.actions.chooseFolder = { requested = $0 } // Simulate canceling the picker.
                model.draft = "/\(provider.slashTokens[0])"
                model.submitFromHome()

                XCTAssertNotNil(requested)
                XCTAssertEqual(model.panelConversationID, requested)
                XCTAssertEqual(model.store.conversation(requested)?.provider, provider)
                XCTAssertNil(model.store.conversation(requested)?.folder)
                XCTAssertTrue(model.store.conversation(requested)?.messages.isEmpty == true)
            }
        }
    }

    @MainActor
    func testAgentPromptDoesNotReuseDefaultOrLastFolder() {
        for provider in ProviderKind.deep {
            withPanel { model in
                AppDefaults.folder = here.url
                AppDefaults.lastFolder = here.url
                var requests: [UUID] = []
                model.actions.chooseFolder = { requests.append($0) }
                model.draft = "/\(provider.slashTokens[0]) explain this project"
                model.submitFromHome()

                guard let id = model.panelConversationID else { return XCTFail("Expected a chat") }
                XCTAssertEqual(requests, [id])
                XCTAssertNil(model.store.conversation(id)?.folder)
                XCTAssertEqual(model.store.conversation(id)?.messages.last?.text, "explain this project")
                XCTAssertFalse(model.store.isRunning(id))

                model.session(id).draft = "try again"
                model.submitInChat(id)
                XCTAssertEqual(requests, [id, id], "Canceling must not bypass folder selection")
                XCTAssertEqual(model.session(id).draft, "try again")
                XCTAssertFalse(model.store.isRunning(id))
            }
        }
    }

    @MainActor
    func testAgentCommandKeepsAnExplicitHomeFolder() {
        withPanel { model in
            model.homeFolder = here
            model.actions.chooseFolder = { _ in XCTFail("A folder was already selected") }
            model.draft = "/codex"
            model.submitFromHome()
            XCTAssertEqual(model.store.conversation(model.panelConversationID)?.folder, here.url)
        }
    }

    @MainActor
    func testCompletingAnAgentStartsFolderSelection() {
        for token in ["clau", "code"] {
            withPanel { model in
                var requested: UUID?
                model.actions.chooseFolder = { requested = $0 }
                model.draft = "/\(token)"
                model.completeSlash()
                XCTAssertNotNil(requested)
                XCTAssertEqual(model.panelConversationID, requested)
            }
        }
    }

    @MainActor
    private func withPanel(_ body: (PanelModel) -> Void) {
        let provider = AppDefaults.provider
        let autoRoute = AppDefaults.autoRoute
        let folder = AppDefaults.folder
        let lastFolder = AppDefaults.lastFolder
        defer {
            AppDefaults.provider = provider
            AppDefaults.autoRoute = autoRoute
            AppDefaults.folder = folder
            AppDefaults.lastFolder = lastFolder
        }
        let store = ChatStore(peers: PeerService(notices: NoticeCenter()))
        body(PanelModel(store: store))
        store.stopAll()
    }
}
