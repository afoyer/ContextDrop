import AppKit
import SwiftUI

enum RoomMetrics {
    static let cardWidth: CGFloat = 220
    static let chatWidth: CGFloat = 440
    static let runWidth: CGFloat = 400
    static let cardRadius: CGFloat = 12
    static let tileRadius: CGFloat = 14
    /// Run tiles are terminal windows: tighter corners than a chat.
    static let runRadius: CGFloat = 9
    static let gridStep: CGFloat = 22
    /// Height of an open chat tile's conversation. The tile scrolls inside itself.
    static let chatTranscriptHeight: CGFloat = 250

    static func width(for tile: RoomTile) -> CGFloat {
        switch tile.content {
        case .card: cardWidth
        case .chat: chatWidth
        case .run: runWidth
        }
    }

    static func radius(for tile: RoomTile) -> CGFloat {
        switch tile.content {
        case .card: cardRadius
        case .chat: tileRadius
        case .run: runRadius
        }
    }

    /// Where a tile sits on the canvas. `measured` is its size once it has been laid out;
    /// without it (off screen since the window opened) the height is a guess.
    static func frame(for tile: RoomTile, measured: CGSize? = nil) -> CGRect {
        CGRect(x: tile.x, y: tile.y, width: width(for: tile), height: measured?.height ?? estimatedHeight(for: tile))
    }

    static func estimatedHeight(for tile: RoomTile) -> CGFloat {
        switch tile.content {
        case .card: 130
        case .chat: tile.collapsed ? 110 : 460
        case .run(let run): run.isLive ? 420 : tile.collapsed ? 70 : 260
        }
    }

    /// Tiles that scroll inside themselves, so scrolling over them doesn't pan the canvas:
    /// an open chat (its conversation) and an open finished run (its summary).
    static func scrollsInside(_ tile: RoomTile) -> Bool {
        guard !tile.collapsed else { return false }
        switch tile.content {
        case .card: return false
        case .chat: return true
        case .run(let run): return !run.isLive
        }
    }
}

/// Room colors: system colors that follow light and dark.
enum RoomPalette {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color { Palette.dynamic(light: light, dark: dark) }

    static let header = Color(nsColor: .windowBackgroundColor)
    /// A slightly darker well than the header, in both appearances.
    static let canvas = dynamic(light: NSColor(white: 0.9, alpha: 1), dark: NSColor(white: 0.09, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(white: 0.17, alpha: 1))
    /// Chat and run tiles: one step quieter than a card, so their content carries.
    static let tile = dynamic(light: NSColor(white: 0.985, alpha: 1), dark: NSColor(white: 0.135, alpha: 1))
    static let tileHeader = Color.primary.opacity(0.035)
    /// A chat spawned from a selection.
    static let spawned = dynamic(light: NSColor(red: 0.93, green: 0.96, blue: 1.0, alpha: 1), dark: NSColor(red: 0.12, green: 0.165, blue: 0.23, alpha: 1))
    /// Thoughts: a warm yellow sticky note.
    static let thought = dynamic(light: NSColor(red: 1.0, green: 0.95, blue: 0.72, alpha: 1), dark: NSColor(red: 0.29, green: 0.25, blue: 0.11, alpha: 1))
    static let thoughtLabel = Palette.keptText
    static let border = dynamic(light: NSColor.black.withAlphaComponent(0.12), dark: NSColor.white.withAlphaComponent(0.14))
    static let chatLabel = dynamic(light: NSColor(red: 0.0, green: 0.4, blue: 0.85, alpha: 1), dark: NSColor(red: 0.61, green: 0.79, blue: 1.0, alpha: 1))
    static let runLabel = dynamic(light: NSColor(red: 0.1, green: 0.5, blue: 0.3, alpha: 1), dark: NSColor(red: 0.37, green: 0.83, blue: 0.59, alpha: 1))
    static let waitingLabel = dynamic(light: NSColor(red: 0.72, green: 0.42, blue: 0.0, alpha: 1), dark: NSColor(red: 1.0, green: 0.7, blue: 0.25, alpha: 1))
    static let running = Color(nsColor: .systemGreen)
    /// The button that starts something on your Mac ("Start run", "Put in room"): the green of "Acts".
    static let go = Color(red: 0.19, green: 0.64, blue: 0.42)
    static let waiting = Color(nsColor: .systemOrange)
    static let removed = dynamic(light: NSColor(red: 0.8, green: 0.2, blue: 0.15, alpha: 1), dark: NSColor(red: 1.0, green: 0.42, blue: 0.37, alpha: 1))

    static func fill(for kind: RoomCardBody.Kind) -> Color { kind == .thought ? thought : card }

    static func labelColor(for kind: RoomCardBody.Kind) -> Color {
        switch kind {
        case .thought, .keptAnswer: thoughtLabel
        case .note: .secondary
        }
    }

    static func labelColor(for tile: RoomTile) -> Color {
        switch tile.content {
        case .card(let body): labelColor(for: body.kind)
        case .chat: chatLabel
        case .run(let run):
            if case .waiting = run.state { waitingLabel } else { runLabel }
        }
    }
}

/// A small upper-case kind label ("CHAT", "THOUGHT").
struct RoomKindLabel: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.4)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

/// The chevron that folds a chat or run tile down to a couple of lines.
struct RoomCollapseButton: View {
    let collapsed: Bool
    /// "chat" or "run", for the accessibility label.
    let noun: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(collapsed ? "Expand" : "Collapse")
        .accessibilityLabel(collapsed ? "Expand \(noun)" : "Collapse \(noun)")
    }
}

extension View {
    /// The floating controls over the canvas (ask bar, zoom, notices): a rounded panel with a hairline border.
    func roomPanel(radius: CGFloat, fill: some ShapeStyle = .regularMaterial) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(fill, in: shape).overlay(shape.strokeBorder(RoomPalette.border, lineWidth: 0.5))
    }
}

/// A small rounded label for a file, a selected tile or a "started from" source.
struct RoomChip: View {
    let text: String
    var color: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(maxWidth: 170)
        .fixedSize()
    }
}

/// One card on the canvas: kind label, body, who added it. Purely visual; the canvas adds the gestures.
struct RoomCardView: View, Equatable {
    let card: RoomCardBody
    let addedBy: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoomKindLabel(text: card.kind.label, color: RoomPalette.labelColor(for: card.kind),
                          symbol: card.kind == .keptAnswer ? "star.fill" : nil)

            if card.text.isEmpty {
                Text("Empty")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            } else if card.looksLikeCode {
                Text(verbatim: card.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(18)
            } else if card.kind == .keptAnswer {
                Text(markdown: card.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(1.5)
                    .lineLimit(24)
            } else {
                Text(verbatim: card.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(1.5)
                    .lineLimit(16)
            }

            HStack(spacing: 5) {
                AvatarView(name: addedBy, size: 16)
                Text(card.caption.map { "\(addedBy) · from “\($0)”" } ?? addedBy).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: RoomMetrics.cardWidth, alignment: .leading)
        .background(RoomPalette.fill(for: card.kind), in: RoundedRectangle(cornerRadius: RoomMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RoomMetrics.cardRadius, style: .continuous)
                .strokeBorder(RoomPalette.border, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
    }
}

extension RoomCardBody {
    /// Notes can hold code; show those in a monospaced face.
    var looksLikeCode: Bool {
        guard kind == .note else { return false }
        if text.contains("```") { return true }
        guard text.contains("\n") else { return false }
        return text.contains("{") || text.contains(";") || text.contains("\n    ") || text.contains("\n\t") || text.contains("()")
    }
}

extension RoomTile {
    var accessibilitySummary: String {
        switch content {
        case .card(let body):
            return "\(body.kind.label) by \(addedBy): \(body.text.isEmpty ? "empty" : String(body.text.prefix(300)))"
        case .chat(let chat):
            let last = chat.lastReply.map { ". Last reply: \($0.text.prefix(200))" } ?? ""
            return "Chat “\(chat.title)”, \(chat.ownerName)’s, \(chat.files.count) file\(chat.files.count == 1 ? "" : "s")\(last)"
        case .run(let run):
            let state: String
            switch run.state {
            case .running: state = "running"
            case .waiting(let reason): state = reason
            case .done: state = "done"
            case .failed: state = "stopped with an error"
            }
            return "\(run.agent) run “\(run.title)” on \(run.ownerName)’s Mac, \(state)"
        }
    }
}
