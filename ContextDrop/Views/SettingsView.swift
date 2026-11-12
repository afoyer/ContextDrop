import AppKit
import SwiftUI

/// The Settings window: four tabs, fixed width, flexible height. Each tab is a grouped `Form`, which scrolls
/// by itself when the window is shorter than its content, so the window never has to outgrow the screen.
struct SettingsView: View {
    let store: ChatStore
    let shortcuts: ShortcutSettings

    static let windowTitle = "ContextDrop Settings"
    static let width: CGFloat = 520
    static let minHeight: CGFloat = 320
    static let idealHeight: CGFloat = 460
    /// Tallest the window may get on `screen` (the main screen when nil).
    static func maxHeight(on screen: NSScreen? = nil) -> CGFloat {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame.height else { return idealHeight }
        return max(minHeight, visible - 40)
    }

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProviderSettingsTab(store: store)
                .tabItem { Label("Providers", systemImage: "cpu") }
            Form { FolderShortcutsSection(folders: store.folders) }
                .formStyle(.grouped)
                .tabItem { Label("Folders", systemImage: "folder") }
            ShortcutSettingsTab(shortcuts: shortcuts)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: Self.width)
        .frame(minHeight: Self.minHeight, idealHeight: min(Self.idealHeight, Self.maxHeight()), maxHeight: Self.maxHeight())
    }
}

// MARK: General

private struct GeneralSettingsTab: View {
    let store: ChatStore
    @State private var name = ""
    @AppStorage(AppDefaults.preferredCLIKey) private var preferredCLI = AppDefaults.preferredCLI.rawValue
    @AppStorage(AppDefaults.routeCLIByTaskKey) private var routeCLIByTask = false
    @AppStorage(AppDefaults.cliWorkPreferencesKey) private var cliWorkPreferences = ""

    var body: some View {
        Form {
            Section("You") {
                TextField("Name shown to people nearby", text: $name)
                    .onSubmit { store.peers.updateDisplayName(name); syncName() }
                Text("Appears as \(store.peers.localDisplayName) · \(store.peers.localDevice)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Auto mode") {
                // Bound straight to the store, so it can't go stale while the window is reused.
                Toggle("Let OpenAI pick the assistant for new chats",
                       isOn: Binding(get: { store.autoRoute }, set: { store.autoRoute = $0 }))
                    .disabled(!store.autoAvailable)
                Text("Auto favors a coding CLI when you mention a folder or project. Selecting a folder always uses a coding CLI. Use /quick, /claude or /codex to choose explicitly.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Preferred coding CLI", selection: $preferredCLI) {
                    ForEach(ProviderKind.deep) { Text($0.displayName).tag($0.rawValue) }
                }
                Text("Used for Auto and folder shortcuts. If it isn’t ready, the other available CLI is used.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Choose CLI by kind of work in Auto", isOn: $routeCLIByTask)
                if routeCLIByTask {
                    TextField("Work preferences", text: $cliWorkPreferences,
                              prompt: Text("Codex for debugging; Claude Code for UI work"), axis: .vertical)
                        .lineLimit(2...5)
                    Text("Describe which work each CLI should handle. Auto uses these preferences in the same routing call, and your preferred CLI when no rule fits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { syncName() }
        .onChange(of: store.peers.localDisplayName) { syncName() }
        // The window is reused: drop an unsubmitted edit when it closes so it reopens with the real name.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.title == SettingsView.windowTitle { syncName() }
        }
    }

    private func syncName() { name = store.peers.localDisplayName }
}

// MARK: Providers

private struct ProviderSettingsTab: View {
    let store: ChatStore
    @State private var apiKey = ""
    @State private var model = AppDefaults.openAIModel
    @State private var keyMessage: String?
    @AppStorage(AppDefaults.permissionLevelKey) private var permissionLevel = PermissionLevel.ask.rawValue
    @AppStorage(AppDefaults.delegateKey) private var delegateAgents = false
    @State private var detail = AppDefaults.openAIDetail

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API key", text: $apiKey, prompt: Text("sk-…"))
                HStack {
                    Text(keySourceText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if OpenAISettings.hasStoredKey {
                        Button("Remove") {
                            OpenAISettings.store("")
                            keyMessage = "Removed from Keychain."
                            store.refreshProviderStatus()
                        }
                    }
                    Button("Save Key") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
                TextField("Model", text: $model, prompt: Text(OpenAISettings.defaultModel))
                    .onSubmit { saveModel() }
                    .onChange(of: model) { saveModel() }
                Text("Model for quick answers and share summaries. A light model keeps it fast; empty = gpt-4.1-mini.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Images and PDFs in room chats", selection: $detail) {
                    ForEach(OpenAIDetail.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: detail) { AppDefaults.openAIDetail = detail }
                Text("How closely the model looks at images and PDF pages. High reads small text but uses more tokens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Deep chats") {
                ForEach(ProviderKind.deep) { kind in
                    LabeledContent(kind.displayName) {
                        Text(store.status(kind).detail).foregroundStyle(store.status(kind).isReady ? Color.primary : Color.secondary)
                    }
                }
                Button("Check Again") { store.refreshProviderStatus() }
                VStack(alignment: .leading, spacing: 6) {
                    Text("When an agent wants to change something")
                    Picker("When an agent wants to change something", selection: $permissionLevel) {
                        Text("Read-only: never edit or run commands").tag("readOnly")
                        Text("Ask me each time").tag("ask")
                        Text("Allow file edits, ask for the rest").tag("acceptEdits")
                        Text("Auto-approve: edits and commands, with a safety check").tag("auto")
                    }
                    .labelsHidden()
                    Text("Applies to new chats. You can change it for each chat, or press ⇧Tab while typing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Let Claude Code and Codex hand side tasks to each other", isOn: $delegateAgents)
                        .disabled(!ProviderKind.deep.allSatisfy { store.status($0).isReady })
                    Text("The agent you chat with can pass searches and reading to the other one, which spares its own usage (the other one’s usage goes up instead). The helper is read-only and shows as a lane in the chat. Claude Code can call Codex in any mode. Codex can call Claude Code only with “Edits allowed”, and then gets network access inside its sandbox.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var keySourceText: String {
        if !OpenAISettings.isLoaded { return "Reading Keychain… (approve the system prompt if one appears)" }
        if OpenAISettings.hasStoredKey { return "Saved in your Keychain. Never sent to other Macs." }
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil { return "Using OPENAI_API_KEY from the environment." }
        return "Not set. Get a key at platform.openai.com/api-keys."
    }

    private func saveKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        keyMessage = OpenAISettings.store(key) ? "Saved in Keychain." : "Couldn’t save to Keychain."
        apiKey = ""
        store.refreshProviderStatus()
    }

    private func saveModel() {
        AppDefaults.openAIModel = model
    }
}

// MARK: Shortcuts

private struct ShortcutSettingsTab: View {
    let shortcuts: ShortcutSettings

    private static let quickChat: [(key: String, label: String)] = [
        ("⌘K", "Keep answer"),
        ("⌘C", "Copy answer"),
        ("⌘⇧S", "Share"),
        ("⌘P", "Provider"),
        ("⌘0", "Auto"),
        ("⌘1–3", "Provider in Quick Chat"),
        ("⌘N", "New chat"),
        ("⌘↵", "Open in window"),
        ("⌘.", "Stop"),
        ("⌘,", "Settings"),
        ("esc", "Close"),
    ]

    private static let window: [(key: String, label: String)] = [
        ("⌘T", "New tab"),
        ("⌘1–9", "Jump to tab"),
        ("⌃Tab", "Next tab that needs you"),
        ("⌘W", "Close tab"),
        ("⌘⇧T", "Reopen closed tab"),
        ("⌘⌥A", "Show or hide Activity"),
        ("⌘⇧R", "Send answer to room"),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("Summon Quick Chat") { ShortcutRecorder(settings: shortcuts) }
                if let message = shortcuts.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Quick Chat") { rows(Self.quickChat) }
            Section {
                rows(Self.window)
            } header: {
                Text("Window")
            } footer: {
                Text("Motion follows System Settings › Accessibility › Display › Reduce motion.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private func rows(_ items: [(key: String, label: String)]) -> some View {
        ForEach(items, id: \.key) { item in
            LabeledContent(item.label) { Kbd(item.key) }
        }
    }
}

/// Settings › Folder shortcuts: `/name` → folder, used from the Quick Chat input.
struct FolderShortcutsSection: View {
    let folders: FolderShortcutStore
    @State private var message: String?

    var body: some View {
        Section("Folder shortcuts") {
            ForEach(folders.shortcuts) { shortcut in
                FolderShortcutRow(shortcut: shortcut, folders: folders, message: $message)
            }
            HStack {
                Text(folders.shortcuts.isEmpty ? "Type /name in Quick Chat to ask a coding agent about that folder." : "Type /name in Quick Chat.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Folder…") { addFolder() }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func addFolder() {
        let chosen = FilePicker.folders(prompt: "Add", multiple: true)
        guard !chosen.isEmpty else { return }
        let added = chosen.map { folders.add($0) }
        message = "Added " + added.map { "/\($0.name)" }.joined(separator: ", ") + "."
    }
}

private struct FolderShortcutRow: View {
    let shortcut: FolderShortcut
    let folders: FolderShortcutStore
    @Binding var message: String?
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("/").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            TextField("name", text: $name)
                .font(.system(.body, design: .monospaced))
                .frame(width: 110)
                .onSubmit { rename() }
            Text(shortcut.display)
                .foregroundStyle(shortcut.exists ? .secondary : Color.red)
                .lineLimit(1).truncationMode(.head)
                .help(shortcut.exists ? shortcut.path : "This folder no longer exists")
            Spacer()
            Button { folders.remove(shortcut.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove /\(shortcut.name)")
        }
        .onAppear { name = shortcut.name }
        .onChange(of: shortcut.name) { name = shortcut.name }
    }

    private func rename() {
        if folders.rename(shortcut.id, to: name) {
            message = nil
        } else {
            message = "“\(name)” can’t be used: it’s empty, taken, or a built-in command (/claude, /codex, /quick, /auto, /add)."
            name = shortcut.name
        }
    }
}
