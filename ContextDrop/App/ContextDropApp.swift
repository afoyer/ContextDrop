import SwiftUI

@main
struct ContextDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Agent app: all UI, including the Settings window, is owned by the AppDelegate.
        // An empty Settings scene only satisfies `App`'s need for one scene.
        Settings { EmptyView() }
    }
}
