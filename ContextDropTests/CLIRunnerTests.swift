import XCTest
@testable import ContextDrop

/// `CLIRunner` end to end with a stand-in CLI (`/bin/sh`): the process, its pipes, the parser hooks and
/// what a clean exit, a failure and Stop turn into. No real agent and no account is involved.
final class CLIRunnerTests: XCTestCase {
    /// Runs a shell script as if it were an agent. Every line it prints is one piece of answer text.
    private struct ShellAgent: CLIAgent {
        let kind = ProviderKind.codex
        let executableName = "sh"
        var script: String
        var readsStdin = false

        func signInStatus(executable: String, environment: [String: String]) async -> ProviderStatus { .ready("sh") }
        func arguments(for request: CLIRunner.Request) -> [String] { ["-c", script] }
        func openingInput(for request: CLIRunner.Request) -> [String: Any]? { readsStdin ? ["prompt": request.prompt] : nil }
        func makeParser(for request: CLIRunner.Request) -> any CLIParser { LineEcho() }
        func retry(afterApproving what: String) -> ApprovedRetry { ApprovedRetry(prompt: what, level: .ask, asksAgain: false) }
    }

    private struct LineEcho: CLIParser {
        var producedOutput = false
        var failure: String?
        var turnStarted = false
        var finished = false

        mutating func parse(_ line: String) -> [ProviderEvent] {
            turnStarted = true
            if line == "DONE" { finished = true; return [] }
            if line.hasPrefix("FAIL ") { failure = String(line.dropFirst(5)); return [] }
            producedOutput = true
            return [.text(line)]
        }

        func afterExit(stderr: String) -> [ProviderEvent] {
            stderr.contains("note") ? [.warning("saw stderr")] : []
        }
    }

    private var request: CLIRunner.Request {
        CLIRunner.Request(folder: FileManager.default.temporaryDirectory, prompt: "hello", level: .ask)
    }

    private func collect(_ agent: ShellAgent, handle: CLIRunner.Handle = CLIRunner.Handle()) async throws -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        for try await event in CLIRunner.run(agent, request, handle: handle) { events.append(event) }
        return events
    }

    func testOutputLinesBecomeEventsAndTheExitCodeIsReported() async throws {
        let events = try await collect(ShellAgent(script: "echo one; echo two; echo note >&2"))
        XCTAssertEqual(events.texts, ["one", "two"])
        XCTAssertTrue(events.contains { if case .runInfo(let patch) = $0 { patch.exitCode == 0 } else { false } })
        XCTAssertTrue(events.contains { if case .warning("saw stderr") = $0 { true } else { false } }, "afterExit sees stderr")
        XCTAssertTrue(events.contains { if case .log(.stderr, "note", _) = $0 { true } else { false } })
    }

    func testTheOpeningInputArrivesOnStdinAndFinishedClosesIt() async throws {
        // `cat` would wait forever; it ends because the parser said the answer is complete.
        let events = try await collect(ShellAgent(script: "read line; echo \"$line\"; echo DONE; cat", readsStdin: true))
        XCTAssertEqual(events.texts, [#"{"prompt":"hello"}"#])
    }

    func testAFailingExitWithoutOutputThrowsTheEndOfStderr() async {
        do {
            _ = try await collect(ShellAgent(script: "echo 'no such model' >&2; exit 3"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.userMessage, "no such model")
            XCTAssertEqual((error as? ProviderError)?.failure, .agentStopped)
        }
    }

    func testAFailureReportedByTheParserIsThrown() async {
        do {
            _ = try await collect(ShellAgent(script: "echo 'FAIL rate limited'"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.userMessage, "rate limited")
        }
    }

    func testANonZeroExitAfterOutputIsOnlyAWarning() async throws {
        let events = try await collect(ShellAgent(script: "echo partial; exit 2"))
        XCTAssertEqual(events.texts, ["partial"])
        XCTAssertTrue(events.contains { if case .warning = $0 { true } else { false } })
    }

    func testStopEndsTheRunWithoutAnError() async throws {
        let handle = CLIRunner.Handle()
        let started = Date()
        var texts: [String] = []
        for try await event in CLIRunner.run(ShellAgent(script: "echo started; sleep 60"), request, handle: handle) {
            if case .text(let text) = event {
                texts.append(text)
                handle.interrupt()
            }
        }
        XCTAssertEqual(texts, ["started"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    func testAMissingExecutableSaysSo() async {
        struct Missing: CLIAgent {
            let kind = ProviderKind.codex
            let executableName = "contextdrop-no-such-cli"
            func signInStatus(executable: String, environment: [String: String]) async -> ProviderStatus { .ready("") }
            func arguments(for request: CLIRunner.Request) -> [String] { [] }
            func makeParser(for request: CLIRunner.Request) -> any CLIParser { LineEcho() }
            func retry(afterApproving what: String) -> ApprovedRetry { ApprovedRetry(prompt: what, level: .ask, asksAgain: false) }
        }
        let status = await CLIRunner.status(of: Missing())
        XCTAssertEqual(status, .notFound("contextdrop-no-such-cli CLI not found on this Mac"))
        do {
            for try await _ in CLIRunner.run(Missing(), request, handle: CLIRunner.Handle()) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.failure, .notInstalled)
        }
    }
}
