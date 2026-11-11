import SwiftUI

/// Compact invitation card for a popover or a notification panel.
struct RoomInvitationView: View {
    let invitation: RoomInvitation
    let onDecline: () -> Void
    let onJoin: () -> Void

    /// Answers straight through the store; `onDone` runs after either button (close the popover, show the window).
    init(store: RoomStore, invitation: RoomInvitation, onDone: @escaping (_ joined: Bool) -> Void = { _ in }) {
        self.invitation = invitation
        onDecline = {
            store.declineInvitation(invitation)
            onDone(false)
        }
        onJoin = {
            store.join(invitation)
            onDone(true)
        }
    }

    init(invitation: RoomInvitation, onDecline: @escaping () -> Void, onJoin: @escaping () -> Void) {
        self.invitation = invitation
        self.onDecline = onDecline
        self.onJoin = onJoin
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AvatarView(name: invitation.hostName, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(invitation.hostName) opened a room")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(invitation.name) · \(invitation.memberCount) here")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            Text("Your chats stay private. Only cards you put on the table are shared.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Not now", action: onDecline)
                    .keyboardShortcut(.cancelAction)
                Button("Join", action: onJoin)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
