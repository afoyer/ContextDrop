import SwiftUI

struct SettingsView: View {
    let store: ChatStore
    let shortcuts: ShortcutSettings
    @State private var apiKey = ""
    @State private var model = UserDefaults.standard.string(forKey: OpenRouterSettings.modelDefaultsKey) ?? ""
    @State private var name = ""
    @State private var keyMessage: String?

    var body: some View {
        Form {
            Section("OpenRouter") {
                SecureField("API key", text: $apiKey, prompt: Text("sk-or-…"))
                HStack {
                    Text(keySourceText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if OpenRouterSettings.hasStoredKey {
                        Button("Remove") {
                            OpenRouterSettings.store("")
                            keyMessage = "Removed from Keychain."
                            store.refreshProviderStatus()
                        }
                    }
                    Button("Save Key") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
                TextField("Model", text: $model, prompt: Text(OpenRouterSettings.defaultModel))
                    .onSubmit { saveModel() }
                    .onChange(of: model) { saveModel() }
                Text("Any OpenRouter model id, e.g. anthropic/claude-sonnet-4.5. Empty = openrouter/auto. Share summaries always use OpenRouter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("You") {
                TextField("Name shown to people nearby", text: $name)
                    .onSubmit { store.peers.updateDisplayName(name); name = store.peers.localDisplayName }
                Text("Appears as \(store.peers.localDisplayName) · \(store.peers.localDevice)").font(.caption).foregroundStyle(.secondary)
            }
            Section("Deep chats") {
                ForEach([ProviderKind.claudeCode, .codex]) { kind in
                    LabeledContent(kind.displayName) {
                        Text(store.status(kind).detail).foregroundStyle(store.status(kind).isReady ? Color.primary : Color.secondary)
                    }
                }
                Button("Check Again") { store.refreshProviderStatus() }
            }
            Section("Keyboard") {
                LabeledContent("Summon Quick Chat") { ShortcutRecorder(settings: shortcuts) }
                if let message = shortcuts.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Keep answer · Share · Provider", value: "⌘K · ⌘⇧S · ⌘P")
                Text("Motion follows System Settings › Accessibility › Display › Reduce motion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { name = store.peers.localDisplayName }
    }

    private var keySourceText: String {
        if !OpenRouterSettings.isLoaded { return "Reading Keychain… (approve the system prompt if one appears)" }
        if OpenRouterSettings.hasStoredKey { return "Saved in your Keychain. Never sent to other Macs." }
        if ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil { return "Using OPENROUTER_API_KEY from the environment." }
        return "Not set. Get a key at openrouter.ai/keys."
    }

    private func saveKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        keyMessage = OpenRouterSettings.store(key) ? "Saved in Keychain." : "Couldn’t save to Keychain."
        apiKey = ""
        store.refreshProviderStatus()
    }

    private func saveModel() {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: OpenRouterSettings.modelDefaultsKey)
    }
}
