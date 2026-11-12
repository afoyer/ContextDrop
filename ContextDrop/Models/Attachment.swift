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
    /// A pasted web link. It has no file: the address itself goes to the assistant.
    var link: String? = nil
    /// True for a block of text that was pasted and tucked away as a file.
    var isPastedText: Bool? = nil

    var url: URL { link.flatMap(URL.init(string:)) ?? URL(fileURLWithPath: path) }
    var isImage: Bool { isReference != true }
    /// Images and files count toward the per-message limit; pasted links and text do not.
    var countsTowardLimit: Bool { link == nil && isPastedText != true }
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

    /// Whether `path` is inside the Attachments folder.
    static func contains(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
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

    // MARK: Pasted links and text

    /// Pasted text longer than this (in lines or characters) becomes a chip instead of filling the input.
    static let pastedTextMaxLines = 8
    static let pastedTextMaxCharacters = 800

    /// A chip for a pasted web address, or nil when the text is anything other than one http(s) link.
    static func link(_ text: String) -> Attachment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2_000, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), host.contains(".") || host == "localhost" else { return nil }
        // Shown as "host/last-part": enough to tell two links apart.
        var name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { name += (url.pathComponents.count > 2 ? "/…/" : "/") + last }
        return Attachment(id: UUID(), path: "", name: name, isReference: true, link: trimmed)
    }

    static func isLongPaste(_ text: String) -> Bool {
        if text.count > pastedTextMaxCharacters { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count > pastedTextMaxLines
    }

    /// Saves a long pasted text as a file in the attachments folder, so it rides along like any attached file.
    static func pastedText(_ text: String) -> Attachment? {
        let id = UUID()
        let dest = directory.appendingPathComponent("\(id.uuidString).txt")
        guard (try? Data(text.utf8).write(to: dest)) != nil else { return nil }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let size = lines > 1 ? "\(lines) lines" : "\(text.count.formatted()) characters"
        return Attachment(id: id, path: dest.path, name: "Pasted text · \(size)", isReference: true, isPastedText: true)
    }

    /// Text of a small referenced file, for assistants that can't read files themselves.
    static func inlineText(_ attachment: Attachment, limit: Int = 30_000) -> String? {
        attachment.isReference == true && attachment.link == nil ? inlineText(at: attachment.url, limit: limit) : nil
    }

    /// Text of a small UTF-8 file, cut to `limit` characters. Nil when it is too large or not text.
    static func inlineText(at url: URL, limit: Int = 30_000) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
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
