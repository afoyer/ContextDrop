import AppKit
import SwiftUI

/// Click, then press a key combination. Esc cancels.
struct ShortcutRecorder: View {
    @Bindable var settings: ShortcutSettings
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                settings.isRecording ? stop(cancel: true) : start()
            } label: {
                Text(settings.isRecording ? "Type shortcut…" : settings.shortcut.display)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
                    .foregroundStyle(settings.isRecording ? Color.accentColor : Color.primary)
            }
            .help("Click, then press the new shortcut")
            if settings.shortcut != .default && !settings.isRecording {
                Button("Reset to ⌥Space") { settings.resetToDefault() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .onDisappear { stop(cancel: true) }
    }

    private func start() {
        settings.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if Int(event.keyCode) == 53, flags.isEmpty { // esc
                    stop(cancel: true)
                    return
                }
                switch Shortcut.from(event) {
                case .success(let shortcut):
                    removeMonitor()
                    settings.apply(shortcut)
                case .failure(.needsModifier):
                    settings.message = "Include ⌘, ⌥ or ⌃ (or use a function key)."
                case .failure(.unsupportedKey):
                    settings.message = "That key can’t be used. Try another."
                }
            }
            return nil // swallow while recording
        }
    }

    private func stop(cancel: Bool) {
        removeMonitor()
        if cancel && settings.isRecording { settings.cancelRecording() }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
