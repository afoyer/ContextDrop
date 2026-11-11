import AppKit
import SwiftUI

/// The room window: a regular, resizable window that is reused across shows.
/// Closing it only hides the table; leaving the room is the Leave button (or `RoomStore.leave()`).
@MainActor
final class RoomWindowController {
    private let store: RoomStore
    private let reduceMotion: () -> Bool
    private var window: NSWindow?

    init(store: RoomStore, reduceMotion: @escaping () -> Bool) {
        self.store = store
        self.reduceMotion = reduceMotion
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = store.room?.name ?? "Room"
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden // the header shows the room name
        window.contentView = NSHostingView(rootView: RoomView(store: store, reduceMotion: reduceMotion))
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        return window
    }
}
