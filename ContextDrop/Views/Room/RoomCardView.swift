import AppKit
import SwiftUI

enum RoomMetrics {
    static let cardWidth: CGFloat = 220
    static let answerCardWidth: CGFloat = 300
    static let cardRadius: CGFloat = 12
    static let gridStep: CGFloat = 22

    static func width(for card: RoomCard) -> CGFloat { card.isAIAnswer ? answerCardWidth : cardWidth }
}

/// Room colors: system colors that follow light and dark.
enum RoomPalette {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static let header = Color(nsColor: .windowBackgroundColor)
    /// A slightly darker well than the header, in both appearances.
    static let canvas = dynamic(light: NSColor(white: 0.9, alpha: 1), dark: NSColor(white: 0.09, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(white: 0.17, alpha: 1))
    /// Thoughts: a warm yellow sticky note.
    static let thought = dynamic(light: NSColor(red: 1.0, green: 0.95, blue: 0.72, alpha: 1), dark: NSColor(red: 0.29, green: 0.25, blue: 0.11, alpha: 1))
    static let thoughtLabel = Palette.keptText
    static let border = dynamic(light: NSColor.black.withAlphaComponent(0.12), dark: NSColor.white.withAlphaComponent(0.14))

    static func fill(for kind: RoomCard.Kind) -> Color { kind == .thought ? thought : card }

    static func labelColor(for card: RoomCard) -> Color {
        if card.isAIAnswer { return .accentColor }
        switch card.kind {
        case .thought, .keptAnswer: return thoughtLabel
        case .note: return .secondary
        }
    }
}

/// One card on the table: kind label, body, who added it. Purely visual; the canvas adds the gestures.
struct RoomCardView: View {
    let card: RoomCard
    var isSelected = false
    var isStreaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if card.kind == .keptAnswer {
                    Image(systemName: "star.fill").font(.system(size: 9.5, weight: .bold))
                } else if card.isAIAnswer {
                    Image(systemName: "sparkles").font(.system(size: 9.5, weight: .bold))
                }
                Text(card.displayLabel.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .kerning(0.4)
                    .lineLimit(1)
            }
            .foregroundStyle(RoomPalette.labelColor(for: card))

            if let question = card.question, !question.isEmpty {
                Text(question)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if card.text.isEmpty {
                Text(card.isAIAnswer ? "Thinking…" : "Empty")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            } else if card.looksLikeCode {
                Text(verbatim: card.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(18)
            } else if card.isAIAnswer {
                Text(markdown: card.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(1.5)
                    .lineLimit(30)
            } else {
                Text(verbatim: card.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(1.5)
                    .lineLimit(16)
            }

            HStack(spacing: 5) {
                AvatarView(name: card.authorName, size: 16)
                Text(card.authorName).lineLimit(1)
                if isStreaming {
                    ProgressView().controlSize(.mini).accessibilityLabel("Answering")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if let caption = card.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: RoomMetrics.width(for: card), alignment: .leading)
        .background(RoomPalette.fill(for: card.kind), in: RoundedRectangle(cornerRadius: RoomMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RoomMetrics.cardRadius, style: .continuous)
                .strokeBorder(RoomPalette.border, lineWidth: 0.5)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: RoomMetrics.cardRadius + 2, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-2)
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
    }
}

extension RoomCard {
    /// Notes can hold code; show those in a monospaced face.
    var looksLikeCode: Bool {
        guard kind == .note, !isAIAnswer else { return false }
        if text.contains("```") { return true }
        guard text.contains("\n") else { return false }
        return text.contains("{") || text.contains(";") || text.contains("\n    ") || text.contains("\n\t") || text.contains("()")
    }

    var accessibilitySummary: String {
        let body = text.isEmpty ? "empty" : String(text.prefix(300))
        if let question, isAIAnswer { return "\(displayLabel) to “\(question)”, asked by \(authorName): \(body)" }
        return "\(displayLabel) by \(authorName): \(body)"
    }
}
