import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A Quick Chat or workspace tab being dragged into the room (R5 board 6, option B). Only this app reads it.
    static let contextDropTab = UTType(exportedAs: "edu.cmu.hackathon.contextdrop.tab", conformingTo: .data)
}

extension NSPasteboard.PasteboardType {
    static let contextDropTab = NSPasteboard.PasteboardType(UTType.contextDropTab.identifier)
}

/// The payload of a tab drag: the conversation's id.
@MainActor
enum TabDrag {
    /// The tab being dragged, so a drop target can name it while it hovers (the payload itself is only read
    /// on drop). Never trusted on its own for a drop unless the payload is missing.
    static var current: UUID?
    /// Called once per drag, when the pointer leaves the window the tab was dragged from.
    static var onLeaveSourceWindow: (@MainActor () -> Void)?
    private static var watch: Timer?
    private static var leftSource = false

    static func provider(for id: UUID) -> NSItemProvider {
        current = id
        watchDrag()
        let data = Data(id.uuidString.utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.contextDropTab.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// SwiftUI gives no callbacks during a drag, so follow the pointer until the button comes up.
    private static func watchDrag() {
        watch?.invalidate()
        leftSource = false
        let mouse = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        guard let frame = NSApp.window(withWindowNumber: number)?.frame else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    watch?.invalidate()
                    watch = nil
                } else if !leftSource, !frame.contains(NSEvent.mouseLocation) {
                    leftSource = true
                    onLeaveSourceWindow?()
                }
            }
        }
        // Common modes include event tracking, which is what runs during a drag.
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    nonisolated static func id(from data: Data?) -> UUID? {
        data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(UUID.init(uuidString:))
    }

    /// Reads the dragged tab's id and hands it to `action` on the main actor. False when no tab is in the drop.
    static func load(_ providers: [NSItemProvider], then action: @escaping @MainActor (UUID) -> Void) -> Bool {
        let type = UTType.contextDropTab.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else { return false }
        let fallback = current
        _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let id = id(from: data) ?? fallback else { return }
            Task { @MainActor in action(id) }
        }
        return true
    }
}

/// Makes a tab draggable to the room canvas or Quick Chat's room target.
struct TabDragSource: ViewModifier {
    let conversation: Conversation
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, conversation.provider.roomShare != .none {
            content.onDrag {
                TabDrag.provider(for: conversation.id)
            } preview: {
                TabDragPreview(provider: conversation.provider, title: conversation.title)
            }
        } else {
            content
        }
    }
}

/// The drag preview: a dark, slightly tilted terminal chip — the CLI's name in green, then the tab's title.
struct TabDragPreview: View {
    let provider: ProviderKind
    let title: String

    private var command: String {
        switch provider {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .openAI: "chat"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(command).foregroundStyle(RoomPalette.dropZone)
            Text(title.isEmpty ? "New chat" : title).foregroundStyle(Color.white.opacity(0.92)).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 300, alignment: .leading)
        .fixedSize()
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .rotationEffect(.degrees(-2.5))
        .padding(14)
        .environment(\.colorScheme, .dark)
    }
}

/// Where a dragged tab will land on the canvas, in canvas points.
struct TabLanding: Equatable {
    var conversationID: UUID
    var title: String
    var origin: CGPoint
    var width: CGFloat
    /// The chat it will also be connected to, when it is over one.
    var chatID: UUID?
    var chatTitle: String?
}

/// The dashed green zone that shows where a dragged tab lands.
struct TabDropZone: View {
    let landing: TabLanding

    private var text: String {
        if let chat = landing.chatTitle { return "Drop to put “\(landing.title)” here and connect it to “\(chat)”" }
        return "Drop to put “\(landing.title)” here"
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(RoomPalette.runLabel)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(width: landing.width, height: 120)
            .background(RoomPalette.go.opacity(0.10), in: RoundedRectangle(cornerRadius: RoomMetrics.runRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RoomMetrics.runRadius, style: .continuous)
                    .strokeBorder(RoomPalette.dropZone, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Takes tab drops on the room canvas. Locations are in the canvas view's own space.
struct TabDropDelegate: DropDelegate {
    let hover: (CGPoint?) -> Void
    let perform: (UUID, CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.contextDropTab]) }

    func dropEntered(info: DropInfo) { hover(info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover(info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { hover(nil) }

    func performDrop(info: DropInfo) -> Bool {
        let location = info.location
        hover(nil)
        return TabDrag.load(info.itemProviders(for: [.contextDropTab])) { perform($0, location) }
    }
}
