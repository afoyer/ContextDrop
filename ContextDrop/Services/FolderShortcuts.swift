import Foundation
import Observation

/// A saved project folder, reachable as `/name` from the Quick Chat input.
struct FolderShortcut: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var path: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var display: String { FolderDrop.display(url) }
    var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Folder shortcuts, persisted in UserDefaults.
@MainActor
@Observable
final class FolderShortcutStore {
    private static let key = "ContextDrop.folderShortcuts"
    /// Names that are slash commands themselves.
    static let reserved = Set(ProviderKind.allCases.flatMap(\.slashTokens) + ["auto", "add", "share", "room", "folder"])

    private(set) var shortcuts: [FolderShortcut] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([FolderShortcut].self, from: data) {
            shortcuts = saved
        }
    }

    func shortcut(named name: String) -> FolderShortcut? {
        shortcuts.first { $0.name == name.lowercased() }
    }

    func shortcut(for url: URL) -> FolderShortcut? {
        let path = url.standardizedFileURL.path
        return shortcuts.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }
    }

    /// Adds (or returns the existing) shortcut for a folder. The name defaults to the folder's name.
    @discardableResult
    func add(_ url: URL, name: String? = nil) -> FolderShortcut {
        if let existing = shortcut(for: url) { return existing }
        let shortcut = FolderShortcut(id: UUID(), name: uniqueName(Self.slug(name ?? url.lastPathComponent)), path: url.standardizedFileURL.path)
        shortcuts.append(shortcut)
        shortcuts.sort { $0.name < $1.name }
        save()
        return shortcut
    }

    /// Returns false if the name is empty, reserved or taken.
    @discardableResult
    func rename(_ id: UUID, to raw: String) -> Bool {
        let name = Self.slug(raw)
        guard !name.isEmpty, !Self.reserved.contains(name),
              !shortcuts.contains(where: { $0.name == name && $0.id != id }),
              let index = shortcuts.firstIndex(where: { $0.id == id }) else { return false }
        shortcuts[index].name = name
        shortcuts.sort { $0.name < $1.name }
        save()
        return true
    }

    func remove(_ id: UUID) {
        shortcuts.removeAll { $0.id == id }
        save()
    }

    static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        let allowed = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
        var slug = String(String.UnicodeScalarView(allowed))
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        return String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(24))
    }

    private func uniqueName(_ base: String) -> String {
        let root = base.isEmpty || Self.reserved.contains(base) ? (base.isEmpty ? "folder" : base + "-dir") : base
        var name = root
        var n = 2
        while shortcuts.contains(where: { $0.name == name }) { name = "\(root)-\(n)"; n += 1 }
        return name
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// ContextDrop actions reachable from the `/` list.
enum SlashAction: String, Sendable {
    case share, room, folder
}

/// A leading `/token` in the input.
enum SlashCommand: Equatable {
    case provider(ProviderKind)
    case auto
    case addFolder
    case folder(FolderShortcut)
    /// A Claude Code skill, by name.
    case skill(String)
    case action(SlashAction)

    /// Parses `/token rest…`. Unknown tokens are not commands (the text is sent as typed).
    @MainActor
    static func parse(_ draft: String, folders: FolderShortcutStore) -> (command: SlashCommand, rest: String)? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let token = text.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        let rest = text.dropFirst(1 + token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = command(for: token, folders: folders) else { return nil }
        return (command, rest)
    }

    /// Consumes consecutive leading commands, leaving the question untouched.
    @MainActor
    static func parseChain(_ draft: String, folders: FolderShortcutStore) -> (commands: [SlashCommand], rest: String) {
        var rest = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        var commands: [SlashCommand] = []
        while let next = parse(rest, folders: folders) {
            commands.append(next.command)
            rest = next.rest
            if next.command == .addFolder { break }
        }
        return (commands, rest)
    }

    @MainActor
    static func command(for token: String, folders: FolderShortcutStore) -> SlashCommand? {
        if let provider = ProviderKind.allCases.first(where: { $0.slashTokens.contains(token) }) { return .provider(provider) }
        return switch token {
        case "auto": .auto
        case "add": .addFolder
        case "share": .action(.share)
        case "room": .action(.room)
        case "folder": .action(.folder)
        default: folders.shortcut(named: token).map { .folder($0) } ?? SkillCatalog.shared.skill(named: token).map { .skill($0.name) }
        }
    }
}

/// One row of the `/` completion list.
struct SlashItem: Identifiable, Equatable {
    enum Kind: Equatable { case folder, skill, command }

    let token: String
    let title: String
    let subtitle: String
    let icon: String
    var kind: Kind = .command
    /// Longer description shown beside the list (skills).
    var detail: String = ""
    var takesImages = false
    var id: String { token }

    /// Rows for `query`: folder shortcuts, then skills, then ContextDrop actions.
    @MainActor
    static func matches(_ query: String, folders: FolderShortcutStore, autoAvailable: Bool,
                        inChat: Bool = false, preferImages: Bool = false) -> [SlashItem] {
        let q = query.lowercased()
        var items = folders.shortcuts.filter { $0.name.hasPrefix(q) }.map {
            SlashItem(token: $0.name, title: "/\($0.name)", subtitle: $0.exists ? $0.display : "\($0.display) (missing)",
                      icon: "folder", kind: .folder)
        }
        let skills = SkillCatalog.shared.matches(q, preferImages: preferImages).prefix(q.isEmpty ? 6 : 12)
        items += skills.map {
            SlashItem(token: $0.name, title: "/\($0.name)", subtitle: $0.source, icon: $0.takesImages ? "photo" : "lightbulb",
                      kind: .skill, detail: $0.description, takesImages: $0.takesImages)
        }
        var commands: [SlashItem] = []
        if inChat {
            commands.append(SlashItem(token: "share", title: "/share", subtitle: "Share this chat with someone nearby", icon: "square.and.arrow.up"))
            commands.append(SlashItem(token: "folder", title: "/folder", subtitle: "Change the working folder", icon: "folder.badge.gearshape"))
        }
        commands.append(SlashItem(token: "room", title: "/room", subtitle: "Open a room for people nearby", icon: "square.grid.2x2"))
        commands += (ProviderKind.deep + ProviderKind.allCases.filter { !$0.isDeep }).compactMap { provider in
            provider.slashTokens.first.map {
                SlashItem(token: $0, title: "/\($0)", subtitle: provider.slashSubtitle, icon: provider.isDeep ? "terminal" : "bubble.left")
            }
        }
        if autoAvailable { commands.append(SlashItem(token: "auto", title: "/auto", subtitle: "Pick a quick answer or your preferred coding CLI", icon: "sparkles")) }
        commands.append(SlashItem(token: "add", title: "/add", subtitle: "Add a folder shortcut…", icon: "folder.badge.plus"))
        // Skills are matched on description too; commands only by name.
        return items + commands.filter { $0.token.hasPrefix(q) && !items.map(\.token).contains($0.token) }
    }
}
