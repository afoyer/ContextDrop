# ContextDrop

*Think together, instantly.* A native macOS app (Swift 6, SwiftUI, Multipeer Connectivity) that lets nearby Macs find each other, connect with an explicit invite/accept, and chat with no server.

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
5. Mac A: **Connect** next to Mac B. Mac B: **Accept**. Both switch to the conversation.
6. Return sends. Shift+Return inserts a newline.

To change your name, click the pencil next to "You appear as …". The name is saved in UserDefaults.

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
| `NSBonjourServices` = `_contextdrop._tcp`, `_contextdrop._udp` | `Config/Info.plist` | Required on macOS 11+ to browse or advertise this service type. It must match `serviceType = "contextdrop"`. |
| `com.apple.security.app-sandbox` | `Config/ContextDrop.entitlements` | App Sandbox |
| `com.apple.security.network.client` + `.server` | same | MPC both opens connections and listens for them |

Signing is ad-hoc ("Sign to Run Locally", `CODE_SIGN_IDENTITY = "-"`), so no Apple Developer team is needed. To distribute without the quarantine step, set a `DEVELOPMENT_TEAM`, sign with a Developer ID certificate, and notarize.

## Architecture

```
SwiftUI Views ──intents──▶ SessionViewModel ──▶ PeerConnectionManager ──▶ MCSession / Advertiser / Browser
      ▲                         (screen state)        (@MainActor @Observable)        (MPC private queues)
      └──────────── observes ────────────────────────────┘ ◀── nonisolated delegates hop to MainActor
```

- **`PeerConnectionManager`** (`Services/`) owns `MCPeerID`, `MCSession` (encryption required), `MCNearbyServiceAdvertiser` and `MCNearbyServiceBrowser`, and implements all three delegates. Delegate methods are `nonisolated` and only forward to the main actor, where all observable state lives (`peers`, `messages`, `pendingInvitations`, `notice`). Callbacks from an object that has since been replaced (after a disconnect or rename) are dropped.
- **Identity**: the MCPeerID is archived per display name and reused across launches, so other Macs don't collect "ghost" duplicates. A stable `senderID` UUID identifies your own messages.
- **Invitations** are never auto-accepted. They show up as `pendingInvitations` (a sheet). Unanswered ones are declined after 30 s, which matches the inviter's timeout.
- **Wire format**: each `session.send(_:toPeers:with: .reliable)` payload is one JSON `WireEnvelope { version, kind, chat }` (`Models/ChatMessage.swift`). The receiver rejects payloads over 64 KB, unknown versions or kinds, and empty or >4000-char content. Rejected payloads are logged and shown as a dismissible notice; they never crash the app. The displayed sender name comes from the transport's MCPeerID, not the payload.
- **No duplicates**: local messages appear immediately, and every message ID goes into `seenMessageIDs`, so repeats are ignored. A message that fails to send stays in the list as "Not delivered. Retry".
- **Disconnects**: the peer's state becomes Disconnected, history stays in memory, and the chat screen shows a banner with **Reconnect** (enabled once the peer is visible again).

## Verification status

The single-Mac tests ran on one machine, with two instances driven by AppleScript UI scripting:

- [x] Launches, Debug and Release (universal) build with no warnings under Swift 6
- [x] Discovery in both directions, with no self-listing
- [x] Invite → Decline shows **Rejected** on the inviter
- [x] Retry → Accept: both show **Connected** and switch to chat
- [x] A → B message (including a Shift+Return newline) and B → A reply; each appears once on each side, in the same order
- [x] Hard-kill of one side: the other shows **Disconnected** after about 15 s (MPC's keep-alive timeout), and history is kept
- [x] Relaunch → Reconnect → Accept: connected again, with the persisted MCPeerID (no ghost peer)
- [x] The Disconnect button updates the other side within about 1 s
- [x] Invalid payloads (random bytes, empty, wrong shape, future version, unknown kind, blank or oversized content, >64 KB) are rejected without crashing (codec harness)
- [ ] **Two physical Macs: not yet performed.** Run the steps above.

## Known limitations

- **Rejected vs. failed is a heuristic.** MPC gives no explicit "declined" signal. A `.notConnected` that arrives well before the 30 s invite timeout is shown as Rejected; otherwise it is shown as Connection failed. A fast network failure during the handshake would be mislabeled Rejected.
- **An abrupt drop takes about 15 s to detect** (MPC's keep-alive). A clean quit or Disconnect is about 1 s.
- **One shared conversation.** Messages are a single in-memory list with no persistence or per-peer threads. The session supports up to 8 peers, but the UI is built for a 1:1 conversation.
- Message order uses the sender's timestamp, so clock skew between Macs can reorder messages sent at nearly the same moment.
- Two Macs with the **same display name** may be pruned as each other's "ghost" when one goes out of range.
- Discovery keeps running while the app is in the background. It stops on quit or rename.
- MPC traffic is encrypted, but peers are **not authenticated** (no certificate pinning): anyone nearby can claim any name. The user's explicit Accept is the only gate.

## Integration points for OpenRouter (not implemented)

1. **New wire kinds**: add cases to `WireEnvelope.Kind` (e.g. `.aiRequest`, `.aiResponse`, `.contextShare`) with matching optional payloads, and route them in `PeerConnectionManager.handleReceived`. Bump `currentVersion` only for breaking changes.
2. **An `AIService` (e.g. `Services/OpenRouterService.swift`)**: an `actor` that calls OpenRouter over `URLSession` with streaming. It should take `[ChatMessage]` as conversation context. Keep it separate from the P2P manager and inject it into `SessionViewModel`.
3. **Who calls the model**: have one peer (e.g. the inviter, the "host") make the API call and broadcast results with `.aiResponse`. Then only one key is used, both screens show the same answer, and duplicate billing is avoided. The message ID dedup already makes re-broadcasting safe.
4. **Streaming tokens**: send chunked `.aiResponse` deltas with `.reliable` (keyed by a response ID and sequence number), or use `MCSession.startStream` for long outputs.
5. **API key**: store it in the Keychain, never in the wire payload or UserDefaults. With the sandbox, the existing `network.client` entitlement already allows HTTPS to OpenRouter.
6. **Payload limits**: `WireCodec.maxPayloadBytes` (64 KB) will need raising, or chunking, for large shared contexts. Use `sendResource(at:)` for files.
