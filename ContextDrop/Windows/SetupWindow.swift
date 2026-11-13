import AppKit
import SwiftUI

/// The setup window: shown on first launch, and again from Settings › General or the menu bar.
/// Closing it before the last step counts as Set Up Later.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    let model: SetupModel
    private var window: NSWindow?
    /// Set while the window closes because setup ended, so the close isn't taken as Set Up Later.
    private var closingOnPurpose = false

    init(model: SetupModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if !isVisible { model.reset() }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // A menu bar app may be refused activation; without this the window can open behind other apps.
        window.orderFrontRegardless()
    }

    func close() {
        closingOnPurpose = true
        window?.close()
        closingOnPurpose = false
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingOnPurpose else { return }
        // Already closing: whatever `later()` asks of this controller must not close it again.
        closingOnPurpose = true
        model.later()
        closingOnPurpose = false
    }

    private func makeWindow() -> NSWindow {
        let size = SetupView.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "ContextDrop Setup"
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(model: model))
        window.setContentSize(size)
        window.center()
        return window
    }
}
