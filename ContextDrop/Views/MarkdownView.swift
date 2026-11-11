import AppKit
import SwiftUI

// MARK: - Model

struct MarkdownListItem: Hashable, Sendable {
    /// "•" for bullets, "1." for ordered items, "☐" / "☑" for task items.
    var marker: String
    var text: String
    /// 0 = top level, 1 = nested.
    var level: Int
}

struct MarkdownBlock: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case list([MarkdownListItem])
        case quote(String)
        case rule
        /// `closed` is false for a fence that has not been terminated yet (still streaming).
        case code(language: String?, code: String, closed: Bool)
        case table(header: [String], rows: [[String]])
        /// A malformed table, shown as monospaced text.
        case preformatted(String)
    }

    /// Index of the block in the document: stable while text is appended.
    var id: Int
    var kind: Kind
}

// MARK: - View

/// Block-level Markdown for chat answers. Inline styling inside blocks uses `AttributedString(markdown:)`.
struct MarkdownView: View {
    private let text: String
    private let fontSize: CGFloat
    private let streaming: Bool

    init(_ text: String, fontSize: CGFloat = 14, streaming: Bool = false) {
        self.text = text
        self.fontSize = fontSize
        self.streaming = streaming
    }

    var body: some View {
        let blocks = Self.parse(text)
        let lastID = blocks.last?.id
        let cursorFits = blocks.last.map(Self.canCarryCursor) ?? false
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                MarkdownBlockView(
                    block: block,
                    fontSize: fontSize,
                    cursor: streaming && cursorFits && block.id == lastID,
                    isFirst: block.id == 0
                )
                .equatable()
            }
            if streaming && !cursorFits {
                Text(Self.cursor).font(.system(size: fontSize))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private nonisolated static func canCarryCursor(_ block: MarkdownBlock) -> Bool {
        switch block.kind {
        case .paragraph, .heading, .list, .quote: true
        case .code(_, _, let closed): !closed
        case .rule, .table, .preformatted: false
        }
    }

    // MARK: Inline

    nonisolated static var cursor: AttributedString {
        var cursor = AttributedString(" ▍")
        cursor.foregroundColor = Color.accentColor
        return cursor
    }

    /// Inline Markdown (bold, italics, code, links) with a plain-text fallback, like `Text(markdown:)`.
    nonisolated static func inline(_ text: String, cursor: Bool = false) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        if cursor { result.append(Self.cursor) }
        return result
    }

    // MARK: Parsing (pure, one pass over the lines)

    nonisolated static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []

        func add(_ kind: MarkdownBlock.Kind) { blocks.append(MarkdownBlock(id: blocks.count, kind: kind)) }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            add(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let indent = leadingSpaces(line)
            let body = line.dropFirst(indent.characters)

            if body.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Fenced code (any indentation, so fences inside list items work).
            if let fence = openingFence(body) {
                flushParagraph()
                var code: [Substring] = []
                var closed = false
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    if isClosingFence(candidate, fence) { closed = true; index += 1; break }
                    code.append(dropIndent(candidate, upTo: indent.characters))
                    index += 1
                }
                add(.code(language: fence.language, code: code.joined(separator: "\n"), closed: closed))
                continue
            }

            if indent.width < 4, let heading = heading(body) {
                flushParagraph()
                add(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if indent.width < 4, isRule(body) {
                flushParagraph()
                add(.rule)
                index += 1
                continue
            }

            if indent.width < 4, body.first == ">" {
                flushParagraph()
                var quoted: [Substring] = []
                while index < lines.count {
                    let candidate = lines[index].drop(while: { $0 == " " || $0 == "\t" })
                    guard candidate.first == ">" else { break }
                    var rest = candidate.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quoted.append(rest)
                    index += 1
                }
                add(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if let first = listMarker(body), paragraph.isEmpty || first.canInterruptParagraph {
                flushParagraph()
                let baseIndent = indent.width
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let candidate = lines[index]
                    let candidateIndent = leadingSpaces(candidate)
                    let candidateBody = candidate.dropFirst(candidateIndent.characters)
                    if candidateBody.isEmpty {
                        // A blank line keeps the list going only when another item or an indented continuation follows.
                        guard index + 1 < lines.count else { break }
                        let next = lines[index + 1]
                        let nextIndent = leadingSpaces(next)
                        let nextBody = next.dropFirst(nextIndent.characters)
                        guard !nextBody.isEmpty, openingFence(nextBody) == nil, !isRule(nextBody),
                              listMarker(nextBody) != nil || nextIndent.width >= baseIndent + 2 else { break }
                        index += 1
                        continue
                    }
                    if openingFence(candidateBody) != nil { break }
                    if candidateIndent.width < 4, isRule(candidateBody) { break }
                    if let marker = listMarker(candidateBody) {
                        if candidateIndent.width < baseIndent { break }
                        items.append(MarkdownListItem(
                            marker: marker.display,
                            text: String(marker.text),
                            level: candidateIndent.width >= baseIndent + 2 ? 1 : 0
                        ))
                    } else if candidateIndent.width > baseIndent, !items.isEmpty {
                        items[items.count - 1].text += "\n" + candidateBody // continuation line
                    } else if !items.isEmpty, candidateIndent.width == baseIndent,
                              heading(candidateBody) == nil, candidateBody.first != ">", !isTableStart(lines, index) {
                        items[items.count - 1].text += "\n" + candidateBody // lazy continuation
                    } else {
                        break
                    }
                    index += 1
                }
                add(.list(items))
                continue
            }

            if isTableStart(lines, index) {
                flushParagraph()
                let start = index
                index += 2
                while index < lines.count, lines[index].contains("|"),
                      !lines[index].allSatisfy({ $0 == " " || $0 == "\t" }) {
                    index += 1
                }
                let header = cells(lines[start])
                let delimiter = cells(lines[start + 1])
                if header.count == delimiter.count, !header.isEmpty {
                    let rows = lines[(start + 2)..<index].map { row -> [String] in
                        var values = cells(row)
                        if values.count > header.count { values.removeLast(values.count - header.count) }
                        while values.count < header.count { values.append("") }
                        return values
                    }
                    add(.table(header: header, rows: rows))
                } else {
                    add(.preformatted(lines[start..<index].joined(separator: "\n")))
                }
                continue
            }

            paragraph.append(line.drop(while: { $0 == " " || $0 == "\t" }))
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Line classifiers

    private struct Indent { var characters: Int; var width: Int }

    private nonisolated static func leadingSpaces(_ line: Substring) -> Indent {
        var characters = 0, width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
            characters += 1
        }
        return Indent(characters: characters, width: width)
    }

    private nonisolated static func dropIndent(_ line: Substring, upTo count: Int) -> Substring {
        var remaining = count
        var rest = line
        while remaining > 0, let first = rest.first, first == " " || first == "\t" {
            rest = rest.dropFirst()
            remaining -= 1
        }
        return rest
    }

    private struct Fence: Equatable { var character: Character; var length: Int; var language: String? }

    private nonisolated static func openingFence(_ body: Substring) -> Fence? {
        guard let character = body.first, character == "`" || character == "~" else { return nil }
        let run = body.prefix(while: { $0 == character })
        guard run.count >= 3 else { return nil }
        let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if character == "`", info.contains("`") { return nil } // inline code such as ```x```
        let language = info.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "{" }).first.map(String.init)
        return Fence(character: character, length: run.count, language: language?.isEmpty == false ? language : nil)
    }

    private nonisolated static func isClosingFence(_ line: Substring, _ fence: Fence) -> Bool {
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        let run = body.prefix(while: { $0 == fence.character })
        guard run.count >= fence.length else { return false }
        return body.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private nonisolated static func heading(_ body: Substring) -> (level: Int, text: String)? {
        guard body.first == "#" else { return nil }
        let hashes = body.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = body.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes: "## Title ##"
        if text.hasSuffix("#") {
            let trimmed = text.reversed().drop(while: { $0 == "#" })
            if trimmed.isEmpty { text = "" } else if trimmed.first == " " { text = String(trimmed.reversed()).trimmingCharacters(in: .whitespaces) }
        }
        return (min(hashes.count, 4), text)
    }

    private nonisolated static func isRule(_ body: Substring) -> Bool {
        guard let character = body.first, character == "-" || character == "*" || character == "_" else { return false }
        var count = 0
        for other in body {
            if other == character { count += 1 } else if other != " " && other != "\t" { return false }
        }
        return count >= 3
    }

    private struct ListMarker { var display: String; var text: Substring; var canInterruptParagraph: Bool }

    private nonisolated static func listMarker(_ body: Substring) -> ListMarker? {
        guard let first = body.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = body.dropFirst()
            guard let space = rest.first, space == " " || space == "\t" else { return nil }
            var text = rest.drop(while: { $0 == " " || $0 == "\t" })
            var display = "•"
            if text.hasPrefix("[ ] ") { display = "☐"; text = text.dropFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { display = "☑"; text = text.dropFirst(4) }
            return ListMarker(display: display, text: text, canInterruptParagraph: true)
        }
        guard first.isASCII, first.isNumber else { return nil }
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        guard digits.count <= 9 else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        let afterDelimiter = rest.dropFirst()
        guard let space = afterDelimiter.first, space == " " || space == "\t" else { return nil }
        return ListMarker(
            display: "\(digits).",
            text: afterDelimiter.drop(while: { $0 == " " || $0 == "\t" }),
            canInterruptParagraph: digits == "1"
        )
    }

    /// A header row followed by a delimiter row such as `| --- | :-: |`.
    private nonisolated static func isTableStart(_ lines: [Substring], _ index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|"),
              lines[index].contains(where: { $0 != "|" && $0 != " " && $0 != "\t" }) else { return false }
        let delimiter = lines[index + 1]
        guard delimiter.contains("-"), delimiter.contains("|") || lines[index].contains("|") else { return false }
        var dashes = 0
        for character in delimiter {
            switch character {
            case "-": dashes += 1
            case "|", ":", " ", "\t": break
            default: return false
            }
        }
        return dashes >= 1 && delimiter.contains("|")
    }

    /// Cells of a table row; outer pipes are optional and `\|` is a literal pipe.
    private nonisolated static func cells(_ line: Substring) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

// MARK: - Block rendering

/// Equatable so a streaming flush only re-renders the blocks whose content changed.
private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let fontSize: CGFloat
    let cursor: Bool
    let isFirst: Bool

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            Text(MarkdownView.inline(text, cursor: cursor))
                .font(.system(size: fontSize))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(MarkdownView.inline(text, cursor: cursor))
                .font(.system(size: fontSize + headingBump(level), weight: .semibold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, isFirst ? 0 : (level <= 2 ? 4 : 2))
                .accessibilityAddTraits(.isHeader)

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: fontSize).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(MarkdownView.inline(item.text, cursor: cursor && offset == items.count - 1))
                            .font(.system(size: fontSize))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }

        case .quote(let text):
            Text(MarkdownView.inline(text, cursor: cursor))
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.25).fill(.tertiary).frame(width: 2.5)
                }

        case .rule:
            HairlineDivider().padding(.vertical, 2)

        case .code(let language, let code, _):
            MarkdownCodeBlock(language: language, code: code, cursor: cursor)

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, fontSize: fontSize)

        case .preformatted(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
    }

    private func headingBump(_ level: Int) -> CGFloat {
        switch level {
        case 1: 4
        case 2: 2.5
        case 3: 1
        default: 0
        }
    }
}

private struct MarkdownCodeBlock: View {
    let language: String?
    let code: String
    let cursor: Bool
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "code")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.disabled)
                Spacer(minLength: 8)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.primary : Color.secondary)
                .help("Copy code")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 24)
            HairlineDivider()
            ScrollView(.horizontal) {
                Text(display)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .onDisappear { resetTask?.cancel() }
    }

    /// Verbatim: code is never run through the Markdown parser.
    private var display: AttributedString {
        var text = AttributedString(code.isEmpty && !cursor ? " " : code)
        if cursor { text.append(MarkdownView.cursor) }
        return text
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = false }
        }
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let fontSize: CGFloat

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    self.cell(cell, weight: .semibold)
                }
            }
            .background(Color.primary.opacity(0.05))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HairlineDivider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        self.cell(cell, weight: .regular)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func cell(_ text: String, weight: Font.Weight) -> some View {
        Text(MarkdownView.inline(text))
            .font(.system(size: fontSize - 1, weight: weight))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
