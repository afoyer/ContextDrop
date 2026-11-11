import AppKit
import SwiftUI

/// A card being written or edited locally. Nothing is shared until it is committed.
struct RoomDraft: Equatable {
    /// The existing card being edited, or nil for a new thought.
    var cardID: UUID?
    var point: CGPoint
    var text: String = ""
}

/// The dotted table: cards at their unscaled positions, with zoom applied as one scale transform.
struct RoomCanvas: View {
    let store: RoomStore
    @Binding var selection: Set<UUID>
    @Binding var draft: RoomDraft?
    let zoom: CGFloat
    /// Called on any click on the table, so the window can take focus away from the ask field.
    var onInteract: () -> Void = {}

    @State private var dragStart: [UUID: CGPoint] = [:]
    @FocusState private var focusedCard: UUID?

    private static let space = "roomCanvas"

    private var interactive: Bool { store.isActive }

    var body: some View {
        let width = CGFloat(RoomLimits.canvasWidth), height = CGFloat(RoomLimits.canvasHeight)
        ScrollView([.horizontal, .vertical]) {
            surface
                .frame(width: width, height: height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: width * zoom, height: height * zoom, alignment: .topLeading)
        }
        .background(RoomPalette.canvas)
    }

    private var surface: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(ImagePaint(image: RoomDotGrid.tile))
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    guard interactive else { return }
                    commitDraft()
                    onInteract()
                    selection = []
                    draft = RoomDraft(point: CGPoint(x: value.location.x - 20, y: value.location.y - 20))
                })
                .simultaneousGesture(TapGesture().onEnded {
                    commitDraft()
                    onInteract()
                    selection = []
                })
                .accessibilityHidden(true)

            ForEach(store.room?.cards ?? []) { card in
                cardItem(card)
                    .opacity(draft?.cardID == card.id ? 0 : 1)
                    .offset(x: card.x, y: card.y)
            }

            if let current = draft {
                RoomDraftEditor(text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }),
                                isNew: current.cardID == nil,
                                kind: current.cardID.flatMap { store.card($0)?.kind } ?? .thought,
                                onCommit: commitDraft,
                                onCancel: { draft = nil })
                    .offset(x: current.point.x, y: current.point.y)
            }
        }
        .coordinateSpace(name: Self.space)
    }

    private func cardItem(_ card: RoomCard) -> some View {
        let selected = selection.contains(card.id)
        return RoomCardView(card: card, isSelected: selected, isStreaming: store.streamingCardIDs.contains(card.id))
            .contentShape(RoundedRectangle(cornerRadius: RoomMetrics.cardRadius, style: .continuous))
            .focusable(interactive)
            .focused($focusedCard, equals: card.id)
            .gesture(drag(card))
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if store.canEdit(card), !card.isAIAnswer { beginEditing(card) }
            })
            .simultaneousGesture(TapGesture().onEnded { tap(card) })
            .onKeyPress(.space) { toggle(card.id); return .handled }
            .onKeyPress(.return) { toggle(card.id); return .handled }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                nudge(card, press.key)
                return .handled
            }
            .contextMenu {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(card.text, forType: .string)
                }
                if store.canEdit(card), !card.isAIAnswer {
                    Button("Edit") { beginEditing(card) }
                }
                if store.canRemove(card) {
                    Divider()
                    Button("Remove from Table", role: .destructive) {
                        selection.remove(card.id)
                        store.removeCard(card.id)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.accessibilitySummary)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Selects the card for asking the room")
            .accessibilityAction { toggle(card.id) }
    }

    // MARK: Selection

    private func tap(_ card: RoomCard) {
        commitDraft()
        onInteract()
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) || flags.contains(.command) {
            toggle(card.id)
        } else {
            selection = [card.id]
        }
        if interactive { focusedCard = card.id }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    // MARK: Moving

    /// Drags the card, or the whole selection when the card is part of it. Positions update every frame;
    /// the store throttles what goes over the network and sends the final position.
    private func drag(_ card: RoomCard) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard interactive else { return }
                if dragStart.isEmpty {
                    var ids = selection
                    if !ids.contains(card.id) {
                        ids = [card.id]
                        selection = ids
                    }
                    var start: [UUID: CGPoint] = [:]
                    for other in store.room?.cards ?? [] where ids.contains(other.id) { start[other.id] = other.position }
                    dragStart = start
                    for (id, origin) in start { move(id, origin, value.translation) }
                } else {
                    for (id, origin) in dragStart { move(id, origin, value.translation) }
                }
            }
            .onEnded { value in
                for (id, origin) in dragStart { move(id, origin, value.translation) }
                dragStart = [:]
            }
    }

    private func move(_ id: UUID, _ origin: CGPoint, _ translation: CGSize) {
        store.moveCard(id, to: CGPoint(x: origin.x + translation.width, y: origin.y + translation.height))
    }

    private func nudge(_ card: RoomCard, _ key: KeyEquivalent) {
        guard interactive else { return }
        let step = RoomMetrics.gridStep
        var point = card.position
        switch key {
        case .leftArrow: point.x -= step
        case .rightArrow: point.x += step
        case .upArrow: point.y -= step
        default: point.y += step
        }
        store.moveCard(card.id, to: point)
    }

    // MARK: Writing

    private func beginEditing(_ card: RoomCard) {
        guard interactive else { return }
        commitDraft()
        draft = RoomDraft(cardID: card.id, point: card.position, text: card.text)
    }

    private func commitDraft() {
        guard let current = draft else { return }
        draft = nil
        let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = current.cardID {
            if store.card(id)?.text != text { store.editCard(id, text: text) }
        } else {
            let id = store.addCard(kind: .thought, text: text, at: current.point)
            if store.card(id) != nil { selection = [id] }
        }
    }
}

/// The in-place editor for a new thought or one of your own cards.
private struct RoomDraftEditor: View {
    @Binding var text: String
    let isNew: Bool
    let kind: RoomCard.Kind
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((isNew ? "New thought" : kind.label).uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(kind == .note ? AnyShapeStyle(.secondary) : AnyShapeStyle(RoomPalette.thoughtLabel))
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
        // Mid grey with alpha reads as a quiet dot on both the light and the dark table.
        context.setFillColor(CGColor(gray: 0.5, alpha: 0.42))
        let dot = CGFloat(1.5 * Double(scale))
        context.fillEllipse(in: CGRect(x: (CGFloat(side) - dot) / 2, y: (CGFloat(side) - dot) / 2, width: dot, height: dot))
        guard let image = context.makeImage() else { return Image(systemName: "circle.fill") }
        return Image(decorative: image, scale: CGFloat(scale))
    }()
}
