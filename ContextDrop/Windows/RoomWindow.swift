import AppKit
import SwiftUI

/// The room window: a regular, resizable window that is reused across shows.
/// Closing it only hides the canvas; leaving the room is the Leave button (or `RoomStore.leave()`).
@MainActor
final class RoomWindowController {
    private let store: RoomStore
    private let reduceMotion: () -> Bool
    private var window: NSWindow?
    private lazy var chats = RoomChatWindows(store: store)

    /// Open one of this Mac's own Claude Code runs (by run tile id).
    var onOpenOwnRun: (UUID) -> Void = { _ in }
    /// Open what was taken home from an ended room as a private chat.
    var onTakeHome: (ShareSummary) -> Void = { _ in }

    init(store: RoomStore, reduceMotion: @escaping () -> Bool) {
        self.store = store
        self.reduceMotion = reduceMotion
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = prepared()
        // Quick Chat is a non-activating panel, so the app is usually not active when this runs. The cooperative
        // `NSApp.activate()` is then turned down and the room opened behind the app in front; the other windows
        // (workspace, Settings) already ask the way that works.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// A tab is being dragged out of Quick Chat or the workspace (R5 board 6 B): put the room up front, under
    /// the pointer, so it can be dropped on. Nothing is activated mid-drag; Quick Chat stays where it is.
    func bringForwardForDrop() {
        prepared().orderFrontRegardless()
    }

    private func prepared() -> NSWindow {
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = store.room?.name ?? "Room"
        if window.isMiniaturized { window.deminiaturize(nil) }
        return window
    }

    func close() {
        window?.close()
    }

    /// The room changed (opened, ended, left): popped-out chats of a room that is gone close.
    func roomChanged() {
        if store.room == nil { chats.closeAll() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden // the header shows the room name
        window.tabbingMode = .disallowed
        let view = RoomView(store: store, reduceMotion: reduceMotion,
                            onPopOut: { [weak self] id in self?.chats.open(id) },
                            onOpenOwnRun: { [weak self] id in self?.onOpenOwnRun(id) },
                            onTakeHome: { [weak self] share in self?.onTakeHome(share) })
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.setContentSize(NSSize(width: 1240, height: 800))
        window.center()
        return window
    }
}

/// "Pop out" (⌘↵): a chat tile as a full tab. Popped-out chats share one window as native tabs,
/// and each stays connected to the room: it is the same tile, only bigger.
@MainActor
final class RoomChatWindows {
    private let store: RoomStore
    private var windows: [UUID: NSWindow] = [:]

    init(store: RoomStore) {
        self.store = store
    }

    func open(_ tileID: UUID) {
        guard let chat = store.tile(tileID)?.chat else { return }
        if let window = windows[tileID] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = chat.title
        window.subtitle = "Room chat"
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "ContextDrop.RoomChats"
        window.contentView = NSHostingView(rootView: RoomChatPopOut(store: store, tileID: tileID) { [weak self] in
            self?.close(tileID)
        })
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 400)
        if let sibling = windows.values.first(where: \.isVisible) {
            sibling.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        windows[tileID] = window
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ tileID: UUID) {
        windows.removeValue(forKey: tileID)?.close()
    }

    func closeAll() {
        for window in windows.values { window.close() }
        windows = [:]
    }
}

private struct RoomChatPopOut: View {
    let store: RoomStore
    let tileID: UUID
    let onClose: () -> Void

    var body: some View {
        Group {
            if let tile = store.tile(tileID), let chat = tile.chat {
                RoomChatTileView(store: store, tile: tile, chat: chat, style: .full)
            } else {
                VStack(spacing: 10) {
                    Text("This chat is no longer in the room").font(.system(size: 14, weight: .semibold))
                    Text("It was removed, or the room was closed.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Close", action: onClose)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(RoomPalette.tile)
    }
}
