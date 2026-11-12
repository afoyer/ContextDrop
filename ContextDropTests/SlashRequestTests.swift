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
}
