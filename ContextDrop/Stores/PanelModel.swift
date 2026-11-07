import AppKit
import Observation
import SwiftUI

/// Rows of the collapsed Quick Chat list (board 1): drops first, then recent chats, then actions.
enum HomeItem: Identifiable, Equatable {
    case offer(IncomingOffer)
    case received(ReceivedShare)
    case chat(Conversation)
    case clipboard

    var id: String {
        switch self {
        case .offer(let o): "offer-\(o.id)"
        case .received(let r): "received-\(r.id)"
        case .chat(let c): "chat-\(c.id)"
        case .clipboard: "clipboard"
        }
    }
}

/// What the floating panel is showing, and the keyboard logic behind it.
@MainActor
@Observable
final class PanelModel {
    enum Mode: Equatable {
        case home
        case chat(UUID)
        case share(UUID)
        case send(conversationID: UUID, share: ShareSummary)
        case offer(UUID)        // preview of a pending offer from someone nearby
        case received(UUID)     // preview of a share already on this Mac (saved for later / file)
    }

    let store: ChatStore
    var mode: Mode = .home
    var draft = ""
    var selection = 0
    var focusedMessageID: UUID?
    var showProviderMenu = false
    var prep: SharePrep?
    /// Bumped to ask the active input to take focus.
    var focusToken = 0
    /// Briefly shown after a successful send ("Shared with Camille").
    var justSharedWith: String?
    var copiedMessageID: UUID?

    // Wired by the AppDelegate.
    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored var onExpand: ((UUID) -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored var onChooseFolder: ((UUID) -> Void)?

    init(store: ChatStore) {
        self.store = store
    }

    var peers: PeerService { store.peers }
    var reduceMotion: Bool { store.reduceMotion }

    var isWide: Bool { if case .share = mode { true } else { false } }
    var width: CGFloat { isWide ? 1040 : 640 }

    /// Panel auto-hides when it loses focus, except during flows that open system UI (AirDrop, folder picker).
    var keepsOpenOnResign: Bool {
        switch mode {
        case .share, .send: true
        default: false
        }
    }

    var activeConversationID: UUID? {
        switch mode {
        case .chat(let id), .share(let id): id
        case .send(let id, _): id
        default: nil
        }
    }

    // MARK: Home list

    var homeItems: [HomeItem] {
        var items: [HomeItem] = []
        let offers = peers.offers.filter { $0.phase == .pending }.sorted { !$0.seen && $1.seen }
        items += offers.map { .offer($0) }
        let received = store.received.sorted { !$0.read && $1.read }
        items += received.prefix(4).map { .received($0) }
        items += store.recentConversations.prefix(4).map { .chat($0) }
        if let clip = NSPasteboard.general.string(forType: .string), !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(.clipboard)
        }
        return items
    }

    // MARK: Lifecycle

    func summoned() {
        if case .home = mode { selection = 0 }
        focusToken += 1
    }

    /// esc: step back one level, or hide.
    func escape() {
        if showProviderMenu { showProviderMenu = false; return }
        switch mode {
        case .home, .chat:
            onHide?()
            mode = .home
            draft = ""
            selection = 0
        case .share(let id):
            prep = nil
            withAnimation(Motion.shareMode(reduceMotion)) { mode = .chat(id) }
        case .send(let id, _):
            if let outgoing = peers.outgoing, outgoing.phase == .waiting || outgoing.phase == .sending {
                onHide?() // sending continues in the background
            } else {
                peers.clearOutgoing()
                withAnimation(Motion.shareMode(reduceMotion)) { mode = .share(id) }
            }
        case .offer, .received:
            withAnimation(Motion.summon(reduceMotion)) { mode = .home }
        }
        focusToken += 1
    }

    // MARK: Home actions

    /// ⌘N: back to the empty home input, ready to type a new question.
    func newChat() {
        showProviderMenu = false
        if case .share = mode { prep = nil }
        if case .send = mode, peers.outgoing.map({ $0.phase != .waiting && $0.phase != .sending }) ?? false { peers.clearOutgoing() }
        withAnimation(Motion.summon(reduceMotion)) { mode = .home }
        draft = ""
        selection = 0
        focusToken += 1
    }

    func submitFromHome() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            openSelected()
            return
        }
        let id = store.newConversation()
        draft = ""
        withAnimation(Motion.resize(reduceMotion)) { mode = .chat(id) }
        store.ask(text, in: id)
    }

    func moveSelection(_ delta: Int) {
        let count = homeItems.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func openSelected() {
        let items = homeItems
        guard items.indices.contains(selection) else { return }
        open(items[selection])
    }

    func open(_ item: HomeItem) {
        switch item {
        case .offer(let offer):
            peers.markSeen(offer)
            withAnimation(Motion.summon(reduceMotion)) { mode = .offer(offer.id) }
        case .received(let received):
            store.markRead(received.id)
            withAnimation(Motion.summon(reduceMotion)) { mode = .received(received.id) }
        case .chat(let conversation):
            openChat(conversation.id)
        case .clipboard:
            if let clip = NSPasteboard.general.string(forType: .string) {
                draft = "About this:\n\(clip.prefix(4_000))\n\n"
                focusToken += 1
            }
        }
    }

    func openChat(_ id: UUID) {
        withAnimation(Motion.continueOpen(reduceMotion)) { mode = .chat(id) }
        focusedMessageID = nil
        focusToken += 1
    }

    // MARK: Chat actions

    func submitInChat(_ id: UUID) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let conversation = store.conversation(id) else { return }
        if conversation.provider.isDeep && conversation.folder == nil {
            onChooseFolder?(id)
            return
        }
        draft = ""
        store.ask(text, in: id)
        focusedMessageID = nil
    }

    /// ↑↓ between answers in a chat.
    func moveAnswerFocus(_ delta: Int, in id: UUID) {
        guard let conversation = store.conversation(id) else { return }
        let answers = conversation.messages.filter { $0.role == .assistant && $0.error == nil }
        guard !answers.isEmpty else { return }
        if let current = focusedMessageID, let index = answers.firstIndex(where: { $0.id == current }) {
            focusedMessageID = answers[max(0, min(answers.count - 1, index + delta))].id
        } else {
            focusedMessageID = (delta < 0 ? answers.last : answers.first)?.id
        }
    }

    /// ⌘K keeps the focused answer, or the latest one.
    func keepFocused(in id: UUID) {
        guard let conversation = store.conversation(id) else { return }
        let target = focusedMessageID ?? conversation.messages.last(where: { $0.role == .assistant && $0.error == nil })?.id
        guard let target else { return }
        withAnimation(Motion.keep(reduceMotion)) { store.toggleKeep(target, in: id) }
        focusedMessageID = target
    }

    func copy(_ message: Message) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copiedMessageID = message.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedMessageID == message.id { copiedMessageID = nil }
        }
    }

    func copyFocused(in id: UUID) {
        guard let conversation = store.conversation(id),
              let message = conversation.messages.first(where: { $0.id == focusedMessageID })
                ?? conversation.messages.last(where: { $0.role == .assistant && $0.error == nil }) else { return }
        copy(message)
    }

    func selectProvider(_ provider: ProviderKind, for id: UUID?) {
        showProviderMenu = false
        guard store.status(provider).isReady else { return }
        if let id {
            store.setProvider(provider, for: id)
            if provider.isDeep, store.conversation(id)?.folder == nil { onChooseFolder?(id) }
        } else {
            store.defaultProvider = provider
        }
        focusToken += 1
    }

    // MARK: Share flow

    /// ⌘⇧S: widen to the checklist and ask OpenRouter for the brief while the panel opens.
    func beginShare(_ id: UUID) {
        guard let conversation = store.conversation(id), !conversation.messages.isEmpty else { return }
        let prep = SharePrep(conversation: conversation)
        self.prep = prep
        withAnimation(Motion.shareMode(reduceMotion)) { mode = .share(id) }
        summarize(prep, conversation: conversation)
    }

    func regenerateSummary() {
        guard let prep, let conversation = store.conversation(prep.conversationID) else { return }
        summarize(prep, conversation: conversation)
    }

    private func summarize(_ prep: SharePrep, conversation: Conversation) {
        prep.phase = .summarizing
        Task { @MainActor in
            do {
                let draft = try await OpenRouterClient.fromSettings().summarize(conversation)
                withAnimation(Motion.streaming(reduceMotion)) { prep.apply(draft) }
            } catch {
                prep.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                // Still allow a hand-written summary.
                if prep.summary.isEmpty { prep.isEditingSummary = true }
            }
        }
    }

    func choosePerson() {
        guard let prep, let conversation = store.conversation(prep.conversationID) else { return }
        if case .failed = prep.phase, !prep.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prep.phase = .ready }
        guard prep.canContinue else { return }
        let share = store.buildShare(from: prep, conversation: conversation)
        peers.clearOutgoing()
        withAnimation(Motion.shareMode(reduceMotion)) { mode = .send(conversationID: conversation.id, share: share) }
    }

    func send(to peer: NearbyPeer) {
        guard case .send(_, let share) = mode else { return }
        withAnimation(Motion.drop(reduceMotion)) { peers.send(share, to: peer.peerID) }
    }

    /// Called when the transfer is acknowledged: check, haptic, then back to the chat with a badge.
    func deliveryConfirmed() {
        guard case .send(let id, _) = mode, let outgoing = peers.outgoing, outgoing.phase == .delivered else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        store.markShared(id, with: outgoing.peerName)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard case .send(let current, _) = mode, current == id else { return }
            peers.clearOutgoing()
            prep = nil
            justSharedWith = outgoing.peerName
            withAnimation(Motion.shareMode(reduceMotion)) { mode = .chat(id) }
            focusToken += 1
        }
    }

    func chooseSomeoneElse() {
        peers.clearOutgoing()
    }

    // MARK: Receiving

    func decline(_ offer: IncomingOffer) {
        peers.decline(offer)
        if case .offer(offer.id) = mode { withAnimation(Motion.summon(reduceMotion)) { mode = .home } }
    }

    func accept(_ offer: IncomingOffer, open: Bool) {
        peers.accept(offer, open: open)
    }

    /// A share arrived (Continue) or was opened from a file / the list: start the private continued chat.
    func continueChat(_ share: ShareSummary) {
        let id = store.continueFrom(share)
        draft = ""
        withAnimation(Motion.continueOpen(reduceMotion)) { mode = .chat(id) }
        focusToken += 1
    }

    func askSuggested(_ question: String, in id: UUID) {
        draft = ""
        store.ask(question, in: id)
    }
}
