# Room invite picker

Design note, 15 November 2026. Not started. Agreed in conversation; items marked **(proposal)** are calls made while writing this up and are open to change.

## Why

Opening a room today invites every nearby Mac without asking. `AppDelegate.openRoom()` calls `roomStore.openRoom()` and then `roomStore.inviteAllNearby()`, so on a shared network (a campus, a conference) everyone running ContextDrop gets an invitation. The room's own Invite control is a plain menu of names with an “Invite Everyone Nearby” shortcut.

The host should choose who is invited, the same way they choose who receives a chat. The chat share already has the right flow in `NearbySendView`: a grid of people, a ring while waiting, a check when delivered, and a “didn’t accept” state.

## Goals

- Nobody is invited to a room unless the host selected them.
- Inviting to a room looks and behaves like sharing a chat.
- One people picker that later gains more sources (known people, team members, an invite link) without another redesign.

## Not in scope

- Any change to the room protocol, wire format or invitation contents. Each selected person gets the same `RoomInvitation` as today.
- Changing when this Mac is visible to others on the network. That is a separate change (see “Later”).
- Online invitations and invite links.

## Approaches considered

1. **Reuse the chat share grid, with multi-select. (Chosen.)** Consistent with the existing flow, and the picker becomes the one place for inviting as more sources arrive.
2. **Keep the menu, remove the two “invite everyone” paths.** Smallest change and fixes the broadcast, but leaves two unrelated ways of choosing people and no room for per-person status.
3. **A separate room-only picker.** Duplicates the grid, tiles and animations that `NearbySendView` already has.

## What the host sees

```
┌──────────────────────────────────────────────┐
│  Invite to “Design review”                   │
│  2 selected                                  │
├──────────────────────────────────────────────┤
│   (◉)        (○)        (✓)        (··)      │
│   Bob        Carol      Dana      Looking…   │
│  MacBook Pro MacBook Air  Joined             │
├──────────────────────────────────────────────┤
│                         esc    [ Invite 2 ]  │
└──────────────────────────────────────────────┘
```

- **Opening it:** the room’s Invite button (replacing the current menu), labelled `Invite…`.
- **On creating a room (proposal):** the picker appears straight away when the host explicitly opens a room and someone is nearby. It can be dismissed without inviting anyone. A room opened as a side effect of dragging a tab into it does not show the picker; the host uses `Invite…`.
- **Selecting:** click a person to select or deselect. Nothing is sent until `Invite N`.
- **Per-person states**, matching the chat share:
  - Selected: accent ring.
  - Invited: progress ring over the 60-second invitation, subtitle “Waiting…”.
  - Joined: green check, not selectable.
  - Didn’t accept: shown on the tile, selectable again.
- **Room full:** a room holds 8 people (`RoomService.maxPeers`), counting those present and those with a pending invitation. Once the selection reaches the remaining places, other tiles are dimmed and the header says how many places are left.
- **Nobody nearby:** the same “Looking…” tile and a line saying no one nearby is running ContextDrop.
- **Guests:** the button is disabled with the existing “Only the host can invite people” explanation.
- **Keys (proposal):** arrows move, space toggles, `↵` invites, `esc` closes. In the chat share `↵` still sends to the highlighted person.
- **Closing:** the picker can be closed while invitations are pending. The existing “… didn’t join.” notice still appears in the room.

## Code changes

Views:

- New shared view (proposal: `Views/Share/PeoplePicker.swift`) holding the grid, person tile and “Looking…” tile now inside `NearbySendView`. It takes the people, a status per person, and a mode: send to one, or pick many.
- `NearbySendView` keeps its header, footer, AirDrop and drop animation, and uses the shared grid in send-to-one mode. Its behaviour must not change.
- New `Views/Room/RoomInviteView.swift`: header, the shared grid in pick-many mode, footer with `Invite N`. Shown as a sheet on the room window.
- `RoomView`: replace `inviteMenu` with a button that shows the sheet.

Rule (pure, tested):

- New caseless enum (proposal: `RoomInviteSelection` in `Stores/`) that decides, from the people present, pending invitations, the current selection and `RoomService.maxPeers`: who can be selected, how many places are left, and what a toggle does. `RoomStore` and the view only apply its result.

Store:

- `RoomStore.invite(_:)` takes the selected people and invites each one, as `invite(_ peer:)` does now.
- Remove `RoomStore.inviteAllNearby()`.
- Track people whose invitation was declined or timed out, so their tile can show “didn’t accept” until they are invited again. Today `onInviteUnanswered` only sets a one-line notice.

App:

- `AppDelegate.openRoom()` no longer invites anyone. It opens the room and, when the host opened it explicitly, asks the room window to show the picker.
- `DebugRoomDemo` (the scripted host role) currently relies on `inviteAllNearby()`. It should invite `invitablePeers` itself, so the demo keeps working without leaving a public “invite everyone” method.

Not touched: `RoomService`, `PeerService`, `RoomReducer`, `RoomWire`, `docs/room-protocol.md`.

## Tests

- `RoomInviteSelectionTests`: toggling; people already in the room or already invited can’t be selected; the selection can’t exceed the remaining places; a declined person can be selected again. Alice hosts, Bob and Carol are guests.
- No UI or Multipeer tests, as elsewhere in the project.
- By hand on three instances (`scripts/dev-run.sh Alice Bob Carol`): open a room and confirm nobody is invited until selected; invite Bob only and confirm Carol gets nothing; decline as Bob and re-invite; fill a room to 8 if enough instances can run; confirm the chat share flow is unchanged.

## Docs

- `README.md`: update the Room section to say the host chooses who to invite. It currently does not mention invitations, so this is an addition.

## Branch

`feature/room-invite-picker`, started after the uncommitted work on `feature/room-handoff` is committed, because both touch the room views and `AppDelegate`.

## Left to the builder

- Exact view names and where the shared grid lives.
- Whether the picker is a sheet or a popover on the room window.
- Animation details for the pick-many mode.

## Later

The picker is where these arrive, in the order agreed for online collaboration:

- **Visibility of this Mac:** stop announcing the Mac while idle; later an AirDrop-style setting (Everyone nearby, Known people only, Off).
- **Known people:** a section for people admitted before, identified by a per-device key, including when they are not nearby. Invitations become signed.
- **Team:** a section for members of the team that owns the room.
- **Invite link:** a `Copy invite link` action in the footer once the internet relay exists.
