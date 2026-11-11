import AppKit
import SwiftUI

/// The menu bar item (R3 boards 3 and 5): a drop that fills while something is brewing, one status dot,
/// a popover with everything that is going on, and a drop target for files.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: PanelModel
    private let room: RoomStore
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let dot = CALayer()
    private var timer: Timer?
    private var frame = 0
    /// The drop stays full for a moment after the last run ends.
    private var solidUntil = Date.distantPast
    private var wasRunning = false
    var actions = MenuBarActions()
    var shortcut = ""
    /// Files dropped on the icon. `newTab` is true when ⌥ was held.
    var onDropFiles: (([URL], _ newTab: Bool) -> Void)?

    private var store: ChatStore { model.store }

    init(model: PanelModel, room: RoomStore) {
        self.model = model
        self.room = room
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        popover.behavior = .transient
        popover.animates = !model.reduceMotion
        popover.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.toolTip = "ContextDrop (\(model.peers.localDisplayName))"
            button.setAccessibilityLabel("ContextDrop")
            button.wantsLayer = true
            dot.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
            dot.cornerRadius = 3
            dot.isHidden = true
            button.layer?.addSublayer(dot)
            let target = StatusDropView(frame: button.bounds)
            target.autoresizingMask = [.width, .height]
            target.onDrop = { [weak self] urls, option in self?.onDropFiles?(urls, option) }
            target.onTargeted = { [weak button] targeted in button?.highlight(targeted) }
            button.addSubview(target)
        }
        refresh()
    }

    // MARK: Popover

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }

    func show() {
        guard let button = item.button else { return }
        var actions = actions
        actions.close = { [weak self] in self?.popover.performClose(nil) }
        // Every action that opens something also closes the popover.
        let base = actions
        actions.openChat = { [weak self] id in self?.popover.performClose(nil); base.openChat(id) }
        actions.openQuickChat = { [weak self] in self?.popover.performClose(nil); base.openQuickChat() }
        actions.openWindow = { [weak self] in self?.popover.performClose(nil); base.openWindow() }
        actions.openSettings = { [weak self] in self?.popover.performClose(nil); base.openSettings() }
        actions.openRoom = { [weak self] in self?.popover.performClose(nil); base.openRoom() }
        actions.dropCurrent = { [weak self] in self?.popover.performClose(nil); base.dropCurrent() }
        let controller = NSHostingController(rootView: MenuBarView(model: model, room: room, shortcut: shortcut, actions: actions))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    // MARK: Icon

    /// Call whenever runs, requests, shares or the room change.
    func refresh() {
        let running = !store.runningConversationIDs.isEmpty
        if wasRunning && !running { solidUntil = Date().addingTimeInterval(10) }
        wasRunning = running
        let animate = running && !model.reduceMotion
        if animate, timer == nil {
            let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.frame = (self.frame + 1) % Self.levels.count
                    self.draw()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !animate, let timer {
            timer.invalidate()
            self.timer = nil
            frame = 0
        }
        if !running, solidUntil > Date() {
            // Come back to redraw the outline once the "just finished" moment passes.
            let delay = solidUntil.timeIntervalSinceNow + 0.1
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.draw()
            }
        }
        draw()
    }

    private static let levels: [CGFloat] = [0.1, 0.3, 0.55, 0.8, 1]

    private func draw() {
        guard let button = item.button else { return }
        let running = !store.runningConversationIDs.isEmpty
        let needsYou = !store.conversationsNeedingYou.isEmpty || !room.pendingInvitations.isEmpty
        let incoming = model.peers.offers.contains { $0.phase == .pending } || store.received.contains { !$0.read }
        let done = !store.finishedUnseen.isEmpty

        let level: CGFloat
        if running { level = model.reduceMotion ? 0.55 : Self.levels[frame] }
        else if solidUntil > Date() || incoming || done { level = 1 }
        else { level = 0 }
        button.image = Self.dropImage(level: level)

        // One dot: orange (needs you) over blue (incoming) over green (done).
        let color: NSColor? = needsYou ? .systemOrange : incoming ? .systemBlue : done ? .systemGreen : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.isHidden = color == nil
        dot.backgroundColor = color?.cgColor
        dot.frame.origin = CGPoint(x: button.bounds.maxX - 9, y: button.isFlipped ? button.bounds.maxY - 9 : 3)
        CATransaction.commit()

        var status: [String] = []
        if needsYou { status.append("needs you") }
        if running { status.append("working") }
        if incoming { status.append("something arrived") }
        if done { status.append("an answer is ready") }
        button.setAccessibilityLabel(status.isEmpty ? "ContextDrop" : "ContextDrop, " + status.joined(separator: ", "))
    }

    /// A drop outline filled from the bottom up to `level` (0…1). Template, so it follows the menu bar.
    static func dropImage(level: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 9, y: 16.6))
            path.curve(to: NSPoint(x: 3.8, y: 7.2), controlPoint1: NSPoint(x: 7.4, y: 13.8), controlPoint2: NSPoint(x: 3.8, y: 10.6))
            path.appendArc(withCenter: NSPoint(x: 9, y: 7.2), radius: 5.2, startAngle: 180, endAngle: 360)
            path.curve(to: NSPoint(x: 9, y: 16.6), controlPoint1: NSPoint(x: 14.2, y: 10.6), controlPoint2: NSPoint(x: 10.6, y: 13.8))
            path.close()
            NSColor.black.set()
            if level > 0 {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                NSBezierPath(rect: NSRect(x: 0, y: 2, width: 18, height: 14.6 * min(1, level))).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            path.lineWidth = 1.3
            path.lineJoinStyle = .round
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Sits over the status button to take file drops (R3 board 5). Clicks pass through to the button.
private final class StatusDropView: NSView {
    var onDrop: (([URL], _ option: Bool) -> Void)?
    var onTargeted: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }

    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = urls(sender)
        onTargeted?(false)
        guard !urls.isEmpty else { return false }
        let option = NSEvent.modifierFlags.contains(.option)
        DispatchQueue.main.async { [onDrop] in onDrop?(urls, option) }
        return true
    }
}
