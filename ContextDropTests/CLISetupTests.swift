import XCTest
@testable import ContextDrop

/// Setup's install and sign-in plumbing: what it would run, and what it shows when something fails.
final class CLISetupTests: XCTestCase {
    func testEveryCodingCLICanBeInstalledAndSignedIn() {
        for kind in ProviderKind.deep {
            let agent = CLISetup.agent(for: kind)
            XCTAssertNotNil(agent, "\(kind) has no CLI agent")
            XCTAssertFalse(agent?.installOptions.isEmpty ?? true, "\(kind) has no install option")
            XCTAssertFalse(agent?.signInArguments.isEmpty ?? true, "\(kind) has no sign-in")
        }
        XCTAssertNil(CLISetup.agent(for: .openAI))
    }

    func testCodexPrefersHomebrewOverNpm() {
        let options = CodexAgent().installOptions
        XCTAssertEqual(options.map(\.requires), ["brew", "npm"])
    }

    func testManualCommandsListEveryInstallOptionThenSignIn() {
        let codex = CLISetup.manualCommands(for: CodexAgent()).split(separator: "\n").map(String.init)
        XCTAssertEqual(codex, ["brew install --cask codex", "# or, with npm:", "npm install -g @openai/codex", "codex login"])

        let claude = CLISetup.manualCommands(for: ClaudeCodeAgent()).split(separator: "\n").map(String.init)
        XCTAssertEqual(claude.last, "claude auth login")
        XCTAssertEqual(claude.count, 2)
    }

    func testTailKeepsTheLastLinesOfBothStreams() {
        let result = CLIRunner.Captured(output: "one\ntwo\n", error: "\n  warning  \nfatal: no\n", status: 1)
        XCTAssertEqual(CLISetup.tail(result), "two\nwarning\nfatal: no")
        XCTAssertNil(CLISetup.tail(CLIRunner.Captured(output: " \n", error: "", status: 1)))
    }

    func testSignInReportsAProcessThatFails() async {
        let job = SetupJob()
        let result = await job.run("/bin/sh", ["-c", "echo nope >&2; exit 3"], env: [:], timeout: 5)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(CLISetup.tail(result), "nope")
    }

    func testCancelledJobStopsItsProcess() async {
        let job = SetupJob()
        let started = Date()
        async let result = job.run("/bin/sleep", ["30"], env: [:], timeout: 60)
        try? await Task.sleep(for: .milliseconds(300))
        job.cancel()
        _ = await result
        XCTAssertTrue(job.isCancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
