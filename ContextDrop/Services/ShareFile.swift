import AppKit
import UniformTypeIdentifiers

/// Writes a ShareSummary as a `.contextdrop` file and hands it to AirDrop or the system share menu.
@MainActor
enum ShareFile {
    static func write(_ share: ShareSummary) throws -> URL { try write(share, index: nil) }

    private static func write(_ share: ShareSummary, index: Int?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDrop", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = share.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let name = String(safe.prefix(60)) + (index.map { " (\($0 + 1))" } ?? "")
        let url = dir.appendingPathComponent(name).appendingPathExtension("contextdrop")
        try share.fileData().write(to: url, options: .atomic)
        return url
    }

    static var airDropAvailable: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    static func airDrop(_ share: ShareSummary) throws { try airDrop([share]) }

    /// Several tabs go as one file each.
    static func airDrop(_ shares: [ShareSummary]) throws {
        let urls = try shares.enumerated().map { try write($1, index: shares.count > 1 ? $0 : nil) }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            throw CocoaError(.featureUnsupported)
        }
        service.perform(withItems: urls)
    }

    static func showPicker(_ share: ShareSummary, relativeTo view: NSView) throws {
        let url = try write(share)
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
