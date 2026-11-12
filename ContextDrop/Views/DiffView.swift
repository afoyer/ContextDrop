import AppKit
import SwiftUI

/// A compact unified diff: line-number gutter, +/- markers, tinted rows, hunk headers as separators.
struct DiffView: View {
    private let hunks: [DiffHunk]
    private let maxHeight: CGFloat?
    private let rows: [DiffRow]
    private let hiddenLines: Int
    private let numberWidth: CGFloat
    @State private var viewportWidth: CGFloat = 0

    /// Rows beyond this are summarised in a footer so a huge diff cannot stall layout.
    private static let maxRows = 1_500

    init(hunks: [DiffHunk], maxHeight: CGFloat? = 260) {
        self.hunks = hunks
        self.maxHeight = maxHeight

        var rows: [DiffRow] = []
        var total = 0
        var largest = 1
        for hunk in hunks {
            total += hunk.lines.count
            guard rows.count < Self.maxRows else { continue }
            if !hunk.header.isEmpty {
                rows.append(DiffRow(id: rows.count, header: hunk.header, line: nil))
            }
            for line in hunk.lines.prefix(max(0, Self.maxRows - rows.count)) {
                rows.append(DiffRow(id: rows.count, header: nil, line: line))
                largest = max(largest, line.oldNumber ?? 0, line.newNumber ?? 0)
            }
        }
        let shown = rows.reduce(0) { $0 + ($1.line == nil ? 0 : 1) }
        self.rows = rows
        self.hiddenLines = max(0, total - shown)
        self.numberWidth = CGFloat(max(2, String(largest).count)) * 6.5 + 6
    }

    var body: some View {
        Group {
            if let maxHeight {
                scroller
                    .frame(maxHeight: maxHeight)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal) { content }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summaryLabel)
    }

    private var scroller: some View {
        ScrollView([.horizontal, .vertical]) { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("No changes")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(rows) { row in
                if let line = row.line {
                    DiffLineRow(line: line, numberWidth: numberWidth)
                } else {
                    DiffHunkHeaderRow(text: row.header ?? "")
                }
            }
            if hiddenLines > 0 {
                DiffHunkHeaderRow(text: "… \(hiddenLines) more line\(hiddenLines == 1 ? "" : "s") not shown")
            }
        }
        .padding(.vertical, 4)
        // Rows stretch to the widest line, and at least to the visible width, so tints are full-bleed.
        .frame(minWidth: viewportWidth, alignment: .leading)
        .textSelection(.enabled)
    }

    private var summaryLabel: String {
        let counts = LineDiff.counts(hunks)
        return "Diff, \(counts.added) added, \(counts.removed) removed"
    }
}

private struct DiffRow: Identifiable {
    let id: Int
    let header: String?
    let line: DiffLine?
}

private struct DiffLineRow: View {
    let line: DiffLine
    let numberWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(markerColor)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            Text(displayText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)
                .accessibilityLabel(accessibilityText)
        }
        .frame(minHeight: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: numberWidth, alignment: .trailing)
            .textSelection(.disabled)
            .accessibilityHidden(true)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added: DiffColors.addedText
        case .removed: DiffColors.removedText
        case .context: .secondary
        }
    }

    private var fill: Color {
        switch line.kind {
        case .added: DiffColors.addedFill
        case .removed: DiffColors.removedFill
        case .context: .clear
        }
    }

    /// Tabs have no fixed width in `Text`; an empty string would collapse the row.
    private var displayText: String {
        if line.text.isEmpty { return " " }
        return line.text.contains("\t") ? line.text.replacingOccurrences(of: "\t", with: "    ") : line.text
    }

    private var accessibilityText: String {
        switch line.kind {
        case .added: "Added: \(line.text)"
        case .removed: "Removed: \(line.text)"
        case .context: line.text
        }
    }
}

private struct DiffHunkHeaderRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(minHeight: 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
    }
}

/// "+6 −1"
struct DiffStat: View {
    private let added: Int
    private let removed: Int

    init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundStyle(DiffColors.addedText)
            Text("\u{2212}\(removed)").foregroundStyle(DiffColors.removedText)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

/// Greens and reds that stay readable as text in both appearances; fills are opacity tints.
private enum DiffColors {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static let addedText = dynamic(light: NSColor(red: 0.10, green: 0.50, blue: 0.22, alpha: 1), dark: NSColor(red: 0.40, green: 0.85, blue: 0.48, alpha: 1))
    static let removedText = dynamic(light: NSColor(red: 0.78, green: 0.16, blue: 0.14, alpha: 1), dark: NSColor(red: 1.0, green: 0.50, blue: 0.46, alpha: 1))
    static let addedFill = dynamic(light: NSColor.systemGreen.withAlphaComponent(0.14), dark: NSColor.systemGreen.withAlphaComponent(0.18))
    static let removedFill = dynamic(light: NSColor.systemRed.withAlphaComponent(0.11), dark: NSColor.systemRed.withAlphaComponent(0.18))
}
