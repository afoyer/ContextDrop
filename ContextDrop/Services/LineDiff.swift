import Foundation

/// One line of a unified diff, with its line number on each side (nil where it does not exist).
struct DiffLine: Hashable, Sendable, Codable {
    enum Kind: String, Sendable, Codable { case context, added, removed }
    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
}

struct DiffHunk: Hashable, Sendable, Codable, Identifiable {
    /// Index of the hunk within its file.
    var id: Int
    /// "@@ -a,b +c,d @@"
    var header: String
    var lines: [DiffLine]
}

/// Line diffing and unified-diff parsing. Pure; safe to call from any thread.
enum LineDiff {
    /// Above this many lines on either side the real diff is skipped (it can go quadratic).
    static let maxDiffableLines = 4_000
    /// Lines kept per side in the fallback hunk.
    static let fallbackLines = 400

    // MARK: Diff two texts

    static func hunks(old: String, new: String, context: Int = 3) -> [DiffHunk] {
        if old == new { return [] }
        let a = splitLines(old)
        let b = splitLines(new)
        if a.isEmpty && b.isEmpty { return [] }
        if a.count > maxDiffableLines || b.count > maxDiffableLines { return [fallbackHunk(a, b)] }

        let difference = b.difference(from: a)
        if difference.isEmpty { return [] } // differ only in the trailing newline
        var removed = [Bool](repeating: false, count: a.count)
        var inserted = [Bool](repeating: false, count: b.count)
        for change in difference {
            switch change {
            case .remove(let offset, _, _): if removed.indices.contains(offset) { removed[offset] = true }
            case .insert(let offset, _, _): if inserted.indices.contains(offset) { inserted[offset] = true }
            }
        }

        // Full edit script: removals before additions inside a change.
        struct Op { var line: DiffLine; var oldBefore: Int; var newBefore: Int }
        var ops: [Op] = []
        ops.reserveCapacity(a.count + difference.insertions.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed[i] {
                ops.append(Op(line: DiffLine(kind: .removed, text: String(a[i]), oldNumber: i + 1, newNumber: nil), oldBefore: i, newBefore: j))
                i += 1
            } else if j < b.count, inserted[j] {
                ops.append(Op(line: DiffLine(kind: .added, text: String(b[j]), oldNumber: nil, newNumber: j + 1), oldBefore: i, newBefore: j))
                j += 1
            } else if i < a.count, j < b.count {
                ops.append(Op(line: DiffLine(kind: .context, text: String(a[i]), oldNumber: i + 1, newNumber: j + 1), oldBefore: i, newBefore: j))
                i += 1; j += 1
            } else if i < a.count { // defensive: should not happen
                ops.append(Op(line: DiffLine(kind: .removed, text: String(a[i]), oldNumber: i + 1, newNumber: nil), oldBefore: i, newBefore: j))
                i += 1
            } else {
                ops.append(Op(line: DiffLine(kind: .added, text: String(b[j]), oldNumber: nil, newNumber: j + 1), oldBefore: i, newBefore: j))
                j += 1
            }
        }

        // Group changes into hunks with `context` lines either side; merge hunks whose context touches.
        let pad = max(0, context)
        var ranges: [Range<Int>] = []
        var index = 0
        while index < ops.count {
            guard ops[index].line.kind != .context else { index += 1; continue }
            var end = index
            while end < ops.count, ops[end].line.kind != .context { end += 1 }
            let lower = max(0, index - pad)
            let upper = min(ops.count, end + pad)
            if let last = ranges.last, lower <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(upper, last.upperBound)
            } else {
                ranges.append(lower..<upper)
            }
            index = end
        }

        return ranges.enumerated().map { number, range in
            let slice = ops[range]
            let lines = slice.map(\.line)
            let oldCount = lines.reduce(0) { $0 + ($1.kind == .added ? 0 : 1) }
            let newCount = lines.reduce(0) { $0 + ($1.kind == .removed ? 0 : 1) }
            let first = slice[slice.startIndex]
            // Like git: an empty side points at the line before the change (0 for a new file).
            let oldStart = oldCount == 0 ? first.oldBefore : first.oldBefore + 1
            let newStart = newCount == 0 ? first.newBefore : first.newBefore + 1
            return DiffHunk(id: number, header: header(oldStart, oldCount, newStart, newCount), lines: lines)
        }
    }

    private static func fallbackHunk(_ a: [Substring], _ b: [Substring]) -> DiffHunk {
        let old = a.prefix(fallbackLines)
        let new = b.prefix(fallbackLines)
        var lines: [DiffLine] = []
        lines.reserveCapacity(old.count + new.count)
        for (offset, text) in old.enumerated() {
            lines.append(DiffLine(kind: .removed, text: String(text), oldNumber: offset + 1, newNumber: nil))
        }
        for (offset, text) in new.enumerated() {
            lines.append(DiffLine(kind: .added, text: String(text), oldNumber: nil, newNumber: offset + 1))
        }
        return DiffHunk(id: 0, header: header(old.isEmpty ? 0 : 1, old.count, new.isEmpty ? 0 : 1, new.count), lines: lines)
    }

    private static func header(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }

    /// Lines without their terminators; a trailing newline does not produce an extra empty line.
    static func splitLines(_ text: String) -> [Substring] {
        if text.isEmpty { return [] }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    // MARK: Parse `git diff` output

    static func parseUnified(_ text: String) -> [(path: String, hunks: [DiffHunk])] {
        var files: [(path: String, hunks: [DiffHunk])] = []

        var hasFile = false
        var oldPath: String?
        var newPath: String?
        var gitPath: String?
        var hunks: [DiffHunk] = []

        var inHunk = false
        var hunkHeader = ""
        var hunkLines: [DiffLine] = []
        var oldNumber = 0, newNumber = 0
        var oldRemaining = 0, newRemaining = 0

        func closeHunk() {
            guard inHunk else { return }
            inHunk = false
            hunks.append(DiffHunk(id: hunks.count, header: hunkHeader, lines: hunkLines))
            hunkLines = []
        }
        func closeFile() {
            closeHunk()
            defer { hasFile = false; oldPath = nil; newPath = nil; gitPath = nil; hunks = [] }
            guard hasFile, !hunks.isEmpty else { return } // binary / mode-only / empty files carry no hunks
            let path = newPath ?? oldPath ?? gitPath ?? ""
            files.append((path: path, hunks: hunks))
        }

        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if inHunk {
                if raw.hasPrefix("\\") { continue } // "\ No newline at end of file"
                if oldRemaining > 0 || newRemaining > 0 {
                    let marker = raw.first
                    if marker == "+", newRemaining > 0 {
                        hunkLines.append(DiffLine(kind: .added, text: String(raw.dropFirst()), oldNumber: nil, newNumber: newNumber))
                        newNumber += 1; newRemaining -= 1
                        continue
                    }
                    if marker == "-", oldRemaining > 0 {
                        hunkLines.append(DiffLine(kind: .removed, text: String(raw.dropFirst()), oldNumber: oldNumber, newNumber: nil))
                        oldNumber += 1; oldRemaining -= 1
                        continue
                    }
                    // A context line; some tools strip the single leading space of an empty one.
                    if (marker == " " || raw.isEmpty), oldRemaining > 0, newRemaining > 0 {
                        hunkLines.append(DiffLine(kind: .context, text: String(raw.dropFirst()), oldNumber: oldNumber, newNumber: newNumber))
                        oldNumber += 1; newNumber += 1
                        oldRemaining -= 1; newRemaining -= 1
                        continue
                    }
                }
                closeHunk() // counts satisfied or the body is malformed: treat the line as a header
            }

            if raw.hasPrefix("diff ") {
                closeFile()
                hasFile = true
                gitPath = pathFromDiffLine(raw)
            } else if raw.hasPrefix("@@") {
                guard let range = parseHunkHeader(raw) else { continue }
                hasFile = true
                inHunk = true
                oldNumber = range.oldStart; newNumber = range.newStart
                oldRemaining = range.oldCount; newRemaining = range.newCount
                // An empty side points at the line before; numbering starts after it.
                if range.oldCount == 0 { oldNumber += 1 }
                if range.newCount == 0 { newNumber += 1 }
                hunkHeader = header(range.oldStart, range.oldCount, range.newStart, range.newCount)
            } else if raw.hasPrefix("--- ") {
                if hasFile, !hunks.isEmpty { closeFile() } // plain `diff -u` output has no "diff" line
                hasFile = true
                oldPath = cleanPath(raw.dropFirst(4))
            } else if raw.hasPrefix("+++ ") {
                hasFile = true
                newPath = cleanPath(raw.dropFirst(4))
            } else if raw.hasPrefix("rename to ") {
                gitPath = String(raw.dropFirst("rename to ".count))
            }
            // Everything else (index, new/deleted file mode, similarity, "Binary files … differ",
            // "GIT binary patch", commit text) is ignored.
        }
        closeFile()
        return files
    }

    /// "@@ -a,b +c,d @@ trailing" with optional counts (a missing count means 1).
    private static func parseHunkHeader(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let oldPart = parts.first(where: { $0.hasPrefix("-") }),
              let newPart = parts.first(where: { $0.hasPrefix("+") }),
              let old = parseRange(oldPart.dropFirst()),
              let new = parseRange(newPart.dropFirst()) else { return nil }
        return (old.start, old.count, new.start, new.count)
    }

    private static func parseRange(_ text: Substring) -> (start: Int, count: Int)? {
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let first = pieces.first, let start = Int(first), start >= 0 else { return nil }
        if pieces.count > 1 {
            guard let count = Int(pieces[1]), count >= 0 else { return nil }
            return (start, min(count, 1_000_000))
        }
        return (start, 1)
    }

    /// Path from a "--- a/x" / "+++ b/x" line; nil for /dev/null.
    private static func cleanPath(_ text: Substring) -> String? {
        var path = text
        if let tab = path.firstIndex(of: "\t") { path = path[..<tab] } // `diff -u` appends a timestamp
        var value = path.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        if value == "/dev/null" || value.isEmpty { return nil }
        if value.hasPrefix("a/") || value.hasPrefix("b/") { value = String(value.dropFirst(2)) }
        return value
    }

    /// Best-effort path from "diff --git a/x b/x" (used when there are no ---/+++ lines).
    private static func pathFromDiffLine(_ line: Substring) -> String? {
        guard let range = line.range(of: " b/", options: .backwards) else {
            return line.split(separator: " ").last.map(String.init)
        }
        var value = String(line[range.upperBound...])
        if value.hasSuffix("\"") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    // MARK: Summaries

    static func counts(_ hunks: [DiffHunk]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .added: added += 1
                case .removed: removed += 1
                case .context: break
                }
            }
        }
        return (added, removed)
    }

    /// A patch-shaped text for "Copy diff".
    static func unifiedText(path: String, hunks: [DiffHunk]) -> String {
        let isNew = hunks.first?.header.hasPrefix("@@ -0,0 ") == true
        let isDeleted = hunks.count == 1 && hunks[0].header.contains(" +0,0 ")
        var out = "--- " + (isNew ? "/dev/null" : "a/" + path) + "\n"
        out += "+++ " + (isDeleted ? "/dev/null" : "b/" + path) + "\n"
        for hunk in hunks {
            out += hunk.header + "\n"
            for line in hunk.lines {
                switch line.kind {
                case .context: out += " "
                case .added: out += "+"
                case .removed: out += "-"
                }
                out += line.text + "\n"
            }
        }
        return out
    }
}
