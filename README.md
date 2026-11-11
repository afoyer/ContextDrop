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
Views (SwiftUI) ──▶ PanelModel / WorkspaceModel ──▶ ChatStore ──▶ OpenAIClient · CLIRunner (claude / codex)
                         │                             │
                         └── RoomStore ── RoomService ─┴── PeerService ──▶ Multipeer Connectivity
```

- **Quick Chat** (`Windows/Panels.swift`, `Views/QuickChat`): the floating panel behind the global shortcut.
- **Workspace window** (`Windows/WorkspaceWindow.swift`): one chat per tab. Quick Chat shows the same tabs. ⌘T new, ⌘1–9 jump (window), ⌃Tab next that needs you, ⌘W close, ⌘⇧T reopen, ⌥⌘A activity, two-finger swipe sideways.
- **Coding agents** (`Providers/CLIRunner.swift`): runs `claude -p` or `codex exec` in the chat's folder and reads their JSON events. Claude Code's permission prompts and questions come back over stdin/stdout (`--permission-prompt-tool stdio`), so a run pauses on a card in the chat until you Allow, Deny or answer. Codex has no live prompt: it runs read-only, and a blocked edit becomes a card that re-runs it with write access.
- **Permission level** per chat: Read-only, Ask before editing (default) or Edits allowed. The default is in Settings › Providers.
- **Changes**: every edit is shown as a diff in the chat and under Activity › Changes (`Services/LineDiff.swift`). For Codex the diff is `git diff` of the touched files against the last commit.
- **Delegation** (Settings › Providers, off by default): Claude Code may hand read-only side tasks to Codex with `codex exec --sandbox read-only`. Codex may call `claude -p` only with Edits allowed, because its read-only sandbox blocks Claude's sign-in; that also turns on network access inside Codex's sandbox.
- **Skills** (`Services/SkillCatalog.swift`): Claude Code skills from `~/.claude/skills`, the project and installed plugins appear in the `/` menu.
- **Menu bar** (`Windows/MenuBarController.swift`): what needs you, what is running, what arrived. Drop a file on the icon to ask about it (⌥ for a new tab).
- **Sharing** (`Services/PeerService.swift`, `Models/Wire.swift`): a share is a summary the sender curates, sent over an encrypted Multipeer session after the receiver accepts. Several tabs can go in one drop.
- **Room** (`Services/RoomService.swift`, `Views/Room`): a shared canvas for people nearby. The Mac that opened it holds the state; it ends when that Mac leaves.

The app is not sandboxed (it starts the `claude` and `codex` CLIs), and is ad-hoc signed.

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
| **OpenAI** (`Providers/OpenAIClient.swift`) | HTTPS to `api.openai.com/v1/chat/completions`, streamed over SSE | Quick answers with no file access and share summaries (Chat Completions); the Auto decision (Decisions API) |
| **Claude Code** (`Providers/CLIRunner.swift`) | The local `claude` CLI, inside a project folder | Questions that need your files, repo or terminal |
| **Codex** (`Providers/CLIRunner.swift`) | The local `codex` CLI, inside a project folder | Same as Claude Code |

### OpenAI setup

1. Get an API key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
2. Paste it in **Settings › OpenAI › API key** and click **Save Key**. The key is stored in the Keychain (`openai-api-key`) and is never sent to other Macs. For development you can instead launch from a terminal with `OPENAI_API_KEY` set; a key saved in the Keychain wins.
3. Optionally change **Model** (default `gpt-4.1-mini`), the light model for quick answers and share summaries. Any Chat Completions model id works; for reasoning models (`gpt-5*`, `o*`) the client sends a low `reasoning_effort` instead of a token cap.

The same key is used for the Decisions API.

### Auto mode (Decisions API)

When Auto is on (**Settings › Auto mode**), the first question of a new chat is sent to the [OpenAI Decisions API](https://developers.openai.com/api/docs/guides/decisions) (`POST /v1/decisions`, model `gpt-6-luna`, 8 s timeout) by `OpenAIClient.route(...)`. The request asks up to two `choice` questions about the question text:

- `route`: `quick` or `code`.
- `folder` (only when folder shortcuts exist): one of the shortcut names, or `(none)`.

The answers drive the chat:

- `code`: Claude Code (or Codex, if that is the default and is ready) answers, in the chosen folder shortcut, else the default folder, else the last folder used.
- `quick`: the light Chat Completions model answers.

The API returns probabilities, not text, so the label under the answer is built locally (e.g. "needs your files (93% sure)"). If no coding agent is ready, the call is skipped. If the call fails or the API refuses, the chat falls back to a quick answer and shows "Auto unavailable · used OpenAI". Typing `/claude`, `/codex`, `/quick` (or `/openai`) or a folder shortcut skips the call. Auto needs an OpenAI key.
