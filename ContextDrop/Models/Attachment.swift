import AppKit
import Foundation
import UniformTypeIdentifiers

/// Something attached to a question. Images (screenshots, pasted or dropped) are copied into the app's Attachments
/// folder; other files are references to where they already are, which a coding agent reads itself.
struct Attachment: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var path: String
    var name: String
    /// True for a file reference (not an image copied into the Attachments folder).
    var isReference: Bool? = nil

    var url: URL { URL(fileURLWithPath: path) }
    var isImage: Bool { isReference != true }
}

/// Saving, importing and capturing images for chats. Everything is copied into one folder so the CLIs
/// can be given access to exactly that folder (`claude --add-dir`).
enum Attachments {
    static let maxPerMessage = 6

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ContextDrop/Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let imageTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// A reference to a non-image file where it already is (no copy).
    static func reference(_ url: URL) -> Attachment? {
        var isDir: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return Attachment(id: UUID(), path: url.standardizedFileURL.path, name: url.lastPathComponent, isReference: true)
    }

    /// Text of a small referenced file, for assistants that can't read files themselves.
    static func inlineText(_ attachment: Attachment, limit: Int = 30_000) -> String? {
        guard attachment.isReference == true, let data = try? Data(contentsOf: attachment.url, options: .mappedIfSafe),
              data.count <= 400_000, let text = String(data: data, encoding: .utf8) else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "\n… (cut)" : text
    }

    /// Copies an image file into the attachments folder (converted to PNG if it isn't PNG/JPEG).
    static func importFile(_ url: URL) -> Attachment? {
        guard isImage(url) else { return nil }
        let id = UUID()
        let ext = url.pathExtension.lowercased()
        if ext == "png" || ext == "jpg" || ext == "jpeg" {
            let dest = directory.appendingPathComponent("\(id.uuidString).\(ext)")
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return nil }
            return Attachment(id: id, path: dest.path, name: url.lastPathComponent)
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        return save(image, name: url.deletingPathExtension().lastPathComponent + ".png")
    }

    static func save(_ image: NSImage, name: String) -> Attachment? {
        guard let data = pngData(image) else { return nil }
        let id = UUID()
        let dest = directory.appendingPathComponent("\(id.uuidString).png")
        guard (try? data.write(to: dest)) != nil else { return nil }
        return Attachment(id: id, path: dest.path, name: name)
    }

    static func save(jpeg data: Data, name: String) -> Attachment? {
        let id = UUID()
        let dest = directory.appendingPathComponent("\(id.uuidString).jpg")
        guard (try? data.write(to: dest)) != nil else { return nil }
        return Attachment(id: id, path: dest.path, name: name)
    }

    /// An image on the clipboard: image data, or copied image files from Finder.
    @MainActor
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> [Attachment] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter(isImage)
            if !images.isEmpty { return images.prefix(maxPerMessage).compactMap(importFile) }
        }
        if pasteboard.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier]),
           let image = NSImage(pasteboard: pasteboard) {
            return save(image, name: "Pasted image.png").map { [$0] } ?? []
        }
        return []
    }

    @MainActor
    static func pasteboardHasImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: isImage) { return true }
        return pasteboard.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier])
    }

    /// Interactive region/window capture with the system tool. Returns nil if the user pressed esc.
    static func captureScreen() async -> Attachment? {
        let id = UUID()
        let dest = directory.appendingPathComponent("\(id.uuidString).png")
        let result = await CLIRunner.runCapture("/usr/sbin/screencapture", ["-i", "-x", dest.path], timeout: 120)
        guard result.status == 0, FileManager.default.fileExists(atPath: dest.path) else { return nil }
        let time = Date().formatted(date: .omitted, time: .shortened)
        return Attachment(id: id, path: dest.path, name: "Screenshot \(time).png")
    }

    // MARK: Encoding for models / shares

    /// JPEG, longest side ≤ maxPixels. Used for OpenAI images and for screenshots inside a share.
    static func jpegData(_ url: URL, maxPixels: CGFloat = 1568, quality: CGFloat = 0.75) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func dataURL(_ url: URL) -> String? {
        jpegData(url).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
