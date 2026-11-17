import Foundation
import ServiceManagement

/// Open ContextDrop at login (Settings › General and setup). The person can also turn it off in
/// System Settings › General › Login Items, so the state is always read back from the system.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns it on or off. Returns why it failed, or nil.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard enabled != isEnabled else { return nil }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
