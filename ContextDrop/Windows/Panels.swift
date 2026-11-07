import AppKit
import SwiftUI

/// Hosting view that takes the first click even when the app is inactive (non-activating panels).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Spotlight-like floating panel: non-activating, floats over every app and Space, grows downward from a fixed top.
final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onResignKey: (() -> Void)?
    /// Top-center anchor, so content changes grow the panel downward and widen it symmetrically.
    var anchorTop: CGFloat = 0
    var anchorMidX: CGFloat = 0

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
        if anchorTop > 0 {
            frame.origin.y = anchorTop - frame.height
            frame.origin.x = (anchorMidX - frame.width / 2).rounded()
        }
        super.setFrame(frame, display: flag)
        invalidateShadow()
    }

    /// Place the panel like Spotlight on the screen under the mouse.
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        anchorTop = visible.maxY - visible.height * 0.16
        anchorMidX = visible.midX
        setFrame(frame, display: false)
    }
}

/// Owns the Quick Chat panel and its show/hide motion.
@MainActor
final class QuickChatPanelController {
    let panel = FloatingPanel()
    let model: PanelModel

    init(model: PanelModel) {
        self.model = model
        let hosting = FirstClickHostingView(rootView: QuickChatView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.onEscape = { [weak self] in self?.model.escape() }
        panel.onResignKey = { [weak self] in
            guard let self, !self.model.keepsOpenOnResign, self.panel.isVisible else { return }
            // Don't hide while one of our own popovers/menus took key.
            if let key = NSApp.keyWindow, key.className.contains("Popover") { return }
            self.hide()
        }
        model.onHide = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible && panel.isKeyWindow ? model.escape() : show() }

    func show() {
        if !panel.isVisible { panel.positionOnActiveScreen() }
        model.summoned()
        let reduce = model.reduceMotion
        if !panel.isVisible {
            panel.alphaValue = 0
            let final = panel.frame
            if !reduce { panel.setFrame(final.offsetBy(dx: 0, dy: 6), display: false) }
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduce ? 0.12 : 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().alphaValue = 1
            }
            if !reduce { panel.anchorTop -= 0 }
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

/// Top-right, non-activating notification for an incoming share (board 4 · 01). Never takes focus.
@MainActor
final class NotificationPanelController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let model: PanelModel

    init(model: PanelModel) { self.model = model }

    func show(_ offer: IncomingOffer) {
        close()
        let panel = NonKeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let hosting = FirstClickHostingView(rootView: ShareNotificationView(model: model, offer: offer) { [weak self] in self?.close() }
            .onHover { [weak self] inside in if inside { self?.hideTask?.cancel() } })
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        let screen = NSScreen.main?.visibleFrame ?? .zero
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
            if !reduce { panel.animator().setFrame(target, display: true) }
        }
        self.panel = panel

        // Ignored for 8 s → it lives on at the top of the Quick Chat list.
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// ⌘↵: the same conversation in a regular, resizable window (the "expanded" deep-chat window).
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private var windows: [UUID: NSWindow] = [:]
    private let model: PanelModel

    init(model: PanelModel) { self.model = model }

    func open(_ conversationID: UUID) {
        if let window = windows[conversationID] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = ChatView(model: model, conversationID: conversationID, style: .window)
            .frame(minWidth: 640, minHeight: 480)
            .background(MaterialBackground(material: .sidebar))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1030, height: 780),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = model.store.conversation(conversationID)?.title ?? "ContextDrop"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        windows[conversationID] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}
