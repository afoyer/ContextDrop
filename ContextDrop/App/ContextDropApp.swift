import SwiftUI

@main
struct ContextDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Agent app: UI lives in panels owned by the AppDelegate. A Settings scene satisfies `App`.
        Settings { SettingsView(store: appDelegate.store, shortcuts: appDelegate.shortcuts) }
    }
}
