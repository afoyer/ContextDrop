import AppKit
import SwiftUI

/// Hosting view that takes the first click even when the app is inactive (non-activating panels).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keep the window exactly as big as the SwiftUI content, including changes made while it was hidden
    /// (a share arriving, a file opened), so it never reappears at a stale size with content cut off.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.fitWindow() }
    }

    func fitWindow() {
        guard let window else { return }
        layoutSubtreeIfNeeded()
        let size = fittingSize
        guard size.width > 1, size.height > 1, window.contentRect(forFrameRect: window.frame).size != size else { return }
        window.setContentSize(size)
    }
}

/// Spotlight-like floating panel: non-activating, floats over every app and Space, grows downward from a fixed top.
final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onResignKey: (() -> Void)?
    /// Top-center anchor, so content changes grow the panel downward and widen it symmetrically.
    var anchorTop: CGFloat = 0
    var anchorMidX: CGFloat = 0
    /// Width added on the right only (the terminal pane): the chat column keeps its place.
    var rightExtension: () -> CGFloat = { 0 }
    /// Tells the content how tall it may get on this screen.
    var onAvailableHeight: ((CGFloat) -> Void)?
    /// Off while the show animation moves the panel itself.
    var anchoringEnabled = true
    /// True while `setFrame` is placing the panel, so those moves aren't mistaken for a drag.
    private var placing = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 200),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userMoved() }
        }
    }

    /// The user dragged the panel: keep it there instead of snapping back on the next resize.
    private func userMoved() {
        guard anchoringEnabled, !placing, anchorTop > 0, isVisible else { return }
        let extra = min(rightExtension(), frame.width)
        anchorTop = frame.maxY
        anchorMidX = frame.minX + (frame.width - extra) / 2
        if let visible = (screen ?? NSScreen.main)?.visibleFrame { onAvailableHeight?(max(240, anchorTop - visible.minY - 16)) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        placing = true
        defer { placing = false }
        if anchorTop > 0 && anchoringEnabled {
            let extra = min(rightExtension(), frame.width)
            frame.origin.y = anchorTop - frame.height
            frame.origin.x = (anchorMidX - (frame.width - extra) / 2).rounded()
            // Stay on screen when the pane would run past the right edge.
            let anchor = NSPoint(x: anchorMidX, y: anchorTop - 1)
            if let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? screen)?.visibleFrame {
                if frame.maxX > visible.maxX - 8 { frame.origin.x = visible.maxX - 8 - frame.width }
                if frame.minX < visible.minX + 8 { frame.origin.x = visible.minX + 8 }
                // Last resort if content is still too tall: slide up rather than run off the bottom.
                if frame.minY < visible.minY + 8 {
                    frame.origin.y = min(visible.minY + 8, visible.maxY - frame.height)
                }
            }
        }
        super.setFrame(frame, display: flag)
        invalidateShadow()
    }

    /// Place the panel like Spotlight on the screen under the mouse.
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        // Smaller gap on short screens (13" laptops) so the panel has room to grow.
        anchorTop = visible.maxY - visible.height * (visible.height < 900 ? 0.08 : 0.16)
        anchorMidX = visible.midX
        onAvailableHeight?(anchorTop - visible.minY - 16)
        setFrame(frame, display: false)
    }
}

/// Owns the Quick Chat panel and its show/hide motion.
@MainActor
final class QuickChatPanelController {
    let panel = FloatingPanel()
    let model: PanelModel
    private let hosting: FirstClickHostingView<QuickChatView>
    private var swipe: TabSwipeTracker?
    private var keyMonitor: Any?

    init(model: PanelModel) {
        self.model = model
        let hosting = FirstClickHostingView(rootView: QuickChatView(model: model))
        self.hosting = hosting
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.onEscape = { [weak self] in self?.model.escape() }
        panel.rightExtension = { [weak model] in MainActor.assumeIsolated { model?.rightExtension ?? 0 } }
        panel.onAvailableHeight = { [weak model] height in MainActor.assumeIsolated { model?.maxPanelHeight = height } }
        panel.onResignKey = { [weak self] in
            guard let self, !self.model.keepsOpenOnResign, self.panel.isVisible else { return }
            // Don't hide while one of our own popovers/menus took key.
            if let key = NSApp.keyWindow, key.className.contains("Popover") { return }
            self.hide()
        }
        model.actions.hide = { [weak self] in self?.hide() }
        // Tabs in Quick Chat: swipe sideways anywhere on the panel, or ⌃Tab / ⌃⇧Tab.
        swipe = TabSwipeTracker(model: model, offset: \.panelSwipe, window: { [weak self] in self?.panel },
                                current: { [weak model] in model?.panelConversationID },
                                select: { [weak model] id in model?.selectPanelTab(id) })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                // ⌘V: a link or a long text becomes a chip instead of filling the input.
                if let self, event.window === self.panel, event.charactersIgnoringModifiers?.lowercased() == "v",
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                    switch self.model.mode {
                    case .home, .chat: return self.model.pasteKey(in: self.panel, session: self.model.session(self.model.panelConversationID))
                    default: return false
                    }
                }
                guard let self, event.window === self.panel, event.keyCode == 48,
                      event.modifierFlags.contains(.control), self.model.panelConversationID != nil else { return false }
                self.model.cyclePanelTab(backwards: event.modifierFlags.contains(.shift))
                return true
            }
            return handled ? nil : event
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible && panel.isKeyWindow ? model.escape() : show() }

    func show() {
        if !panel.isVisible { panel.positionOnActiveScreen() }
        model.summoned()
        hosting.fitWindow()
        let reduce = model.reduceMotion
        if !panel.isVisible {
            panel.alphaValue = 0
            let final = panel.frame
            // Settles 6 pt down into place. The anchor is off meanwhile, or it would cancel the move.
            if !reduce {
                panel.anchoringEnabled = false
                panel.setFrame(final.offsetBy(dx: 0, dy: 6), display: false)
            }
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = reduce ? 0.12 : 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().alphaValue = 1
                // Through NSWindow, so the animator proxy gets an Objective-C message. Calling the Swift
                // override directly would run it on the proxy object and write past its memory.
                if !reduce { (panel as NSWindow).animator().setFrame(final, display: true) }
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.panel.anchoringEnabled = true
                    self.hosting.fitWindow()
                    self.panel.setFrame(self.panel.frame, display: true) // back on the anchor, at the current size
                }
            })
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
                self?.panel.alphaValue = 1
            }
        })
    }
}

/// Top-right, non-activating notification for an incoming share or room invitation (board 4 · 01).
/// Never takes focus.
@MainActor
final class NotificationPanelController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let model: PanelModel

    init(model: PanelModel) { self.model = model }

    func show(_ offer: IncomingOffer) {
        present(ShareNotificationView(model: model, offer: offer) { [weak self] in self?.close() })
    }

    func show(_ invitation: RoomInvitation, store: RoomStore, onJoined: @escaping @MainActor () -> Void) {
        let card = RoomInvitationView(store: store, invitation: invitation) { [weak self] joined in
            self?.close()
            if joined { onJoined() }
        }
        .frame(width: 340)
        .background(MaterialBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        present(card, stay: 20)
    }

    private func present<Content: View>(_ content: Content, stay: TimeInterval = 8) {
        close()
        let panel = NonKeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.anchorTop = screen.maxY - 12 // Preview grows the card downward, not off the top of the screen
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Stays while the pointer is on it; the countdown starts again when it leaves.
        let hosting = FirstClickHostingView(rootView: content.onHover { [weak self] inside in
            if inside { self?.hideTask?.cancel() } else { self?.scheduleClose(after: stay) }
        })
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        let size = panel.frame.size
        let target = NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12, width: size.width, height: size.height)
        let reduce = model.reduceMotion
        panel.setFrame(reduce ? target : target.offsetBy(dx: 24, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0.15 : 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().alphaValue = 1
            if !reduce { (panel as NSWindow).animator().setFrame(target, display: true) }
        }
        self.panel = panel
        // Ignored → it lives on in the Quick Chat list and the menu bar.
        scheduleClose(after: stay)
    }

    private func scheduleClose(after seconds: TimeInterval) {
        hideTask?.cancel()
        guard panel != nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        hideTask?.cancel()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }
}

private final class NonKeyPanel: NSPanel {
    var anchorTop: CGFloat = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if anchorTop > 0 { frame.origin.y = anchorTop - frame.height }
        super.setFrame(frame, display: flag)
    }
}
