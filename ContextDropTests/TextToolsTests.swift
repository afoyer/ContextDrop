import XCTest
@testable import ContextDrop

/// The pure text helpers: diffs, edit previews, secret masking, summary parsing, chat titles.
final class TextToolsTests: XCTestCase {
    // MARK: LineDiff

    func testIdenticalTextsHaveNoHunks() {
        XCTAssertTrue(LineDiff.hunks(old: "a\nb", new: "a\nb").isEmpty)
        XCTAssertTrue(LineDiff.hunks(old: "a\n", new: "a").isEmpty, "a trailing newline alone is not a change")
    }

    func testAChangedLineIsOneRemovalAndOneAddition() {
        let hunks = LineDiff.hunks(old: "one\ntwo\nthree", new: "one\n2\nthree")
        XCTAssertEqual(hunks.count, 1)
        let counts = LineDiff.counts(hunks)
        XCTAssertEqual(counts.added, 1)
        XCTAssertEqual(counts.removed, 1)
        XCTAssertEqual(hunks[0].lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(hunks[0].lines.first { $0.kind == .added }?.newNumber, 2)
    }

    func testANewFileIsAllAdditions() {
        let counts = LineDiff.counts(LineDiff.hunks(old: "", new: "a\nb\nc"))
        XCTAssertEqual(counts.added, 3)
        XCTAssertEqual(counts.removed, 0)
    }

    func testParseUnifiedReadsGitDiffOutput() {
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,3 @@
         one
        -two
        +2
         three
        """
        let files = LineDiff.parseUnified(diff)
        XCTAssertEqual(files.map(\.path), ["Sources/App.swift"])
        let counts = LineDiff.counts(files[0].hunks)
        XCTAssertEqual(counts.added, 1)
        XCTAssertEqual(counts.removed, 1)
    }

    // MARK: EditPreview

    func testEditPreviewAppliesAnEditToTheCurrentFile() {
        let texts = EditPreview.texts(tool: "Edit", input: ["old_string": "two", "new_string": "2"], current: "one\ntwo\nthree")
        XCTAssertEqual(texts?.before, "one\ntwo\nthree")
        XCTAssertEqual(texts?.after, "one\n2\nthree")
    }

    func testEditPreviewFallsBackToTheSnippetsWhenTheFileDoesNotMatch() {
        let texts = EditPreview.texts(tool: "Edit", input: ["old_string": "missing", "new_string": "new"], current: "something else")
        XCTAssertEqual(texts?.before, "missing")
        XCTAssertEqual(texts?.after, "new")
    }

    func testEditPreviewWriteReplacesEverything() {
        let texts = EditPreview.texts(tool: "Write", input: ["content": "new"], current: "old")
        XCTAssertEqual(texts?.before, "old")
        XCTAssertEqual(texts?.after, "new")
    }

    func testEditPreviewUndoesAMultiEditThatAlreadyRan() {
        let input: [String: Any] = ["edits": [["old_string": "a", "new_string": "b"], ["old_string": "x", "new_string": "y"]]]
        let texts = EditPreview.reversed(tool: "MultiEdit", input: input, current: "b y")
        XCTAssertEqual(texts?.before, "a x")
        XCTAssertEqual(texts?.after, "b y")
    }

    // MARK: SecretMasker

    func testSecretsAreHidden() {
        let fakeKey = "sk-" + String(repeating: "a1B2", count: 8)
        let cases: [(input: String, secret: String)] = [
            ("OPENAI_API_KEY=\(fakeKey)", fakeKey),
            ("export GITHUB_TOKEN=ghp_" + String(repeating: "x", count: 36), "ghp_xxxx"),
            ("curl -H \"Authorization: Bearer abcdef1234567890\" https://example.com", "abcdef1234567890"),
            ("db_password: \"hunter2-very-secret\"", "hunter2"),
            ("postgres://admin:s3cretpass@db.local/app", "s3cretpass"),
            ("Compiling… \(fakeKey) done", fakeKey),
            ("AKIAIOSFODNN7EXAMPLE in config", "AKIAIOSFODNN7EXAMPLE"),
        ]
        for (input, secret) in cases {
            XCTAssertFalse(SecretMasker.mask(input).contains(secret), input)
        }
    }

    func testEnvFileLinesAreHiddenWhole() {
        XCTAssertFalse(SecretMasker.mask("FOO=bar", envFile: true).contains("bar"))
        XCTAssertTrue(SecretMasker.looksLikeEnv("cat .env.local"))
        XCTAssertFalse(SecretMasker.looksLikeEnv("cat environment.md"))
    }

    func testPlainLinesAreLeftAlone() {
        XCTAssertEqual(SecretMasker.mask("Edit Views/DecisionCard.swift +18"), "Edit Views/DecisionCard.swift +18")
    }

    // MARK: Summary drafts, titles, models

    func testSummaryDraftAcceptsEitherKeyStyleAndIsTrimmed() throws {
        let raw = """
        Here you go: {"title":"T","summary":"  Where it stands.  ","decisions":["  a ",""],"open_questions":["q1","q2","q3","q4","q5"],"keyFacts":["f"]}
        """
        let draft = try OpenAIClient.parseDraft(raw)
        XCTAssertEqual(draft.summary, "Where it stands.")
        XCTAssertEqual(draft.decisions, ["a"])
        XCTAssertEqual(draft.openQuestions.count, 4)
        XCTAssertEqual(draft.keyFacts, ["f"])
    }

    func testSummaryDraftWithoutASummaryIsRefused() {
        XCTAssertThrowsError(try OpenAIClient.parseDraft(#"{"title":"T","summary":""}"#))
        XCTAssertThrowsError(try OpenAIClient.parseDraft("no json here"))
    }

    func testReasoningModels() {
        XCTAssertTrue(OpenAIClient.isReasoningModel("gpt-5-mini"))
        XCTAssertTrue(OpenAIClient.isReasoningModel("o3"))
        XCTAssertFalse(OpenAIClient.isReasoningModel("gpt-4.1-mini"))
    }

    @MainActor
    func testChatTitleIsTheFirstSixWords() {
        XCTAssertEqual(ChatStore.title(from: "why does the build fail on my other mac today?"), "Why does the build fail on")
        XCTAssertEqual(ChatStore.title(from: "   "), "New chat")
    }

    func testPermissionRuleNamesTheProgramForShellCommands() {
        let bash = PermissionRequest(id: "1", tool: "Bash", summary: "git push origin main")
        XCTAssertEqual(bash.rule, "Bash:git")
        let edit = PermissionRequest(id: "2", tool: "Edit", summary: "a.swift", filePath: "/x/a.swift")
        XCTAssertEqual(edit.rule, "Edit")
        XCTAssertTrue(edit.isEdit)
        XCTAssertEqual(edit.fileName, "a.swift")
    }
}
