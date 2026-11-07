import AppKit
import Carbon.HIToolbox
import Observation

/// A global keyboard shortcut, stored as a Carbon key code + Carbon modifier mask.
struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Human label for the key itself ("Space", "K", "F5"), captured when recorded.
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    private static let defaultsKey = "ContextDrop.shortcut"

    static func load() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .default }
        return shortcut
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    enum RecordError: Error { case needsModifier, unsupportedKey }

    /// Builds a shortcut from a key press. Requires ⌘, ⌥ or ⌃ unless it's a function key.
    static func from(_ event: NSEvent) -> Result<Shortcut, RecordError> {
        let code = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }

        let label: String
        if let f = functionKeys[code] {
            label = f
        } else if let named = namedKeys[code] {
            label = named
        } else if let chars = event.charactersIgnoringModifiers?.uppercased(), let first = chars.first, !first.isWhitespace {
            label = String(first)
        } else {
            return .failure(.unsupportedKey)
        }

        let hasRealModifier = mods & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasRealModifier || functionKeys[code] != nil else { return .failure(.needsModifier) }
        return .success(Shortcut(keyCode: UInt32(code), modifiers: mods, key: label))
    }
}

/// Global hotkey via Carbon RegisterEventHotKey (no Accessibility permission needed). Re-registrable.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)
    }

    /// Returns false if the system refused the combination (e.g. reserved by macOS).
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x43_44_52_50), id: 1) // "CDRP"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

/// The user-editable summon shortcut, shared by Settings, the menu bar item and the hotkey.
@MainActor
@Observable
final class ShortcutSettings {
    private(set) var shortcut = Shortcut.load()
    private(set) var isRecording = false
    var message: String?

    @ObservationIgnored private let hotKey: HotKey
    @ObservationIgnored var onChange: ((Shortcut) -> Void)?

    init(hotKey: HotKey) {
        self.hotKey = hotKey
        if !hotKey.register(shortcut) {
            message = "\(shortcut.display) couldn’t be registered. Choose another shortcut."
        }
    }

    /// Recording pauses the global hotkey so pressing the current combo is captured, not triggered.
    func beginRecording() {
        isRecording = true
        message = "Press the new shortcut. Esc cancels."
        hotKey.unregister()
    }

    func cancelRecording() {
        isRecording = false
        message = nil
        hotKey.register(shortcut)
    }

    func apply(_ new: Shortcut) {
        isRecording = false
        if hotKey.register(new) {
            shortcut = new
            new.save()
            message = "\(new.display) now opens Quick Chat. If another app (e.g. Raycast or Spotlight) uses it too, change it there."
            onChange?(new)
        } else {
            hotKey.register(shortcut)
            message = "macOS refused \(new.display). It may be reserved by the system; try another."
        }
    }

    func resetToDefault() { apply(.default) }
}
