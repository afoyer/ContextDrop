import XCTest
@testable import ContextDrop

/// How much of a run the room sees: "Live run" leaves the log out, "Live run + log" sends all of it.
final class RoomShareLevelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100)

    private func sampleRun() -> RoomRunTile {
        var run = RoomRunTile(ownerName: "Alice", agent: "Codex", title: "Fix the login", folder: "~/p")
        run.state = .waiting("Waiting for Alice to approve an edit to Auth.swift")
        run.startedAt = t0
        run.endedAt = t0.addingTimeInterval(30)
        run.plan = [RunPlanStep(text: "Read Auth.swift", status: .done), RunPlanStep(text: "Fix the check", status: .active)]
        run.subagents = [RunSubagentInfo(type: "Explore", task: "Find callers", running: true)]
        run.changes = [RunChangeInfo(path: "Auth.swift", added: 4, removed: 1)]
        run.log = [RunLogLine(seq: 7, text: "› swift build"), RunLogLine(seq: 8, text: "  Build complete")]
        run.summary = "Fixed it."
        return run
    }

    func testStepsLeavesTheLogOut() {
        XCTAssertTrue(RoomRunBroadcaster.applying(.steps, to: sampleRun()).log.isEmpty)
    }

    func testStepsKeepsEverythingElse() {
        let original = sampleRun()
        var shown = RoomRunBroadcaster.applying(.steps, to: original)
        XCTAssertEqual(shown.ownerName, original.ownerName)
        XCTAssertEqual(shown.agent, original.agent)
        XCTAssertEqual(shown.title, original.title)
        XCTAssertEqual(shown.folder, original.folder)
        XCTAssertEqual(shown.state, original.state)
        XCTAssertEqual(shown.startedAt, original.startedAt)
        XCTAssertEqual(shown.endedAt, original.endedAt)
        XCTAssertEqual(shown.plan, original.plan)
        XCTAssertEqual(shown.subagents, original.subagents)
        XCTAssertEqual(shown.changes, original.changes)
        XCTAssertEqual(shown.summary, original.summary)
        // Nothing but the log differs.
        shown.log = original.log
        XCTAssertEqual(shown, original)
    }

    func testWithLogSendsEverything() {
        let original = sampleRun()
        XCTAssertEqual(RoomRunBroadcaster.applying(.withLog, to: original), original)
    }

    func testChangingTheLevelChangesWhatIsSent() {
        let original = sampleRun()
        // The broadcaster only sends a summary that differs from the last one, so turning the log off must differ.
        XCTAssertNotEqual(RoomRunBroadcaster.applying(.steps, to: original), RoomRunBroadcaster.applying(.withLog, to: original))
        // Turning it back on sends the lines with their original numbers, so watchers stitch them on.
        XCTAssertEqual(RoomRunBroadcaster.applying(.withLog, to: original).log.map(\.seq), [7, 8])
    }

    func testARunWithNoLogLooksTheSameAtEitherLevel() {
        var original = sampleRun()
        original.log = []
        XCTAssertEqual(RoomRunBroadcaster.applying(.steps, to: original), RoomRunBroadcaster.applying(.withLog, to: original))
    }
}
