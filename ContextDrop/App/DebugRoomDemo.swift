#if DEBUG
import AppKit
import Foundation

/// Development only: drives a room from launch arguments, so several instances on one Mac can be checked
/// without clicking through each (see `scripts/dev-run.sh`). Not compiled into release builds.
///
///     -ContextDrop.demoRoom host    open a room, invite everyone nearby, add a thought and a chat
///     -ContextDrop.demoRoom guest   join the first invitation, reply in the first chat and drop an image on it
///     -ContextDrop.selfCheck YES    check the secret masker and log the result
@MainActor
enum DebugRoomDemo {
    static var role: String? { UserDefaults.standard.string(forKey: "ContextDrop.demoRoom") }

    static func start(room: RoomStore, openRoom: @escaping @MainActor () -> Void, showRoom: @escaping @MainActor () -> Void) {
        // `-ContextDrop.selfCheck YES`: check the secret masker and log the result.
        if UserDefaults.standard.bool(forKey: "ContextDrop.selfCheck") {
            let failures = SecretMasker.selfCheck()
            p2pLog.info("Secret masker self-check: \(failures.isEmpty ? "passed" : "FAILED on \(failures.joined(separator: " | "))", privacy: .public)")
        }
        guard let role else { return }
        p2pLog.info("Room demo: \(role, privacy: .public)")
        Task {
            switch role {
            case "host":
                try? await Task.sleep(for: .seconds(4)) // let nearby peers be found
                openRoom()
                room.addCard(kind: .thought, text: "What if questions show in the menu bar too?", at: CGPoint(x: 80, y: 80))
                room.addCard(kind: .note, text: "Demo: 0:00 Quick Chat · 0:40 drop · 1:10 room", at: CGPoint(x: -260, y: 120))
                room.spawnChat(question: "Say hello to the room in one short sentence.", selected: [])
                // Keep inviting: guests may start later than the host.
                for _ in 0..<10 {
                    try? await Task.sleep(for: .seconds(3))
                    room.inviteAllNearby()
                }
            case "guest":
                guard let invitation = await first({ room.pendingInvitations.first }) else { return }
                room.join(invitation)
                showRoom()
                guard let chat = await first({ room.tiles.first { $0.chat != nil } }) else { return }
                try? await Task.sleep(for: .seconds(2))
                room.addImage(sampleImage(), to: chat.id)
                room.sendChat("What is in the image I just added?", in: chat.id)
                room.addCard(kind: .thought, text: "Added from \(room.localName)’s Mac", at: CGPoint(x: 120, y: 320))
            default:
                break
            }
        }
    }

    /// Polls for up to a minute until `value` is there.
    private static func first<T>(_ value: @MainActor () -> T?) async -> T? {
        for _ in 0..<120 {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// A small image with a word on it, so a vision model has something to describe.
    private static func sampleImage() -> NSImage {
        NSImage(size: NSSize(width: 320, height: 160), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            let text = "ROOM DEMO" as NSString
            text.draw(at: NSPoint(x: 40, y: 60), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.white])
            return true
        }
    }
}
#endif
