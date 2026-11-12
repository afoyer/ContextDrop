import Foundation
import Observation

/// A Claude Code skill found on disk (a folder with a SKILL.md).
struct Skill: Identifiable, Hashable, Sendable {
    /// Unique: source + name.
    var id: String
    var name: String
    var description: String
    /// "your skills folder" | "this project" | "<plugin> plugin"
    var source: String
    /// Path of the SKILL.md.
    var path: String
    var takesImages: Bool
}

/// The skills available to a coding agent in the current project. Scans off the main actor.
@MainActor @Observable final class SkillCatalog {
    /// One catalog for the app (the `/` list, slash parsing and drop suggestions all read it).
    static let shared = SkillCatalog()

    private(set) var skills: [Skill] = []

    @ObservationIgnored private var lastKey: String?
    @ObservationIgnored private var lastScan: Date?
    @ObservationIgnored private var scan: Task<Void, Never>?

    /// Rescans in the background and publishes on the main actor. Cheap to call often:
    /// a scan of the same folder less than 5 s ago is reused.
    func refresh(projectFolder: URL?) {
        let key = projectFolder?.standardizedFileURL.path ?? ""
        if key == lastKey, let lastScan, Date().timeIntervalSince(lastScan) < 5 { return }
        lastKey = key
        lastScan = Date()
        scan?.cancel() // a scan for another folder is now stale
        scan = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                SkillScanner.scan(projectFolder: projectFolder)
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.skills != found { self.skills = found }
        }
    }

    /// Name-prefix matches, then name-substring, then description matches; at most 30.
    /// An empty query returns everything (capped). With `preferImages`, image-capable skills lead each group.
    func matches(_ query: String, preferImages: Bool = false) -> [Skill] {
        SkillScanner.rank(skills, query: query, preferImages: preferImages)
    }

    func skill(named name: String) -> Skill? {
        var wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        if wanted.hasPrefix("/") { wanted.removeFirst() }
        guard !wanted.isEmpty else { return nil }
        if let exact = skills.first(where: { $0.name.lowercased() == wanted }) { return exact }
        // "plugin:skill", the way Claude Code namespaces plugin skills.
        guard let colon = wanted.lastIndex(of: ":") else { return nil }
        let short = String(wanted[wanted.index(after: colon)...])
        let plugin = String(wanted[..<colon])
        return skills.first { $0.name.lowercased() == short && $0.source.lowercased() == "\(plugin) plugin" }
            ?? skills.first { $0.name.lowercased() == short }
    }
}

/// Pure, nonisolated scanning and parsing. Never throws or traps on unreadable input.
enum SkillScanner {
    static let maxSkills = 500
    static let maxDescription = 300
    static let maxMatches = 30
    /// Front matter lives at the top; never read more of a SKILL.md than this.
    private static let maxBytes = 32 * 1024
    private static let maxEntriesPerFolder = 2_000

    // MARK: Ranking

    static func rank(_ skills: [Skill], query: String, preferImages: Bool) -> [Skill] {
        var needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.hasPrefix("/") { needle.removeFirst() }

        var groups: [[Skill]] = [[], [], []]
        if needle.isEmpty {
            groups[0] = skills
        } else {
            for skill in skills {
                let name = skill.name.lowercased()
                if name.hasPrefix(needle) {
                    groups[0].append(skill)
                } else if name.contains(needle) {
                    groups[1].append(skill)
                } else if skill.description.lowercased().contains(needle) {
                    groups[2].append(skill)
                }
            }
        }
        var result: [Skill] = []
        for group in groups {
            if preferImages {
                result += group.filter(\.takesImages) + group.filter { !$0.takesImages }
            } else {
                result += group
            }
            if result.count >= maxMatches { break }
        }
        return Array(result.prefix(maxMatches))
    }

    // MARK: Scanning

    static func scan(projectFolder: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Skill] {
        var skills: [Skill] = []
        var seen = Set<String>()

        func collect(root: URL, source: String) {
            guard skills.count < maxSkills else { return }
            for folder in children(of: root) {
                guard skills.count < maxSkills else { return }
                guard let skill = readSkill(folder: folder, source: source) else { continue }
                guard seen.insert(skill.name.lowercased()).inserted else { continue }
                skills.append(skill)
            }
        }

        if let projectFolder {
            collect(root: projectFolder.appendingPathComponent(".claude/skills", isDirectory: true), source: "this project")
        }
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        collect(root: claude.appendingPathComponent("skills", isDirectory: true), source: "your skills folder")
        for plugin in installedPlugins(claude.appendingPathComponent("plugins", isDirectory: true)) {
            collect(root: plugin.root.appendingPathComponent("skills", isDirectory: true), source: "\(plugin.name) plugin")
        }
        return skills
    }

    /// Install roots from `installed_plugins.json`; if that is missing or unrecognised, the newest
    /// version folder of each plugin in the cache.
    static func installedPlugins(_ pluginsFolder: URL) -> [(name: String, root: URL)] {
        let manifest = pluginsFolder.appendingPathComponent("installed_plugins.json")
        if let data = readHead(manifest, limit: 4 * 1024 * 1024),
           let found = pluginsFromManifest(data), !found.isEmpty {
            return found
        }
        return pluginsFromCache(pluginsFolder.appendingPathComponent("cache", isDirectory: true))
    }

    /// `{ "version": 2, "plugins": { "<name>@<marketplace>": [ { "installPath": "…", … } ] } }`
    /// (version 1 had a single record instead of an array). Returns nil when the shape is not recognised.
    static func pluginsFromManifest(_ data: Data) -> [(name: String, root: URL)]? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = top["plugins"] as? [String: Any] else { return nil }
        var found: [(name: String, root: URL)] = []
        for id in plugins.keys.sorted() {
            let records: [[String: Any]]
            if let list = plugins[id] as? [[String: Any]] {
                records = list
            } else if let single = plugins[id] as? [String: Any] {
                records = [single]
            } else {
                continue
            }
            let name = id.split(separator: "@").first.map(String.init) ?? id
            for record in records {
                guard let path = record["installPath"] as? String, path.hasPrefix("/") else { continue }
                found.append((name: name, root: URL(fileURLWithPath: path, isDirectory: true)))
            }
        }
        return found
    }

    /// cache/<marketplace>/<plugin>/<version>: keep the most recently modified version of each plugin.
    static func pluginsFromCache(_ cache: URL) -> [(name: String, root: URL)] {
        var found: [(name: String, root: URL)] = []
        for marketplace in children(of: cache) {
            for plugin in children(of: marketplace) {
                var newest: (url: URL, date: Date)?
                for version in children(of: plugin) {
                    let date = (try? version.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if let current = newest {
                        let later = date > current.date
                            || (date == current.date && version.lastPathComponent.compare(current.url.lastPathComponent, options: .numeric) == .orderedDescending)
                        if later { newest = (version, date) }
                    } else {
                        newest = (version, date)
                    }
                }
                if let newest { found.append((name: plugin.lastPathComponent, root: newest.url)) }
            }
        }
        return found
    }

    // MARK: Files

    private enum EntryKind { case directory, file, symlink, other }

    /// Kind of the item itself; a symlink is reported as a symlink, never followed.
    private static func kind(_ url: URL) -> EntryKind {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return .other }
        switch type {
        case .typeDirectory: return .directory
        case .typeRegular: return .file
        case .typeSymbolicLink: return .symlink
        default: return .other
        }
    }

    /// Follows at most one symlink. Returns the real item and whether a link was used; nil if a second link follows.
    private static func resolveOnce(_ url: URL) -> (url: URL, kind: EntryKind, viaLink: Bool)? {
        let first = kind(url)
        guard first == .symlink else { return (url, first, false) }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let target = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        let second = kind(target)
        guard second != .symlink else { return nil }
        return (target, second, true)
    }

    /// Visible sub-folders of `root`, sorted by name. A sub-folder may be a symlink (one level).
    private static func children(of root: URL) -> [URL] {
        guard let resolved = resolveOnce(root), resolved.kind == .directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: resolved.url.path) else { return [] }
        return names.lazy
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(maxEntriesPerFolder)
            .map { resolved.url.appendingPathComponent($0, isDirectory: true) }
    }

    private static func readSkill(folder: URL, source: String) -> Skill? {
        guard let directory = resolveOnce(folder), directory.kind == .directory else { return nil }
        let file = directory.url.appendingPathComponent("SKILL.md", isDirectory: false)
        // The folder may be a link, or the file may be, but not both: one level in total.
        guard let resolved = resolveOnce(file), resolved.kind == .file, !(directory.viaLink && resolved.viaLink),
              let data = readHead(resolved.url, limit: maxBytes) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let front = parseFrontMatter(text)

        let folderName = folder.lastPathComponent
        var name = (front.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.contains(where: \.isNewline) { name = folderName }
        guard !name.isEmpty else { return nil }
        let description = clip(front.description ?? "", to: maxDescription)
        return Skill(
            id: "\(source)/\(name)",
            name: name,
            description: description,
            source: source,
            path: file.path,
            takesImages: mentionsImages(front.description ?? "") // the whole description, not the clipped one
        )
    }

    /// The first `limit` bytes of a regular file, or nil.
    private static func readHead(_ url: URL, limit: Int) -> Data? {
        guard let resolved = resolveOnce(url), resolved.kind == .file,
              let handle = try? FileHandle(forReadingFrom: resolved.url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }

    // MARK: Front matter

    static func mentionsImages(_ description: String) -> Bool {
        let lowered = description.lowercased()
        return ["image", "screenshot", "design", "mockup", "visual"].contains { lowered.contains($0) }
    }

    /// Collapses whitespace and clips to `limit` characters (with an ellipsis when cut).
    static func clip(_ text: String, to limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit, limit > 1 else { return collapsed }
        return collapsed.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `name:` and `description:` from the YAML block between the leading `---` lines.
    /// Handles quoted values, `>` / `|` block scalars and plain values continued on indented lines.
    static func parseFrontMatter(_ text: String) -> (name: String?, description: String?) {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[lines.startIndex] = first.dropFirst() }
        guard let opening = lines.first, isFence(opening) else { return (nil, nil) }
        lines = lines.dropFirst()

        var block: [Substring] = []
        for line in lines {
            if isFence(line) || line.trimmingCharacters(in: .whitespaces) == "..." { break }
            block.append(line)
            if block.count >= 400 { break }
        }

        var name: String?
        var description: String?
        var index = 0
        while index < block.count {
            let line = block[index]
            index += 1
            guard let first = line.first, first != " ", first != "\t", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let rest = line[line.index(after: colon)...]
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { continue }

            // Indented (or blank) lines that follow belong to this key.
            var continuation: [Substring] = []
            while index < block.count {
                let next = block[index]
                let blank = next.allSatisfy { $0 == " " || $0 == "\t" }
                guard blank || next.first == " " || next.first == "\t" else { break }
                continuation.append(next)
                index += 1
            }
            guard key == "name" || key == "description" else { continue }
            let value = scalar(rest.trimmingCharacters(in: .whitespaces), continuation: continuation)
            if key == "name" { if name == nil { name = value } } else if description == nil { description = value }
        }
        return (name?.isEmpty == true ? nil : name, description?.isEmpty == true ? nil : description)
    }

    private static func isFence(_ line: Substring) -> Bool {
        line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func scalar(_ head: String, continuation: [Substring]) -> String {
        let folded = continuation.map { $0.trimmingCharacters(in: .whitespaces) }

        // Block scalars: ">" folds lines into one, "|" keeps them (optionally followed by +, - or an indent digit).
        if let indicator = head.first, indicator == ">" || indicator == "|",
           head.dropFirst().allSatisfy({ $0 == "+" || $0 == "-" || $0.isNumber }) {
            if indicator == "|" { return folded.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            var out = ""
            for line in folded {
                if line.isEmpty { out += "\n" } else {
                    if !out.isEmpty, !out.hasSuffix("\n") { out += " " }
                    out += line
                }
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let joined = ([head] + folded).filter { !$0.isEmpty }.joined(separator: " ")
        if joined.hasPrefix("\"") { return doubleQuoted(joined) }
        if joined.hasPrefix("'") { return singleQuoted(joined) }

        // Plain scalar: " #" starts a comment.
        var plain = joined
        if let comment = plain.range(of: " #") { plain = String(plain[..<comment.lowerBound]) }
        return plain.trimmingCharacters(in: .whitespaces)
    }

    private static func doubleQuoted(_ text: String) -> String {
        var out = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                switch character {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(character) // \" \\ \/ and anything unknown
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func singleQuoted(_ text: String) -> String {
        var out = ""
        var pendingQuote = false
        for character in text.dropFirst() {
            if pendingQuote {
                guard character == "'" else { break } // the quote before this one closed the string
                out.append("'")                        // '' is an escaped quote
                pendingQuote = false
            } else if character == "'" {
                pendingQuote = true
            } else {
                out.append(character)
            }
        }
        return out
    }
}
