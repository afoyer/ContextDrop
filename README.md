<p align="center">
  <img src="docs/logo.png" alt="ContextDrop logo" width="160">
</p>

# ContextDrop

*Think together, instantly.* A native macOS app (Swift 6, SwiftUI, Multipeer Connectivity) a menu bar AI chat (OpenAI, Claude Code, Codex) that hands curated context to nearby Macs with no server.

Requires macOS 14+. Built and tested with Xcode 26.2.

## Build

```sh
# Debug (or open ContextDrop.xcodeproj in Xcode and press ⌘R)
xcodebuild -project ContextDrop.xcodeproj -scheme ContextDrop -configuration Debug \
  -derivedDataPath build/DerivedData build

# Release, universal (Apple silicon + Intel), for copying to another Mac
xcodebuild -project ContextDrop.xcodeproj -scheme ContextDrop -configuration Release \
  -derivedDataPath build/DerivedData ONLY_ACTIVE_ARCH=NO build
# → build/DerivedData/Build/Products/Release/ContextDrop.app
```

## Run on two Macs

1. Build Release on Mac A. Copy `ContextDrop.app` to Mac B (AirDrop, USB, or zip), or build from source on Mac B.
2. On Mac B, if the app was copied: `xattr -dr com.apple.quarantine /path/to/ContextDrop.app`. It is ad-hoc signed, so Gatekeeper blocks it otherwise. You can also right-click → Open.
3. Launch on both Macs. When macOS asks to **find devices on your local network**, click **Allow**. If you clicked Don't Allow: System Settings › Privacy & Security › Local Network → enable ContextDrop.
4. Keep both Macs on the same Wi-Fi network, or at least with Wi-Fi and Bluetooth turned on (MPC can use peer-to-peer Wi-Fi). Some corporate or campus networks block Bonjour/mDNS between clients. If discovery fails there, use a phone hotspot or just leave both Macs' Wi-Fi on without joining a network.
5. Mac A: open a chat, press ⌘⇧S, choose what to keep, then pick Mac B. Mac B: **Continue** on the notification.

To change your name, open Settings › General.

### Two instances on one Mac (dev testing)

```sh
APP=build/DerivedData/Build/Products/Debug/ContextDrop.app
open -n "$APP" --args -ContextDrop.displayName Alice
open -n "$APP" --args -ContextDrop.displayName Bob
log stream --info --predicate 'subsystem == "edu.cmu.hackathon.ContextDrop"'
```

## Permissions, signing and entitlements

| Item | Where | Why |
|---|---|---|
| `NSLocalNetworkUsageDescription` | `Config/Info.plist` | Text for the Local Network prompt. Without it, discovery fails silently. |
| `NSBonjourServices` = `_ctxdrop._tcp`, `_ctxdrop._udp` | `Config/Info.plist` | Required on macOS 11+ to browse or advertise this service type. It must match the service type in `PeerService`. |

Signing is ad-hoc ("Sign to Run Locally", `CODE_SIGN_IDENTITY = "-"`), so no Apple Developer team is needed. To distribute without the quarantine step, set a `DEVELOPMENT_TEAM`, sign with a Developer ID certificate, and notarize.

## Architecture

```
Views (SwiftUI) ──▶ PanelModel / WorkspaceModel ──▶ ChatStore ──▶ ChatProvider ──▶ OpenAIProvider · CLIProvider (claude / codex)
                         │                             │
                         └── RoomStore ── RoomService ─┴── PeerService ──▶ Multipeer Connectivity
```

The stores hold state and talk to the network and to processes. The rules they follow are pure functions in their own files, each with tests:

| Rule | File | Called by |
|---|---|---|
| What a provider event does to a chat and its activity pane | `Stores/ConversationReducer.swift` | `ChatStore` |
| What a room message does to the table, and who may send it | `Stores/RoomReducer.swift` | `RoomStore` |
| What a chain of `/commands` asks for | `Models/SlashRequest.swift` | `PanelModel+Slash.swift` |
| How a room message looks as JSON | `RoomWire` in `Models/Room.swift` | `RoomCodec` |

- **Quick Chat** (`Windows/Panels.swift`, `Views/QuickChat`): the floating panel behind the global shortcut.
- **Workspace window** (`Windows/WorkspaceWindow.swift`): one chat per tab. Quick Chat shows the same tabs. ⌘T new, ⌘1–9 jump (window), ⌃Tab next that needs you, ⌘W close, ⌘⇧T reopen, ⌥⌘A activity, two-finger swipe sideways.
- **Panel** (`Stores/PanelModel.swift` and its `PanelModel+Attachments`, `+Slash`, `+Share` files): what Quick Chat shows and its keyboard logic. What it needs from the rest of the app is one `PanelActions` struct, filled in by `AppDelegate`.
- **Providers** (`Providers/ChatProvider.swift`): every provider answers through one protocol and streams `ProviderEvent`s back; `ChatStore` knows nothing else about it. `ProviderKind` describes each one to the UI (see [Extending](#extending)).
- **Coding agents** (`Providers/CLI/`): `CLIRunner` runs `claude -p` or `codex exec` in the chat's folder and reads their JSON events. Claude Code's permission prompts and questions come back over stdin/stdout (`--permission-prompt-tool stdio`), so a run pauses on a card in the chat until you Allow, Deny or answer. Codex has no live prompt: it runs read-only, and a blocked edit becomes a card that re-runs it with write access.
- **Permission level** per chat: Read-only, Ask before editing (default) or Edits allowed. The default is in Settings › Providers.
- **Changes**: every edit is shown as a diff in the chat and under Activity › Changes (`Services/LineDiff.swift`). For Codex the diff is `git diff` of the touched files against the last commit.
- **Delegation** (Settings › Providers, off by default): Claude Code may hand read-only side tasks to Codex with `codex exec --sandbox read-only`. Codex may call `claude -p` only with Edits allowed, because its read-only sandbox blocks Claude's sign-in; that also turns on network access inside Codex's sandbox.
- **Skills** (`Services/SkillCatalog.swift`): Claude Code skills from `~/.claude/skills`, the project and installed plugins appear in the `/` menu.
- **Menu bar** (`Windows/MenuBarController.swift`): what needs you, what is running, what arrived. Drop a file on the icon to ask about it (⌥ for a new tab).
- **Sharing** (`Services/PeerService.swift`, `Models/Wire.swift`): a share is a summary the sender curates, sent over an encrypted Multipeer session after the receiver accepts. Several tabs can go in one drop. `Services/ShareSummarizer.swift` writes the first draft; `SharePrep` holds the checklist and builds the share.
- **Room** (`Services/RoomService.swift`, `Stores/RoomStore.swift`, `Views/Room`): a shared canvas for people nearby. The Mac that opened it holds the state, checks every change against `RoomReducer` and relays it; the room ends when that Mac leaves.
- **OpenAI** (`Providers/OpenAIHTTP.swift`): one helper for authorized requests, errors and streamed replies, used by Chat Completions (`OpenAIClient`), Responses and Files (`OpenAIResponses`, room chats) and the Auto decision (`Services/AutoRouter.swift`).

The app is not sandboxed (it starts the `claude` and `codex` CLIs), and is ad-hoc signed.

## Tests

```sh
xcodebuild test -project ContextDrop.xcodeproj -scheme ContextDrop -derivedDataPath build/DerivedData
```

The tests in `ContextDropTests/` cover the parts that have no UI: the Claude Code and Codex output parsers, `CLIRunner` end to end (with `/bin/sh` standing in for an agent, so no account is used), the provider registry, the chat and room reducers, slash-command chains, the room wire format, the Auto decision's reply, diffs and secret masking. The app is the test host, and it skips its normal startup when it is only hosting tests.

## Extending

**Add a coding-agent CLI.** Three steps, no changes to `ChatStore` or the views:

1. Add a case to `ProviderKind` (`Providers/ProviderKind.swift`) and fill in its properties: name, `/token`s, whether it supports skills, what sharing it to a room makes, and so on. The compiler lists every `switch` that needs the new case, and they are all in that file.
2. Write a `CLIAgent` and a `CLIParser` (`Providers/CLI/CLIAgent.swift` documents both). The agent says how to start the CLI (executable name, arguments, what goes on stdin, how to check sign-in); the parser turns each line the CLI prints into `ProviderEvent`s. `CodexAgent.swift` is the shorter example. `CLIRunner` handles the process, the PATH, stopping and exit codes.
3. Add `CLIProvider(agent: YourAgent())` to `Providers.all` (`Providers/ChatProvider.swift`).

**Add an API provider.** Same step 1, then write a `ChatProvider` directly (`OpenAIProvider.swift` is about 70 lines): `status()` says whether it can answer, `run(_:handle:)` returns a stream of `ProviderEvent`s. Yielding `.text` is enough for a plain chat.

**What a provider can send back** is the `ProviderEvent` enum in `Providers/Provider.swift`: text, tool steps, permission requests, questions, subagents, file changes and activity-pane telemetry. The chat UI renders whichever of these arrive.

**Add a slash command.**

1. Give it a case in `SlashCommand` (or in `SlashAction`, if it just does something and sends nothing) and map its token in `SlashCommand.command(for:)`, both in `Services/FolderShortcuts.swift`. Add the token to `FolderShortcutStore.reserved` so a folder shortcut can't take the name.
2. List it in `SlashItem.matches` (same file) so it shows in the `/` menu.
3. Say what it means in a chain in `SlashRequest.init(commands:rest:)`: a new field, or a `Stop` if nothing should be sent after it. Add a case to `SlashRequestTests`.
4. Carry it out in `PanelModel+Slash.swift`: `submitFromHome` for the home input, `applySlash` for an open chat.

A new provider needs none of this: its `/token`s come from `ProviderKind.slashTokens`.

**Add a kind of room tile.**

1. Add the body type and a case to `RoomTileContent` (`Models/Room.swift`), with a `sanitized()` that cuts everything a peer sends down to size. The compiler then points at the switches in `RoomTile` (`ownerName`, `shortLabel`, `contextText`).
2. If people can change the tile after it is added, add a `RoomMessage` case for each change, its fields in `RoomWire` (`init` and `message()`, same file), and its rule in `RoomReducer.apply`: who may send it, and what is stamped from the sender's name rather than believed. Test the rule in `RoomReducerTests` and the round trip in `RoomCodecTests`.
3. In `RoomReducer`'s `.addTile` case, stamp who owns the new tile.
4. Draw it in `Views/Room/RoomCanvas.swift` (the tile switch is there), and decide what it contributes in `RoomTakeHomeSheet.swift` and as context for a room chat (`RoomChatEngine.swift`).
5. If this Mac has to do work when a message arrives (as the owner of a chat or run does), do it in `RoomStore.afterApply`.

New fields must be optional in `RoomWire`, and a change that older builds can't ignore needs a bump of `RoomMessage.currentVersion`: Macs on another version refuse the message.

Settings keys live in `Services/AppDefaults.swift`. One-line messages to the user go through `NoticeCenter`.

## Known limitations

- Peers are **not authenticated**: anyone nearby can claim any name. Accepting an offer or a room invitation is the only gate.
- Multipeer has no "declined" signal, so a drop that ends before the timeout is shown as declined.
- Chats are kept in memory only and are gone when the app quits.
- Room: thoughts, kept answers and notes only. No votes, linked actions, tasks, cursors or saving yet.
- Claude Code decides which shell commands are harmless (`ls`, `echo`…) and runs those without asking, even in "Ask before editing".

## AI providers

Each chat is answered by one of three providers:

| Provider | Runs | Used for |
|---|---|---|
| **OpenAI** (`Providers/OpenAIProvider.swift`, `OpenAIClient.swift`) | HTTPS to `api.openai.com/v1/chat/completions`, streamed over SSE | Quick answers with no file access and share summaries (Chat Completions); the Auto decision (Decisions API) |
| **Claude Code** (`Providers/CLI/ClaudeCodeAgent.swift`) | The local `claude` CLI, inside a project folder | Questions that need your files, repo or terminal |
| **Codex** (`Providers/CLI/CodexAgent.swift`) | The local `codex` CLI, inside a project folder | Same as Claude Code |

### OpenAI setup

1. Get an API key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
2. Paste it in **Settings › OpenAI › API key** and click **Save Key**. The key is stored in the Keychain (`openai-api-key`) and is never sent to other Macs. For development you can instead launch from a terminal with `OPENAI_API_KEY` set; a key saved in the Keychain wins.
3. Optionally change **Model** (default `gpt-4.1-mini`), the light model for quick answers and share summaries. Any Chat Completions model id works; for reasoning models (`gpt-5*`, `o*`) the client sends a low `reasoning_effort` instead of a token cap.

The same key is used for the Decisions API.

### Auto mode (Decisions API)

When Auto is on (**Settings › Auto mode**), the first question of a new chat is sent to the [OpenAI Decisions API](https://developers.openai.com/api/docs/guides/decisions) (`POST /v1/decisions`, model `gpt-6-luna`, 8 s timeout) by `AutoRouter` (`Services/AutoRouter.swift`). The request asks up to two `choice` questions about the question text:

- `route`: `quick` or `code`.
- `folder` (only when folder shortcuts exist): one of the shortcut names, or `(none)`.

The answers drive the chat:

- `code`: Claude Code (or Codex, if that is the default and is ready) answers, in the chosen folder shortcut, else the default folder, else the last folder used.
- `quick`: the light Chat Completions model answers.

The API returns probabilities, not text, so the label under the answer is built locally (e.g. "needs your files (93% sure)"). If no coding agent is ready, the call is skipped. If the call fails or the API refuses, the chat falls back to a quick answer and shows "Auto unavailable · used OpenAI". Typing `/claude`, `/codex`, `/quick` (or `/openai`) or a folder shortcut skips the call. Auto needs an OpenAI key.
