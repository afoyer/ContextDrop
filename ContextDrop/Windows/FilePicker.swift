import AppKit

/// The system open panel, configured in one place.
@MainActor
enum FilePicker {
    /// Folders only. Empty when the user cancelled.
    static func folders(prompt: String, message: String? = nil, multiple: Bool = false) -> [URL] {
        run(folders: true, multiple: multiple, prompt: prompt, message: message)
    }

    /// Files only. Empty when the user cancelled.
    static func files(prompt: String, message: String? = nil) -> [URL] {
        run(folders: false, multiple: true, prompt: prompt, message: message)
    }

    private static func run(folders: Bool, multiple: Bool, prompt: String, message: String?) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        if let message { panel.message = message }
        return panel.runModal() == .OK ? panel.urls : []
    }
}
