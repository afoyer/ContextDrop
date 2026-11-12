import AppKit
import SwiftUI

/// A card being written or edited locally. Nothing is shared until it is committed.
struct RoomDraft: Equatable {
    /// The existing card being edited, or nil for a new thought.
    var cardID: UUID?
    var point: CGPoint
    var text: String = ""
}

/// Where this Mac is looking: the canvas has no edges, so the view is just an offset and a zoom.
/// It belongs to each person; nothing about it is shared.
struct RoomViewport: Equatable {
    static let zoomRange: ClosedRange<CGFloat> = 0.1...3

    /// Where canvas point (0, 0) sits in the view.
    var offset: CGSize = .zero
    var zoom: CGFloat = 1

    func toCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / zoom, y: (point.y - offset.height) / zoom)
    }

    func toCanvas(_ rect: CGRect) -> CGRect {
        CGRect(origin: toCanvas(rect.origin), size: CGSize(width: rect.width / zoom, height: rect.height / zoom))
    }

    /// Zooms so the canvas point under `anchor` (view coordinates) stays under it.
    mutating func setZoom(_ target: CGFloat, around anchor: CGPoint) {
        var next = min(max(target, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        if abs(next - 1) < 0.02 { next = 1 }
        let fixed = toCanvas(anchor)
        zoom = next
        offset = CGSize(width: anchor.x - fixed.x * next, height: anchor.y - fixed.y * next)
    }

    /// Shows all of `rect` (canvas coordinates) centred in a view of `size`, never zooming in past 100%.
    mutating func fit(_ rect: CGRect, in size: CGSize, padding: CGFloat = 80) {
        guard rect.width > 0, rect.height > 0, size.width > padding * 2, size.height > padding * 2 else { return }
        let scale = min((size.width - padding * 2) / rect.width, (size.height - padding * 2) / rect.height, 1)
        zoom = min(max(scale, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        offset = CGSize(width: size.width / 2 - rect.midX * zoom, height: size.height / 2 - rect.midY * zoom)
    }
}

/// The dotted canvas: endless in every direction. Two-finger scroll pans, pinch (or ⌘-scroll) zooms toward
/// the pointer, dragging empty canvas draws a selection box, and ⌥-drag or a middle-button drag pans.
struct RoomCanvas: View {
    let store: RoomStore
    @Binding var viewport: RoomViewport
    @Binding var selection: Set<UUID>
    @Binding var draft: RoomDraft?
    /// Measured tile sizes, in canvas points.
    @Binding var sizes: [UUID: CGSize]
    @Binding var viewSize: CGSize
    /// Chat tiles whose reply field has the keyboard. A set, not a flag: when focus moves from one tile
    /// to another, the two changes can arrive in either order.
    @Binding var typing: Set<UUID>
    /// Called on any click on the canvas, so the window can take focus away from the ask field.
    var onInteract: () -> Void = {}
    var onPopOut: (UUID) -> Void = { _ in }
    var onWatch: (UUID) -> Void = { _ in }
    var onOpenOwnRun: ((UUID) -> Void)?
    var onSpawn: (Set<UUID>) -> Void = { _ in }

    @State private var dragStart: [UUID: CGPoint] = [:]
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<UUID> = []
    @State private var panStart: CGSize?
    @State private var pinchStart: CGFloat?
    /// The chat tile a dragged run would be added to.
    @State private var runTarget: UUID?
    @FocusState private var focusedCard: UUID?

    private static let space = "roomCanvas"

    private var interactive: Bool { store.isActive }
    private var tiles: [RoomTile] { store.tiles }

    var body: some View {
        GeometryReader { geo in
            let visible = viewport.toCanvas(CGRect(origin: .zero, size: geo.size)).insetBy(dx: -300, dy: -300)
            ZStack(alignment: .topLeading) {
                dots(geo.size)
                background
                layer(visible: visible)
                if let marquee {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.1))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(pinch)
            .background {
                RoomCanvasInput(onScroll: scroll, onMiddleDrag: { delta in
                    viewport.offset.width += delta.width
                    viewport.offset.height += delta.height
                })
            }
            .onChange(of: geo.size, initial: true) { _, size in viewSize = size }
        }
        .background(RoomPalette.canvas)
    }

    // MARK: Background

    private func dots(_ size: CGSize) -> some View {
        let step = RoomMetrics.gridStep * viewport.zoom
        func phase(_ value: CGFloat) -> CGFloat {
            let r = value.truncatingRemainder(dividingBy: step)
            return (r < 0 ? r + step : r) - step
        }
        return Rectangle()
            .fill(ImagePaint(image: RoomDotGrid.tile, scale: viewport.zoom))
            .frame(width: size.width + step * 2, height: size.height + step * 2)
            .offset(x: phase(viewport.offset.width), y: phase(viewport.offset.height))
            // Zoomed far out the dots would turn into noise.
            .opacity(viewport.zoom < 0.4 ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var background: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                guard interactive else { return }
                commitDraft()
                onInteract()
                selection = []
                let point = viewport.toCanvas(value.location)
                draft = RoomDraft(point: CGPoint(x: point.x - 20, y: point.y - 20))
            })
            .simultaneousGesture(TapGesture().onEnded {
                commitDraft()
                onInteract()
                selection = []
            })
            .simultaneousGesture(backgroundDrag)
            .accessibilityHidden(true)
    }

    /// Dragging empty canvas selects with a box; with ⌥ held it pans.
    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if panStart == nil, marquee == nil {
                    commitDraft()
                    onInteract()
                    if NSEvent.modifierFlags.contains(.option) {
                        panStart = viewport.offset
                    } else {
                        marqueeBase = NSEvent.modifierFlags.contains(.shift) ? selection : []
                    }
                }
                if let start = panStart {
                    viewport.offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                    return
                }
                let box = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                 width: abs(value.translation.width), height: abs(value.translation.height))
                marquee = box
                let area = viewport.toCanvas(box)
                let hit = marqueeBase.union(tiles.filter { rect(of: $0).intersects(area) }.map(\.id))
                if hit != selection { selection = hit }
            }
            .onEnded { _ in
                panStart = nil
                marquee = nil
                marqueeBase = []
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? viewport.zoom
                pinchStart = start
                viewport.setZoom(start * value.magnification, around: value.startLocation)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Scroll pans; ⌘-scroll zooms toward the pointer. Returns false to let the view under the pointer scroll
    /// instead (an open chat's conversation).
    private func scroll(_ delta: CGSize, at point: CGPoint, zooming: Bool) -> Bool {
        if zooming {
            viewport.setZoom(viewport.zoom * exp(delta.height * 0.01), around: point)
            return true
        }
        let spot = viewport.toCanvas(point)
        if tiles.contains(where: { RoomMetrics.scrollsInside($0) && rect(of: $0).contains(spot) }) { return false }
        viewport.offset.width += delta.width
        viewport.offset.height += delta.height
        return true
    }

    // MARK: Tiles

    private func rect(of tile: RoomTile) -> CGRect { RoomMetrics.frame(for: tile, measured: sizes[tile.id]) }

    private func layer(visible: CGRect) -> some View {
        // Only what is in view is built; a tile being dragged or edited stays even if it leaves the view.
        let shown = tiles.filter { rect(of: $0).intersects(visible) || dragStart[$0.id] != nil || draft?.cardID == $0.id }
        return ZStack(alignment: .topLeading) {
            RoomLinks(links: links)
            ForEach(shown) { tile in
                tileItem(tile)
                    .opacity(draft?.cardID == tile.id ? 0 : 1)
                    .offset(x: tile.x, y: tile.y)
                    .zIndex(dragStart[tile.id] != nil ? 2 : selection.contains(tile.id) ? 1 : 0)
            }
            if let current = draft {
                RoomDraftEditor(text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }),
                                isNew: current.cardID == nil,
                                kind: current.cardID.flatMap { store.tile($0)?.card?.kind } ?? .thought,
                                onCommit: commitDraft,
                                onCancel: { draft = nil })
                    .offset(x: current.point.x, y: current.point.y)
                    .zIndex(3)
            }
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .scaleEffect(viewport.zoom, anchor: .topLeading)
        .offset(viewport.offset)
    }

    /// "Spawned from" links: from the middle of each source to the middle of the chat it led to.
    private var links: [RoomLinks.Link] {
        let spawned = tiles.filter { $0.chat?.spawnedFrom.isEmpty == false }
        guard !spawned.isEmpty else { return [] }
        let frames = Dictionary(tiles.map { ($0.id, rect(of: $0)) }, uniquingKeysWith: { first, _ in first })
        var result: [RoomLinks.Link] = []
        for tile in spawned {
            guard let to = frames[tile.id] else { continue }
            for sourceID in tile.chat?.spawnedFrom ?? [] {
                guard let from = frames[sourceID] else { continue }
                result.append(.init(id: "\(sourceID)-\(tile.id)", from: CGPoint(x: from.midX, y: from.midY), to: CGPoint(x: to.midX, y: to.midY)))
            }
        }
        return result
    }

    @ViewBuilder
    private func content(_ tile: RoomTile) -> some View {
        switch tile.content {
        case .card(let body):
            RoomCardView(card: body, addedBy: tile.addedBy).equatable()
        case .chat(let chat):
            RoomChatTileView(store: store, tile: tile, chat: chat, onPopOut: { onPopOut(tile.id) },
                             onTyping: { if $0 { typing.insert(tile.id) } else { typing.remove(tile.id) } })
        case .run(let run):
            RoomRunTileView(store: store, tile: tile, run: run, onWatch: { onWatch(tile.id) },
                            onOpenOwnRun: onOpenOwnRun.map { open in { open(tile.id) } })
        }
    }

    private func tileItem(_ tile: RoomTile) -> some View {
        let selected = selection.contains(tile.id)
        let radius = RoomMetrics.radius(for: tile)
        return content(tile)
            .overlay {
                if runTarget == tile.id {
                    RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
                        .strokeBorder(RoomPalette.running, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .padding(-2)
                } else if selected {
                    RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-2)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { sizes[tile.id] = $0 }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .modifier(CardKeys(enabled: interactive && tile.card != nil, id: tile.id, focus: $focusedCard,
                               onToggle: { toggle(tile.id) }, onNudge: { nudge(tile, $0) }))
            .gesture(drag(tile))
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if store.canEdit(tile) { beginEditing(tile) }
            })
            .simultaneousGesture(TapGesture().onEnded { tap(tile) })
            .contextMenu { menu(tile) }
            .accessibilityElement(children: tile.card != nil ? .ignore : .contain)
            .accessibilityLabel(tile.accessibilitySummary)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: selected ? "Deselect" : "Select") { toggle(tile.id) }
    }

    @ViewBuilder
    private func menu(_ tile: RoomTile) -> some View {
        switch tile.content {
        case .card(let body):
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(body.text, forType: .string)
            }
            if store.canEdit(tile) { Button("Edit") { beginEditing(tile) } }
        case .chat:
            Button("Pop Out") { onPopOut(tile.id) }
            Button(tile.collapsed ? "Expand" : "Collapse") { store.setCollapsed(tile.id, !tile.collapsed) }
        case .run(let run):
            Button("Watch") { onWatch(tile.id) }
            let chats = tiles.filter { $0.chat != nil && $0.chat?.runIDs.contains(tile.id) == false }
            if !chats.isEmpty, interactive {
                Menu("Add to Chat") {
                    ForEach(chats.prefix(12)) { chat in
                        Button(chat.chat?.title ?? "Chat") { store.attachRun(tile.id, to: chat.id) }
                    }
                }
            }
            if run.isLive { Button(tile.collapsed ? "Expand" : "Collapse") { store.setCollapsed(tile.id, !tile.collapsed) } }
        }
        if interactive {
            Button("New Chat from This") { onSpawn(selection.contains(tile.id) ? selection : [tile.id]) }
        }
        if store.canRemove(tile) {
            Divider()
            Button("Remove from Room", role: .destructive) {
                selection.remove(tile.id)
                store.removeTile(tile.id)
            }
        }
    }

    // MARK: Selection

    private func tap(_ tile: RoomTile) {
        commitDraft()
        onInteract()
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) || flags.contains(.command) {
            toggle(tile.id)
        } else if !selection.contains(tile.id) || tile.card != nil {
            selection = [tile.id]
        }
        if interactive, tile.card != nil { focusedCard = tile.id }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    // MARK: Moving

    /// Drags the tile, or the whole selection when the tile is part of it. Positions update every frame;
    /// the store throttles what goes over the network and sends the final position.
    /// A run let go over a chat is added to that chat (and goes back to where it was).
    private func drag(_ tile: RoomTile) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard interactive else { return }
                if dragStart.isEmpty {
                    var ids = selection
                    if !ids.contains(tile.id) {
                        ids = [tile.id]
                        selection = ids
                    }
                    var start: [UUID: CGPoint] = [:]
                    for other in tiles where ids.contains(other.id) { start[other.id] = other.position }
                    dragStart = start
                }
                for (id, origin) in dragStart { move(id, origin, value.translation) }
                runTarget = dragStart.count == 1 && tile.run != nil ? chatUnder(value.location, for: tile.id) : nil
            }
            .onEnded { value in
                if let target = runTarget, let origin = dragStart[tile.id] {
                    store.moveTile(tile.id, to: origin)
                    store.attachRun(tile.id, to: target)
                } else {
                    for (id, origin) in dragStart { move(id, origin, value.translation) }
                }
                runTarget = nil
                dragStart = [:]
            }
    }

    private func chatUnder(_ point: CGPoint, for runID: UUID) -> UUID? {
        tiles.last { $0.chat != nil && $0.chat?.runIDs.contains(runID) == false && rect(of: $0).contains(point) }?.id
    }

    private func move(_ id: UUID, _ origin: CGPoint, _ translation: CGSize) {
        store.moveTile(id, to: CGPoint(x: origin.x + translation.width, y: origin.y + translation.height))
    }

    private func nudge(_ tile: RoomTile, _ key: KeyEquivalent) {
        guard interactive else { return }
        let step = RoomMetrics.gridStep
        var point = tile.position
        switch key {
        case .leftArrow: point.x -= step
        case .rightArrow: point.x += step
        case .upArrow: point.y -= step
        default: point.y += step
        }
        store.moveTile(tile.id, to: point)
    }

    // MARK: Writing

    private func beginEditing(_ tile: RoomTile) {
        guard interactive, let card = tile.card else { return }
        commitDraft()
        draft = RoomDraft(cardID: tile.id, point: tile.position, text: card.text)
    }

    private func commitDraft() {
        guard let current = draft else { return }
        draft = nil
        let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = current.cardID {
            if store.tile(id)?.card?.text != text { store.editCard(id, text: text) }
        } else if let id = store.addCard(kind: .thought, text: text, at: current.point) {
            selection = [id]
        }
    }
}

/// Keyboard handling for a card: Return selects, the arrows nudge. Chat and run tiles keep their own controls.
private struct CardKeys: ViewModifier {
    let enabled: Bool
    let id: UUID
    var focus: FocusState<UUID?>.Binding
    let onToggle: () -> Void
    let onNudge: (KeyEquivalent) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusable()
                .focused(focus, equals: id)
                .onKeyPress(.return) { onToggle(); return .handled }
                .onKeyPress(.space) { onToggle(); return .handled }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    onNudge(press.key)
                    return .handled
                }
        } else {
            content
        }
    }
}

/// Dashed curves from the tiles a chat was spawned from to that chat, drawn under the tiles.
private struct RoomLinks: View {
    struct Link: Identifiable, Equatable {
        let id: String
        let from: CGPoint
        let to: CGPoint
    }

    let links: [Link]

    var body: some View {
        Path { path in
            for link in links {
                let bend = max(40, abs(link.to.x - link.from.x) * 0.45)
                path.move(to: link.from)
                path.addCurve(to: link.to,
                              control1: CGPoint(x: link.from.x + bend, y: link.from.y),
                              control2: CGPoint(x: link.to.x - bend, y: link.to.y))
            }
        }
        .stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 4]))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The in-place editor for a new thought or one of your own cards.
private struct RoomDraftEditor: View {
    @Binding var text: String
    let isNew: Bool
    let kind: RoomCardBody.Kind
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoomKindLabel(text: isNew ? "New thought" : kind.label, color: RoomPalette.labelColor(for: kind))
            TextField("A quick idea…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(2...12)
                .focused($focused)
                .onSubmit(onCommit)
                .onExitCommand(perform: onCancel)
                .accessibilityLabel(isNew ? "New thought" : "Card text")
            HStack(spacing: 8) {
                HintItem(key: "↵", label: isNew ? "Add" : "Save")
                HintItem(key: "esc", label: "Cancel")
                Spacer(minLength: 0)
                Button(isNew ? "Add" : "Save", action: onCommit)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: RoomMetrics.cardWidth + 30, alignment: .leading)
        .background(RoomPalette.fill(for: kind), in: RoundedRectangle(cornerRadius: RoomMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RoomMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .onAppear { focused = true }
    }
}

/// One 22 pt tile of the dot grid, drawn once at 2× and repeated by `ImagePaint`.
@MainActor
enum RoomDotGrid {
    static let tile: Image = {
        let scale = 2
        let side = Int(RoomMetrics.gridStep) * scale
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Image(systemName: "circle.fill")
        }
        // Mid grey with alpha reads as a quiet dot on both the light and the dark canvas.
        context.setFillColor(CGColor(gray: 0.5, alpha: 0.42))
        let dot = CGFloat(1.5 * Double(scale))
        context.fillEllipse(in: CGRect(x: (CGFloat(side) - dot) / 2, y: (CGFloat(side) - dot) / 2, width: dot, height: dot))
        guard let image = context.makeImage() else { return Image(systemName: "circle.fill") }
        return Image(decorative: image, scale: CGFloat(scale))
    }()
}

// MARK: - Scroll and middle-button input

/// Reads scroll-wheel and middle-button-drag events over the canvas. SwiftUI has no scroll gesture, so this
/// watches the window's events (the same way `TabSwipeTracker` does) and only acts on the ones over this view.
private struct RoomCanvasInput: NSViewRepresentable {
    /// Delta, location in the view (top-left origin), and whether ⌘ is held. Return true when it was used.
    let onScroll: (CGSize, CGPoint, Bool) -> Bool
    let onMiddleDrag: (CGSize) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.onScroll = onScroll
        view.onMiddleDrag = onMiddleDrag
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.onScroll = onScroll
        view.onMiddleDrag = onMiddleDrag
    }

    static func dismantleNSView(_ view: InputView, coordinator: ()) {
        view.removeMonitors()
    }

    final class InputView: NSView {
        var onScroll: ((CGSize, CGPoint, Bool) -> Bool)?
        var onMiddleDrag: ((CGSize) -> Void)?
        private var monitors: [Any] = []

        override var isFlipped: Bool { true }
        /// Never takes clicks: it only marks where the canvas is.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitors()
            guard window != nil else { return }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
                let used = MainActor.assumeIsolated { self?.scrolled(event) ?? false }
                return used ? nil : event
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDragged, handler: { [weak self] event in
                let used = MainActor.assumeIsolated { self?.middleDragged(event) ?? false }
                return used ? nil : event
            }) { monitors.append(monitor) }
        }

        func removeMonitors() {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []
        }

        private func location(_ event: NSEvent) -> CGPoint? {
            guard let window, event.window === window else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            return bounds.contains(point) ? point : nil
        }

        private func scrolled(_ event: NSEvent) -> Bool {
            guard let point = location(event), let onScroll else { return false }
            var delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            if !event.hasPreciseScrollingDeltas {
                // A mouse wheel reports lines, not points.
                delta.width *= 10
                delta.height *= 10
            }
            guard delta != .zero else { return false }
            return onScroll(delta, point, event.modifierFlags.contains(.command))
        }

        private func middleDragged(_ event: NSEvent) -> Bool {
            guard location(event) != nil, let onMiddleDrag else { return false }
            onMiddleDrag(CGSize(width: event.deltaX, height: event.deltaY))
            return true
        }
    }
}
