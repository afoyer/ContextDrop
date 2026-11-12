import AppKit
import SwiftUI

/// Two-finger sideways swipe between tabs, anywhere in a window (the workspace window or Quick Chat).
/// The page follows the fingers, a pill names the tab you are heading to, and letting go past the
/// threshold switches. Vertical scrolling, and sideways scrolling inside code or diffs, is left alone.
@MainActor
final class TabSwipeTracker {
    static let threshold: CGFloat = 110

    private let model: PanelModel
    private let offset: ReferenceWritableKeyPath<PanelModel, CGFloat>
    private let window: () -> NSWindow?
    private let current: () -> UUID?
    private let select: (UUID) -> Void
    private var monitor: Any?

    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var seen = CGSize.zero
    private var raw: CGFloat = 0
    private var swallowMomentum = false

    init(model: PanelModel, offset: ReferenceWritableKeyPath<PanelModel, CGFloat>, window: @escaping () -> NSWindow?,
         current: @escaping () -> UUID?, select: @escaping (UUID) -> Void) {
        self.model = model
        self.offset = offset
        self.window = window
        self.current = current
        self.select = select
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    private var tabs: [UUID] { model.workspace.tabs }

    /// The tab a swipe in this direction leads to (positive = fingers moving right = previous tab).
    private func neighbor(for value: CGFloat) -> UUID? {
        guard let id = current(), let index = tabs.firstIndex(of: id) else { return nil }
        let next = index + (value > 0 ? -1 : 1)
        return tabs.indices.contains(next) ? tabs[next] : nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = window(), event.window === window, event.hasPreciseScrollingDeltas else { return false }
        if event.momentumPhase != [] {
            let swallow = swallowMomentum
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled { swallowMomentum = false }
            return swallow
        }
        if event.phase == .mayBegin || event.phase == .began {
            axis = .undecided
            seen = .zero
            raw = 0
            swallowMomentum = false
            if event.phase == .mayBegin { return false }
        }
        if axis == .undecided {
            seen.width += abs(event.scrollingDeltaX)
            seen.height += abs(event.scrollingDeltaY)
            guard seen.width + seen.height >= 4 else { return false }
            let sideways = seen.width > seen.height * 1.5
            axis = sideways && current() != nil && tabs.count > 1 && !overSidewaysScroller(event, in: window) ? .horizontal : .vertical
        }
        guard axis == .horizontal else { return false }

        // The page follows the fingers whichever way "natural scrolling" is set.
        raw += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        if event.phase == .ended || event.phase == .cancelled {
            finish(cancelled: event.phase == .cancelled, width: window.frame.width)
            axis = .undecided
            swallowMomentum = true
        } else if !model.reduceMotion {
            // Nothing that way: the page resists.
            model[keyPath: offset] = neighbor(for: raw) == nil ? raw * 0.2 : raw
        } else {
            // Reduce Motion: the page stays put; only the pill shows where you're heading.
            model[keyPath: offset] = neighbor(for: raw) == nil ? 0 : (raw > 0 ? 1 : -1) * min(abs(raw), Self.threshold) * 0.001
            model.swipeHint = abs(raw) >= Self.threshold ? neighbor(for: raw) : nil
        }
        return true
    }

    private func finish(cancelled: Bool, width: CGFloat) {
        let value = raw
        raw = 0
        model.swipeHint = nil
        guard !cancelled, abs(value) >= Self.threshold, let target = neighbor(for: value) else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { model[keyPath: offset] = 0 }
            return
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if model.reduceMotion {
            model[keyPath: offset] = 0
            select(target)
            return
        }
        // The old page leaves the way it was going; the view slides the new one in when the tab changes.
        withAnimation(.easeIn(duration: 0.1)) { model[keyPath: offset] = (value > 0 ? 1 : -1) * max(abs(value) + 80, width * 0.3) }
        Task { @MainActor [select] in
            try? await Task.sleep(for: .milliseconds(90))
            select(target)
        }
    }

    /// True when the pointer is over something that itself scrolls sideways (a wide code block, a diff, the tab strip).
    private func overSidewaysScroller(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        while let current = view {
            if let scroll = current as? NSScrollView, let document = scroll.documentView,
               document.frame.width > scroll.contentView.bounds.width + 1 { return true }
            view = current.superview
        }
        return false
    }
}

extension PanelModel {
    /// The new tab arrives from the side it lives on and settles.
    func slideIn(_ offset: ReferenceWritableKeyPath<PanelModel, CGFloat>) {
        guard !reduceMotion else { self[keyPath: offset] = 0; return }
        self[keyPath: offset] = workspace.direction == .trailing ? 70 : -70
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { self[keyPath: offset] = 0 }
    }
}

/// How a page looks while it is being swiped, and the pill that names the tab you're heading to.
struct SwipeFeedback: ViewModifier {
    let model: PanelModel
    let offset: CGFloat
    let current: UUID?

    private var target: Conversation? {
        guard let current, let index = model.workspace.tabs.firstIndex(of: current), offset != 0 else { return nil }
        let next = index + (offset > 0 ? -1 : 1)
        guard model.workspace.tabs.indices.contains(next) else { return nil }
        return model.store.conversation(model.workspace.tabs[next])
    }

    func body(content: Content) -> some View {
        let distance = abs(offset)
        let hinted = model.swipeHint.flatMap { model.store.conversation($0) }
        let armed = distance >= TabSwipeTracker.threshold || hinted != nil
        content
            .offset(x: model.reduceMotion ? 0 : offset)
            .opacity(model.reduceMotion ? 1 : 1 - min(0.45, distance / 700))
            .overlay(alignment: offset > 0 ? .leading : .trailing) {
                if let target = hinted ?? target, model.reduceMotion || distance > 12 {
                    HStack(spacing: 6) {
                        if offset > 0 { Image(systemName: "chevron.left") }
                        Text(target.title.isEmpty ? "New chat" : target.title).lineLimit(1).frame(maxWidth: 200)
                        if offset <= 0 { Image(systemName: "chevron.right") }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(armed ? Color.white : Color.primary)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(armed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: armed ? 0 : 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .scaleEffect(armed ? 1.06 : 1)
                    .opacity(model.reduceMotion ? 1 : min(1, distance / 60))
                    .padding(.horizontal, 16)
                    .animation(.easeOut(duration: 0.12), value: armed)
                    .allowsHitTesting(false)
                }
            }
    }
}
