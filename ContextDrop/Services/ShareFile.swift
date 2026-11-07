import AppKit
import UniformTypeIdentifiers

/// Writes a ShareSummary as a `.contextdrop` file and hands it to AirDrop or the system share menu.
@MainActor
enum ShareFile {
    static func write(_ share: ShareSummary) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDrop", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = share.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let url = dir.appendingPathComponent(String(safe.prefix(60))).appendingPathExtension("contextdrop")
        try share.fileData().write(to: url, options: .atomic)
        return url
    }

    static var airDropAvailable: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    static func airDrop(_ share: ShareSummary) throws {
        let url = try write(share)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
            throw CocoaError(.featureUnsupported)
        }
        service.perform(withItems: [url])
    }

    static func showPicker(_ share: ShareSummary, relativeTo view: NSView) throws {
        let url = try write(share)
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
