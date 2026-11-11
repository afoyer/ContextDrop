import Foundation

/// UserDefaults keys for the "new chat" defaults chosen in Settings.
enum AppDefaults {
    static let providerKey = "ContextDrop.defaultProvider"
    static let folderKey = "ContextDrop.defaultFolder"
    static let claudeModelKey = "ContextDrop.claudeModel"
    static let autoRouteKey = "ContextDrop.autoRoute"
    static let lastFolderKey = "ContextDrop.lastFolder"

    /// Auto mode: the OpenAI Decisions API decides quick answer vs. Claude Code for a new chat's first question.
    static var autoRoute: Bool {
        get { UserDefaults.standard.object(forKey: autoRouteKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoRouteKey) }
    }

    static let delegateKey = "ContextDrop.delegateAgents"

    /// Coding agents may hand self-contained side tasks to the other CLI (Claude Code ⇄ Codex).
    static var delegateAgents: Bool {
        get { UserDefaults.standard.bool(forKey: delegateKey) }
        set { UserDefaults.standard.set(newValue, forKey: delegateKey) }
    }

    /// The folder most recently used by a deep chat.
    static var lastFolder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: lastFolderKey), !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: lastFolderKey) }
    }

    /// `claude --model` aliases. Empty = whatever the CLI is configured to use.
    static let claudeModels: [(id: String, label: String)] = [
        ("", "CLI default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"),
    ]

    static var provider: ProviderKind {
        get { UserDefaults.standard.string(forKey: providerKey).flatMap(ProviderKind.init(rawValue:)) ?? .openAI }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    static var folder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: folderKey) }
    }

    static var claudeModel: String {
        get { UserDefaults.standard.string(forKey: claudeModelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: claudeModelKey) }
    }
}

enum FolderDrop {
    /// The folder a dropped item refers to: the folder itself, or the folder containing a dropped file.
    static func directory(from url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return url.standardizedFileURL }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir) && isDir.boolValue ? parent : nil
    }

    static func display(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}
