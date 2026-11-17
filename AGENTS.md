# AGENTS.md

Guidance for coding agents working in this repository. `README.md` is the user-facing reference (build, run on two Macs, architecture, extension recipes); this file covers what you need in order to change the code the way it is already written. When the two disagree, the code wins. Fix whichever document is wrong.

## What this is

ContextDrop is a native macOS menu bar app (Swift 6, SwiftUI + AppKit, Multipeer Connectivity, macOS 14+, Xcode 26.2). It offers a quick AI chat (OpenAI over HTTPS, or the local `claude` / `codex` CLIs run in a project folder) and hands curated context to nearby Macs with no server. It does this through one-off shares and through a shared **Room** canvas that is hosted by one Mac.

There are no Swift packages and no third-party dependencies. Use only Apple frameworks. Don't add a dependency without asking.

## Commands

```sh
# Build (Debug)
xcodebuild -project ContextDrop.xcodeproj -scheme ContextDrop -configuration Debug \
  -derivedDataPath build/DerivedData build

# Test. Add the signing overrides on a machine without the team's certificate, as CI does
xcodebuild test -project ContextDrop.xcodeproj -scheme ContextDrop -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=

# One test class
xcodebuild test ... -only-testing:ContextDropTests/RoomReducerTests

# Run named instances on one Mac (Room / sharing testing)
scripts/dev-run.sh Alice Bob
log stream --info --predicate 'subsystem == "edu.cmu.hackathon.ContextDrop"'

# Universal Release zip in dist/
scripts/package.sh
```

- `build/` and `dist/` are git-ignored outputs. Never commit them.
- `scripts/dev-run.sh` copies the app to a fresh `build/Run` path on each launch because mDNSResponder caches the Bonjour allow-list per app path. Use it rather than `open`-ing the DerivedData build when you test discovery.
- CI (`.github/workflows/macos-tests.yml`) runs the tests on every push and PR, on `macos-15` with Xcode 26.2 and signing disabled. Keep the tests green and runnable without signing, network, API keys or a signed-in CLI.

## Layout

```
ContextDrop/
  App/        AppDelegate (wires everything together, fills PanelActions), app entry, global hot key
  Models/     Value types and wire formats: Room.swift (RoomState, RoomTile, RoomMessage, RoomWire, RoomLimits), Wire.swift (shares)
  Providers/  ChatProvider protocol, ProviderKind, ProviderEvent, OpenAI clients; CLI/ holds the Claude Code and Codex adapters and CLIRunner
  Services/   Stateless or single-purpose helpers: PeerService (Multipeer), RoomService, Keychain, AppDefaults, NoticeCenter, SecretMasker, LineDiff, AutoRouter…
  Stores/     @Observable state owners (ChatStore, RoomStore, PanelModel, WorkspaceModel) and the pure reducers they call
  Views/      SwiftUI, grouped by surface: QuickChat, Room, Share, Receive, Setup, MenuBar, DeepChat
  Windows/    AppKit windows and panels that host the SwiftUI views
ContextDropTests/  XCTest unit tests (the app is the test host)
Config/Info.plist  Local Network usage text and the Bonjour service types
docs/room-protocol.md  Room protocol v4 and the agreed order for follow-up work
```

The Xcode project uses **file-system synchronized groups**. A new `.swift` file under `ContextDrop/` or `ContextDropTests/` joins the target automatically, so don't edit `project.pbxproj` to add files.

## Architecture rules

```
Views ──▶ PanelModel / WorkspaceModel ──▶ ChatStore ──▶ ChatProvider ──▶ OpenAIProvider · CLIProvider
              │                              │
              └── RoomStore ── RoomService ──┴── PeerService ──▶ Multipeer Connectivity
```

- **Stores hold state and side effects. Rules are pure functions in their own files, and each has tests.** Keep this split. When you add behavior, put the decision in a reducer or a pure helper and test it there. The store should only apply the result and do the I/O.
  - `ConversationReducer`: what a `ProviderEvent` does to a chat
  - `RoomReducer`: what a `RoomMessage` does to the room, and who may send it
  - `SlashRequest`: what a chain of `/commands` means
  - `RoomWire` / `RoomCodec`: the JSON wire format
  - Smaller ones: `RoomRunStart`, `RoomSizeLedger`, `LineDiff`, `SecretMasker`
- **Providers are opaque to `ChatStore`.** A provider takes a `ProviderRequest` and streams `ProviderEvent`s. `RunHandle` is its only control surface (cancel, answer a permission, answer a question). Don't special-case a provider in `ChatStore` or in the views. Describe it through `ProviderKind` properties instead. CLI-specific encoding stays in the `CLIAgent` / `CLIParser` for that CLI.
- **`ProviderKind.swift` holds every `switch` over providers.** Adding a case makes the compiler list them.
- **`PanelModel` reaches the rest of the app only through the `PanelActions` struct**, which `AppDelegate` fills in. Don't give it direct references to other stores.
- **The Room is host-authoritative (protocol v4).** Guests submit a change with an operation ID. The host checks it against `RoomReducer.apply`, applies it once and echoes it to everyone, the sender included. Order is decided by the host, not by client timestamps. Read `docs/room-protocol.md` before you touch room messages.
- Work this Mac must do when a room message arrives belongs in `RoomStore.afterApply`.
- `ChatRunCoordinator` keeps one run generation per conversation, so late events from a cancelled run can't change its replacement. Route room answers through `RoomAnswerProvider`.

The README's **Extending** section has step-by-step recipes for adding a coding-agent CLI, an API provider, a slash command and a room tile type. Follow them, including the test steps.

## Security and trust rules (do not weaken)

Nearby peers are **not cryptographically authenticated**, and everything a peer sends is untrusted.

- Run every incoming room payload through `sanitized()` and the caps in `RoomLimits`. A new tile body or field needs both.
- In `RoomReducer`, **stamp** authorship and ownership from the sender's member ID instead of believing what the message claims. A guest may only add tiles that are its own.
- Content from peers, rooms or imports goes to a provider **fenced off as reference material**. Escape angle brackets so it can't close the context markers, and tell the agent to treat it as untrusted and to report any embedded instructions. A coding run that carries room-supplied content is capped at **Ask before editing**.
- Follow-ups from another member wait for the owner's explicit **Run**. Files go only to the owner's Mac.
- The OpenAI key lives in the Keychain (`Services/Keychain.swift`, item `openai-api-key`) and never leaves this Mac. Mask secrets with `SecretMasker` before anything is shared or broadcast.
- The app is **not sandboxed** because it launches `claude` and `codex`. Be deliberate about anything that touches the user's files or spawns processes.

## Wire format and versioning

- New fields in `RoomWire` (and in share `Wire` types) must be **optional**, so older builds can decode the message.
- A change that older builds can't safely ignore requires bumping `RoomMessage.currentVersion` (`Models/Room.swift`, currently 4). Macs on a different version refuse the message. Update `docs/room-protocol.md` when the protocol changes.
- Each new `RoomMessage` case needs: its `RoomWire` fields (`init` and `message()`), its rule in `RoomReducer.apply`, a rule test in `RoomReducerTests` and a round-trip test in `RoomCodecTests`.

## Swift conventions

- **Swift 6 language mode with strict concurrency.** UI-facing types are `@MainActor`. Types that cross actors are `Sendable`. Lock-guarded classes such as `RunHandle` use `NSLock.withLock` and `@unchecked Sendable`. Prefer `async`/`await` and `AsyncThrowingStream` over GCD.
- **State uses the Observation framework** (`@Observable` final classes). Don't introduce `ObservableObject` or `@Published`.
- Rule namespaces are caseless `enum`s with `static func`s (`RoomReducer`, `AppDefaults`, `RoomLimits`).
- Value types (`struct` / `enum`) for models. Use `Codable` for anything that goes on the wire.
- Split a large type across files with extensions named `Type+Topic.swift` (`PanelModel+Slash.swift`, `RoomStore+StartRun.swift`).
- **Settings:** every `UserDefaults` key and its typed accessor go in `Services/AppDefaults.swift`, with keys prefixed `ContextDrop.`.
- **One-line user messages** go through `NoticeCenter`. The room window has its own `RoomStore.notice`.
- **Logging:** `os.Logger` with subsystem `edu.cmu.hackathon.ContextDrop` (see `p2pLog` in `PeerService.swift`). Don't use `print`.
- Name limits and magic numbers, as `RoomLimits` does, instead of inlining them.
- Indentation is 4 spaces. Long lines (~120–130 characters) are fine. Follow the surrounding file.

### Comments and docs

- Put a `///` doc comment on every type and on non-obvious members. Write it in **plain English and in terms of what the user sees or what the rule is**, for example: "The title of a chat tile until its first question names it." Say who calls the code and why, not how the code works line by line.
- Inline comments explain *why* (a macOS quirk, a security reason), never *what*.
- UI and docs name menus as `Settings › Providers`, use curly quotes and ellipses (`Continue…`), and show shortcuts as `⌘⇧S`.
- When you change user-visible behavior, an architecture rule or an extension step, update `README.md` (and `docs/room-protocol.md` if needed) in the same change.

## Tests

- XCTest (`final class …Tests: XCTestCase`, `@testable import ContextDrop`) with a `///` line saying what the suite covers. Use small private builder helpers for fixtures, fixed dates such as `Date(timeIntervalSince1970: 100)`, and named members (Alice hosts, Bob and Carol are guests).
- Tests cover the non-UI logic: parsers, reducers, codec, slash chains, `CLIRunner` (with `/bin/sh` standing in for an agent, so no account is used), diffs and masking. Don't write tests that need the network, a real CLI login, Multipeer or UI.
- The app is the test host and skips normal startup when `XCTestConfigurationFilePath` is set (`AppDelegate.isHostingTests`). Keep startup side effects behind that check.
- A new rule needs a test. A bug fix in a reducer or parser should come with a test that reproduces the bug.

## Git workflow

- `main` is the default branch. Work happens on `feature/<topic>` branches. Do multi-file refactors on their own `refactor/<topic>` branch, not on a feature branch.
- Commit only when asked. Don't push or open PRs unless asked.
- **Commit messages:** an imperative, sentence-case subject that describes the change as a user or reviewer would see it, with no `feat:`-style prefix and no trailing period. For example: "Bring the room window to the front when opened or dragged toward". For anything non-trivial, add a body: either short prose paragraphs or `- ` bullets, each saying what changed and why, in plain language and naming the types involved.
- Don't commit `build/`, `dist/`, `.DS_Store`, `xcuserdata/` or `.claude/`.

## Before you say you're done

1. Run the test command above. It must pass with signing disabled.
2. If you touched the Room or sharing, say whether you tested it on two instances (`scripts/dev-run.sh Alice Bob`) or only with unit tests.
3. Update the README and `docs/room-protocol.md` for anything they describe that you changed.
