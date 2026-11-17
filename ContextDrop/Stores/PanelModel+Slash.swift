import AppKit
import SwiftUI

// Sending from an input, and the slash commands typed before a question (see `SlashRequest`).
extension PanelModel {
    // MARK: Home

    /// The coding agent the home input would ask right now (nil for quick answers, Auto routing and actions).
    /// Decides whether the permission chip shows; mirrors how `submitFromHome` picks the provider.
    var homeAgent: ProviderKind? {
        var provider: ProviderKind?
        var folder = homeFolder
        var auto = store.autoActive
        for command in SlashCommand.parseChain(draft, folders: store.folders).commands {
            switch command {
            case .provider(let selected): provider = selected; auto = false
            case .folder(let selected): folder = selected
            case .auto: provider = nil; auto = true
            case .skill: provider = .forSkills; auto = false
            case .addFolder, .action: return nil
            }
        }
        if !homeSession.skills.isEmpty { return .forSkills }
        if let provider { return provider.capabilities.requiresFolder ? provider : nil }
        if auto { return nil }
        if store.defaultProvider.capabilities.requiresFolder { return store.defaultProvider }
        return folder != nil ? store.preferredDeepProvider() : nil
    }

    func submitFromHome() {
        let request = SlashRequest(draft: draft, folders: store.folders)
        let text = request.rest
        let folder = request.folder?.url ?? homeFolder?.url
        var skills = homeSession.skills
        for name in request.skills where !skills.contains(name) { skills.append(name) }

        switch request.stop {
        case .action(let action):
            draft = text
            switch action {
            case .room: actions.openRoom()
            case .share, .folder: notices.text = "Open a chat first, then use /\(action.rawValue)."
            }
            return
        case .addFolder:
            homeFolder = folder.flatMap { store.folders.shortcut(for: $0) }
            draft = text
            actions.addFolderShortcut()
            return
        case .missingFolder(let shortcut):
            notices.text = "/\(shortcut.name) points to a folder that no longer exists (\(shortcut.display))."
            return
        case nil:
            break
        }
        var explicitProvider = request.auto ? nil : request.provider
        var autoRequested = request.auto
        if let explicitProvider, !store.status(explicitProvider).isUsable {
            notices.text = "\(explicitProvider.displayName): \(store.status(explicitProvider).detail)"
            return
        }
        if autoRequested && !store.autoAvailable {
            notices.text = "Auto is unavailable until OpenAI is ready."
            return
        }
        // Skills run in Claude Code.
        if !skills.isEmpty && explicitProvider?.supportsSkills != true {
            let provider = ProviderKind.forSkills
            guard store.status(provider).isUsable else {
                notices.text = "Skills need \(provider.displayName): \(store.status(provider).detail)"
                return
            }
            explicitProvider = provider
            autoRequested = false
        }
        if text.isEmpty && pendingAttachments.isEmpty && !request.isEmpty {
            // Choosing a coding agent starts its setup now, even before there is a question.
            if request.provider?.capabilities.requiresFolder == true, let explicitProvider, explicitProvider.capabilities.requiresFolder {
                selectProvider(explicitProvider, for: nil)
                let id = store.newConversation(provider: explicitProvider)
                store.setPermissionLevel(homeLevel, for: id)
                homeSession.resetComposer()
                homeFolder = nil
                session(id).skills = skills
                openChat(id)
                if let folder {
                    store.setFolder(folder, for: id)
                } else {
                    actions.chooseFolder(id)
                }
                return
            }
            if !skills.isEmpty {
                homeSession.skills = skills
                draft = ""
                focusToken += 1
                return
            }
            homeFolder = folder.flatMap { store.folders.shortcut(for: $0) }
            if let explicitProvider {
                selectProvider(explicitProvider, for: nil)
            } else if folder != nil && !autoRequested && !store.autoActive {
                guard let deep = (store.defaultProvider.capabilities.requiresFolder ? store.defaultProvider : nil)
                    ?? store.preferredDeepProvider() else {
                    notices.text = "Folder shortcuts need Claude Code or Codex on this Mac."
                    return
                }
                selectProvider(deep, for: nil)
            }
            if autoRequested { selectAuto() }
            draft = ""
            focusToken += 1
            return
        }

        if text.isEmpty && pendingAttachments.isEmpty {
            openSelected()
            return
        }
        // A folder picks a coding agent unless Auto or a provider was explicitly selected.
        if folder != nil && explicitProvider == nil && !autoRequested && !store.autoActive {
            guard let deep = (!store.autoRoute && store.defaultProvider.capabilities.requiresFolder ? store.defaultProvider : nil)
                ?? store.preferredDeepProvider() else {
                notices.text = "Folder shortcuts need Claude Code or Codex on this Mac."
                return
            }
            explicitProvider = deep
        }

        let auto = autoRequested || (explicitProvider == nil && store.autoActive)
        let provider = explicitProvider ?? store.defaultProvider
        let id = store.newConversation(provider: provider)
        // The chip's level; Auto routing hides the chip, so its chats keep the Settings default.
        if provider.capabilities.requiresFolder && !auto { store.setPermissionLevel(homeLevel, for: id) }
        let attachments = pendingAttachments
        homeSession.resetComposer()
        homeFolder = nil
        withAnimation(Motion.resize(reduceMotion)) { mode = .chat(id) }
        composerFocused(id, inWindow: false)

        if auto {
            if let folder { store.setFolder(folder, for: id) }
            Task { @MainActor in
                if await store.askAuto(text, attachments: attachments, in: id) { actions.chooseFolder(id) }
            }
            return
        }
        if provider.capabilities.requiresFolder {
            // An explicit agent command requires an explicit folder for this chat.
            let target = request.provider?.capabilities.requiresFolder == true ? folder : (folder ?? AppDefaults.folder ?? AppDefaults.lastFolder)
            if let target {
                store.setFolder(target, for: id)
            }
        }
        store.ask(text, attachments: attachments, skills: skills, in: id)
        // A deep chat without a folder keeps the question and answers it once one is chosen.
        if provider.capabilities.requiresFolder && store.conversation(id)?.folder == nil { actions.chooseFolder(id) }
    }

    // MARK: Slash commands

    /// The home input's "/" token (see `ChatSession.slashQuery`).
    var slashQuery: String? { homeSession.slashQuery }
    var slashMatches: [SlashItem] { slashMatches(in: homeSession) }

    func slashMatches(in session: ChatSession) -> [SlashItem] {
        session.slashMatches(autoAvailable: store.autoAvailable)
    }

    func moveSlash(_ delta: Int, in target: ChatSession? = nil) {
        let session = target ?? homeSession
        let count = slashMatches(in: session).count
        guard count > 0 else { return }
        session.slashSelection = (session.slashSelection + delta + count) % count
    }

    func selectedSlashItem(in session: ChatSession) -> SlashItem? {
        let matches = slashMatches(in: session)
        return matches.isEmpty ? nil : matches[min(session.slashSelection, matches.count - 1)]
    }

    /// Tab / ↵ on the list: complete the active token. Coding agents start setup; skills become chips.
    func completeSlash(in target: ChatSession? = nil) {
        let session = target ?? homeSession
        guard let item = selectedSlashItem(in: session) else { return }
        session.slashSelection = 0
        if item.token == "add" {
            session.draft = ""
            actions.addFolderShortcut()
            return
        }
        guard let slash = session.draft.lastIndex(of: "/") else { return }
        if item.kind == .skill {
            session.draft = String(session.draft[..<slash])
            if !session.skills.contains(item.token) { session.skills.append(item.token) }
        } else {
            session.draft = String(session.draft[..<slash]) + "/\(item.token) "
        }
        session.requestFocus()
        focusToken += 1
        if case .provider(let provider) = SlashCommand.command(for: item.token, folders: store.folders), provider.capabilities.requiresFolder {
            let request = SlashRequest(draft: session.draft, folders: store.folders)
            if request.stop == nil, request.rest.isEmpty, request.provider == provider, !request.auto,
               session.pendingAttachments.isEmpty {
                submit(session)
            }
        }
    }

    /// ⌥↵ on a skill: use it with every message in this chat.
    @discardableResult
    func pinSelectedSkill(in session: ChatSession) -> Bool {
        guard let id = session.conversationID, let item = selectedSlashItem(in: session), item.kind == .skill,
              var pinned = store.conversation(id)?.pinnedSkills else { return false }
        if !pinned.contains(item.token) { pinned.append(item.token) }
        store.setPinnedSkills(pinned, for: id)
        if let slash = session.draft.lastIndex(of: "/") { session.draft = String(session.draft[..<slash]) }
        session.slashSelection = 0
        return true
    }

    func unpinSkill(_ name: String, in id: UUID) {
        guard let pinned = store.conversation(id)?.pinnedSkills else { return }
        store.setPinnedSkills(pinned.filter { $0 != name }, for: id)
    }

    /// ↵ from either kind of input.
    func submit(_ session: ChatSession) {
        if let id = session.conversationID { submitInChat(id) } else { submitFromHome() }
    }

    /// Applies leading slash commands typed in an existing chat. Returns true if there is still something to ask.
    func applySlash(in id: UUID) -> Bool {
        let input = session(id)
        let request = SlashRequest(draft: input.draft, folders: store.folders)
        guard !request.isEmpty else { return true }
        guard let conversation = store.conversation(id) else { return false }
        for name in request.skills where !input.skills.contains(name) { input.skills.append(name) }

        switch request.stop {
        case .addFolder:
            input.draft = request.rest
            actions.addFolderShortcut()
            return false
        case .action(let action):
            input.draft = request.rest
            switch action {
            case .share: beginShare(id)
            case .room: actions.openRoom()
            case .folder: actions.chooseFolder(id)
            }
            return false
        case .missingFolder(let shortcut):
            notices.text = "/\(shortcut.name) points to a folder that no longer exists."
            return false
        case nil:
            break
        }
        var provider = conversation.provider
        if let named = request.provider {
            guard store.status(named).isUsable else {
                notices.text = "\(named.displayName): \(store.status(named).detail)"
                return false
            }
            provider = named
        }
        if request.auto { notices.text = "Auto picks the assistant for new chats. This chat keeps \(provider.displayName)." }
        // A folder needs a coding agent.
        let folder = request.folder?.url
        if folder != nil, !provider.capabilities.requiresFolder {
            guard let deep = store.preferredDeepProvider() else { notices.text = "Folder shortcuts need Claude Code or Codex on this Mac."; return false }
            provider = deep
        }
        if provider != conversation.provider { store.setProvider(provider, for: id) }
        if let folder { store.setFolder(folder, for: id) }
        input.draft = request.rest
        if !input.skills.isEmpty, store.conversation(id)?.provider.supportsSkills != true {
            notices.text = "Skills run in \(ProviderKind.forSkills.displayName). Switch this chat with /\(ProviderKind.forSkills.slashTokens[0]), or start a new one."
            input.skills = []
        }
        if store.conversation(id)?.provider.capabilities.requiresFolder == true, store.conversation(id)?.folder == nil {
            if request.rest.isEmpty && input.pendingAttachments.isEmpty {
                actions.chooseFolder(id)
                return false
            }
        }
        input.requestFocus()
        return !request.rest.isEmpty || !input.pendingAttachments.isEmpty
    }
}
