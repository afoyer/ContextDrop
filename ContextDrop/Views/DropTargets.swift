import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// R3 board 2: dropping files shows three targets side by side — Attach, Run a skill on it, New tab.
/// The target under the pointer wins; holding ⌥ always attaches.
struct DropTargetsOverlay: View {
    let zone: PanelModel.DropAction?
    var cornerRadius: CGFloat = 16
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            target(.attach, icon: "paperclip", title: "Attach", detail: "Add to the message · ⌥")
            target(.runSkill, icon: "lightbulb", title: "Run a skill on it", detail: "Pick a skill next")
            target(.newTab, icon: "plus.rectangle.on.rectangle", title: "New tab", detail: "Start a chat with it")
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }

    private func target(_ action: PanelModel.DropAction, icon: String, title: String, detail: String) -> some View {
        let active = zone == action
        return VStack(spacing: compact ? 2 : 6) {
            Image(systemName: icon).font(.system(size: compact ? 15 : 20, weight: .medium))
            Text(title).font(.system(size: 13, weight: .semibold))
            if !compact { Text(detail).font(.system(size: 11)).foregroundStyle(active ? Color.white.opacity(0.85) : .secondary) }
        }
        .foregroundStyle(active ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(active ? Color.accentColor : Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(active ? 0 : 0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
    }
}

/// Tracks which third of the view the pointer is over and performs the drop.
struct FileDropDelegate: DropDelegate {
    @Binding var targeted: Bool
    @Binding var zone: PanelModel.DropAction?
    let width: CGFloat
    let enabled: Bool
    let perform: @MainActor ([URL], PanelModel.DropAction) -> Void

    private func zone(at location: CGPoint) -> PanelModel.DropAction {
        if NSEvent.modifierFlags.contains(.option) { return .attach }
        let third = max(1, width / 3)
        switch location.x {
        case ..<third: return .attach
        case ..<(third * 2): return .runSkill
        default: return .newTab
        }
    }

    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        targeted = true
        zone = zone(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = zone(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        targeted = false
        zone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let action = zone(at: info.location)
        targeted = false
        zone = nil
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            let urls = await Self.urls(from: providers)
            if !urls.isEmpty { perform(urls, action) }
        }
        return true
    }

    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}

extension View {
    /// The three drop targets over this view, for files dropped into `conversationID` (nil = home).
    func fileDropTargets(model: PanelModel, conversationID: @escaping @MainActor () -> UUID?, enabled: Bool = true,
                         cornerRadius: CGFloat = 16) -> some View {
        modifier(FileDropTargets(model: model, conversationID: conversationID, enabled: enabled, cornerRadius: cornerRadius))
    }
}

private struct FileDropTargets: ViewModifier {
    let model: PanelModel
    let conversationID: @MainActor () -> UUID?
    let enabled: Bool
    let cornerRadius: CGFloat
    @State private var targeted = false
    @State private var zone: PanelModel.DropAction?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay {
                if targeted && enabled {
                    DropTargetsOverlay(zone: zone, cornerRadius: cornerRadius, compact: size.height < 150)
                        .transition(.opacity)
                }
            }
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(targeted: $targeted, zone: $zone, width: size.width, enabled: enabled) { urls, action in
                model.handleDrop(urls, action: action, in: conversationID())
            })
    }
}
