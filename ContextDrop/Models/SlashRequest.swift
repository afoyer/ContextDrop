import Foundation

/// What a chain of leading slash commands asks for, before any of it is carried out.
/// The home input and an open chat both read a draft this way, then apply their own rules.
struct SlashRequest: Equatable {
    /// A command that ends the chain: nothing after it counts, and nothing is sent.
    enum Stop: Equatable {
        case action(SlashAction)
        case addFolder
        /// A folder shortcut whose folder is gone.
        case missingFolder(FolderShortcut)
    }

    /// True when the draft had no commands at all.
    var isEmpty = true
    /// Skills named, in order, each once.
    var skills: [String] = []
    /// The last provider named.
    var provider: ProviderKind?
    /// `/auto` was typed, and no provider was named after it.
    var auto = false
    /// The last folder shortcut named.
    var folder: FolderShortcut?
    var stop: Stop?
    /// The question left once the commands are taken off.
    var rest: String

    init(commands: [SlashCommand], rest: String) {
        self.rest = rest
        isEmpty = commands.isEmpty
        for command in commands {
            switch command {
            case .skill(let name):
                if !skills.contains(name) { skills.append(name) }
            case .provider(let named):
                provider = named
                auto = false
            case .auto:
                auto = true
            case .folder(let shortcut):
                if shortcut.exists { folder = shortcut } else { stop = .missingFolder(shortcut) }
            case .action(let action):
                stop = .action(action)
            case .addFolder:
                stop = .addFolder
            }
            if stop != nil { return }
        }
    }

    @MainActor
    init(draft: String, folders: FolderShortcutStore) {
        let parsed = SlashCommand.parseChain(draft, folders: folders)
        self.init(commands: parsed.commands, rest: parsed.rest)
    }
}
