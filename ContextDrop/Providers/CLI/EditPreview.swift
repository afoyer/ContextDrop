import Foundation

/// Works out what an edit tool will change (before it runs) or did change (after).
enum EditPreview {
    static let maxBytes = 600_000

    static func read(_ path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= maxBytes else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func edits(tool: String, input: [String: Any]) -> [(old: String, new: String, all: Bool)] {
        if let list = input["edits"] as? [[String: Any]] {
            return list.map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "", $0["replace_all"] as? Bool ?? false) }
        }
        return [(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "", input["replace_all"] as? Bool ?? false)]
    }

    private static func replace(_ text: String, _ old: String, _ new: String, all: Bool) -> String? {
        guard !old.isEmpty, let range = text.range(of: old) else { return nil }
        return all ? text.replacingOccurrences(of: old, with: new) : text.replacingCharacters(in: range, with: new)
    }

    /// Before/after of an edit that hasn't run yet. `current` is the file as it is now.
    static func texts(tool: String, input: [String: Any], current: String?) -> (before: String, after: String)? {
        if tool == "Write" { return (current ?? "", input["content"] as? String ?? "") }
        let list = edits(tool: tool, input: input)
        if let current {
            var after = current
            var applied = true
            for edit in list {
                if let next = replace(after, edit.old, edit.new, all: edit.all) { after = next } else { applied = false; break }
            }
            if applied { return (current, after) }
        }
        // The file couldn't be read or didn't match: show just the snippets.
        return (list.map(\.old).joined(separator: "\n"), list.map(\.new).joined(separator: "\n"))
    }

    /// Before/after of an edit that already ran, by undoing it on the file as it is now.
    static func reversed(tool: String, input: [String: Any], current: String?) -> (before: String, after: String)? {
        let list = edits(tool: tool, input: input)
        if let current {
            var before = current
            var undone = true
            for edit in list.reversed() {
                if let previous = replace(before, edit.new, edit.old, all: edit.all) { before = previous } else { undone = false; break }
            }
            if undone { return (before, current) }
        }
        return (list.map(\.old).joined(separator: "\n"), list.map(\.new).joined(separator: "\n"))
    }
}
