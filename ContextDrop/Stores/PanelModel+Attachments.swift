import AppKit
import SwiftUI

// Attachments on a composer: paste, pick, and files dropped on the panel, a tab or the menu bar icon.
extension PanelModel {
    func attach(_ items: [Attachment], to target: ChatSession? = nil) {
        let session = target ?? activeSession
        // The limit is for images and files. Pasted links and text are only text, so they don't count.
        let free = items.filter { !$0.countsTowardLimit }
        let limited = items.filter(\.countsTowardLimit)
        let room = Attachments.maxPerMessage - session.pendingAttachments.filter(\.countsTowardLimit).count
        if !limited.isEmpty, room <= 0 { notices.text = "Up to \(Attachments.maxPerMessage) images or files per message." }
        guard !free.isEmpty || room > 0 else { return }
        withAnimation(Motion.keep(reduceMotion)) { session.pendingAttachments += free + limited.prefix(max(room, 0)) }
        session.requestFocus()
        focusToken += 1
    }

    func removeAttachment(_ id: UUID, from target: ChatSession? = nil) {
        let session = target ?? activeSession
        withAnimation(Motion.keep(reduceMotion)) { session.pendingAttachments.removeAll { $0.id == id } }
    }

    /// ⌘V with something that should not fill the input: an image (or copied image files), a web link,
    /// or a long block of text. Each becomes a chip above the input. Returns false to let a normal text paste happen.
    func pasteAsAttachment(into target: ChatSession? = nil) -> Bool {
        pasteImageIfAny(into: target) || pasteLinkOrLongText(into: target)
    }

    /// ⌘V seen by a window's key monitor, before the text field pastes. Only acts while a text field is being typed in.
    func pasteKey(in window: NSWindow?, session: ChatSession) -> Bool {
        guard window?.firstResponder is NSTextView else { return false }
        return pasteAsAttachment(into: session)
    }

    private func pasteLinkOrLongText(into target: ChatSession?) -> Bool {
        let session = target ?? activeSession
        guard NSPasteboard.general.availableType(from: [.fileURL]) == nil,
              let text = NSPasteboard.general.string(forType: .string) else { return false }
        guard let item = Attachments.link(text) ?? (Attachments.isLongPaste(text) ? Attachments.pastedText(text) : nil) else { return false }
        // The same link twice is one chip.
        if let link = item.link, session.pendingAttachments.contains(where: { $0.link == link }) { return true }
        attach([item], to: target)
        return true
    }

    private func pasteImageIfAny(into target: ChatSession? = nil) -> Bool {
        guard Attachments.pasteboardHasImage() else { return false }
        // Text wins when the clipboard has both (e.g. copying from a web page).
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty,
           NSPasteboard.general.availableType(from: [.fileURL]) == nil { return false }
        let items = Attachments.fromPasteboard()
        guard !items.isEmpty else { return false }
        attach(items, to: target)
        return true
    }

    /// Images are copied in; other files are attached by reference (a coding agent reads them itself).
    func attachDropped(_ urls: [URL], to target: ChatSession? = nil) {
        let items = urls.compactMap { url in Attachments.isImage(url) ? Attachments.importFile(url) : Attachments.reference(url) }
        if items.isEmpty { notices.text = "Couldn’t attach that." } else { attach(items, to: target) }
    }

    /// What a drop does, for the three drop targets.
    enum DropAction { case attach, runSkill, newTab }

    /// Files dropped on the panel, a tab or the menu bar icon.
    func handleDrop(_ urls: [URL], action: DropAction, in conversationID: UUID?) {
        if let file = urls.first(where: { $0.pathExtension.lowercased() == "contextdrop" }) {
            if let share = store.ingestFile(file) { continueChat(share) }
            return
        }
        var isDir: ObjCBool = false
        let folders = urls.filter { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
            && !((try? $0.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false) }
        let files = urls.filter { !folders.contains($0) }
        if let folder = folders.first {
            if action == .newTab || conversationID == nil {
                // "New tab here" / home: a coding agent in that folder.
                let shortcut = store.folders.add(folder)
                if action == .newTab, let deep = store.preferredDeepProvider() {
                    let id = store.newConversation(provider: deep)
                    store.setFolder(folder, for: id)
                    openInWorkspace(id)
                } else {
                    homeFolder = shortcut
                    notices.text = "Using /\(shortcut.name) → \(shortcut.display)."
                }
            } else if let id = conversationID {
                // "Use as working folder".
                if store.conversation(id)?.provider.isDeep == false, let deep = store.preferredDeepProvider() {
                    store.setProvider(deep, for: id)
                }
                store.setFolder(folder, for: id)
                notices.text = "Working folder: \(FolderDrop.display(folder))."
            }
        }
        guard !files.isEmpty else { return }
        switch action {
        case .newTab:
            let provider = files.contains(where: { !Attachments.isImage($0) }) ? (store.preferredDeepProvider() ?? store.defaultProvider) : store.defaultProvider
            let id = store.newConversation(provider: provider)
            if provider.isDeep, let folder = AppDefaults.lastFolder ?? AppDefaults.folder { store.setFolder(folder, for: id) }
            attachDropped(files, to: session(id))
            openInWorkspace(id)
        case .attach, .runSkill:
            let target = session(conversationID)
            attachDropped(files, to: target)
            if action == .runSkill {
                target.draft = target.draft.isEmpty ? "/" : target.draft + " /"
                SkillCatalog.shared.refresh(projectFolder: conversationID.flatMap { store.conversation($0)?.folder })
            }
            target.requestFocus()
        }
    }
}
