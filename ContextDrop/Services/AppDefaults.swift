import Foundation

/// Every setting the app keeps in UserDefaults: one key and one typed accessor each.
/// (Types that persist their own data, such as folder shortcuts or the global shortcut, keep a private key.)
enum AppDefaults {
    static let permissionLevelKey = "ContextDrop.permissionLevel"
    static let openAIModelKey = "ContextDrop.openAIModel"
    private static let shareDetailKey = "ContextDrop.shareDetail"
    private static let openAIDetailKey = "ContextDrop.openAIDetail"
    private static let showTerminalKey = "ContextDrop.showTerminal"

    /// The permission level new chats start with (Settings › Providers).
    static var permissionLevel: PermissionLevel {
        UserDefaults.standard.string(forKey: permissionLevelKey).flatMap(PermissionLevel.init(rawValue:)) ?? .ask
    }

    /// The OpenAI model as typed in Settings ("" = the built-in default).
    static var openAIModel: String {
        get { UserDefaults.standard.string(forKey: openAIModelKey)?.trimmingCharacters(in: .whitespaces) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: openAIModelKey) }
    }

    /// Brief or Detailed share summaries.
    static var shareDetail: ShareDetail {
        get { UserDefaults.standard.string(forKey: shareDetailKey).flatMap(ShareDetail.init(rawValue:)) ?? .detailed }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: shareDetailKey) }
    }

    /// How closely OpenAI looks at images and PDF pages in room chats.
    static var openAIDetail: OpenAIDetail {
        get { UserDefaults.standard.string(forKey: openAIDetailKey).flatMap(OpenAIDetail.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: openAIDetailKey) }
    }

    /// Deep chats show the agent's terminal pane beside the chat.
    static var showTerminal: Bool {
        get { UserDefaults.standard.object(forKey: showTerminalKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showTerminalKey) }
    }

    static let providerKey = "ContextDrop.defaultProvider"
    static let folderKey = "ContextDrop.defaultFolder"
    static let autoRouteKey = "ContextDrop.autoRoute"
    static let lastFolderKey = "ContextDrop.lastFolder"

    /// Auto mode: the OpenAI Decisions API decides quick answer vs. a coding CLI for a new chat's first question.
    static var autoRoute: Bool {
        get { UserDefaults.standard.object(forKey: autoRouteKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoRouteKey) }
    }

    static let preferredCLIKey = "ContextDrop.preferredCLI"
    static let routeCLIByTaskKey = "ContextDrop.routeCLIByTask"
    static let cliWorkPreferencesKey = "ContextDrop.cliWorkPreferences"

    /// Independent of the last manually selected chat provider; preserve the old preference on upgrade.
    static var preferredCLI: ProviderKind {
        get {
            let saved = UserDefaults.standard.string(forKey: preferredCLIKey).flatMap(ProviderKind.init(rawValue:))
            if let saved, saved.isDeep { return saved }
            let initial: ProviderKind = provider.isDeep ? provider : .claudeCode
            UserDefaults.standard.set(initial.rawValue, forKey: preferredCLIKey)
            return initial
        }
        set { if newValue.isDeep { UserDefaults.standard.set(newValue.rawValue, forKey: preferredCLIKey) } }
    }

    static var routeCLIByTask: Bool {
        get { UserDefaults.standard.bool(forKey: routeCLIByTaskKey) }
        set { UserDefaults.standard.set(newValue, forKey: routeCLIByTaskKey) }
    }

    static var cliWorkPreferences: String {
        get { UserDefaults.standard.string(forKey: cliWorkPreferencesKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: cliWorkPreferencesKey) }
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

    /// `path` without the leading `folder/`, or nil when it isn't inside that folder.
    static func relative(_ path: String, to folder: String) -> String? {
        path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : nil
    }
}
