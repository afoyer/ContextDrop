import AppKit
import SwiftUI

// The share flow: checklist and summary, several tabs at once, choosing a person, delivery.
extension PanelModel {
    // MARK: Sharing several tabs (R3 board 4)

    /// The given tabs arrive ticked; the other open tabs are listed unticked.
    func beginMultiShare(_ ids: [UUID]) {
        let candidates = workspace.tabs.filter { store.conversation($0)?.messages.isEmpty == false }
        guard !candidates.isEmpty else { return }
        multiShare = MultiSharePrep(items: candidates.map { .init(id: $0, included: ids.contains($0)) })
        prep = nil
        extraShares = []
        peers.clearOutgoing()
        withAnimation(Motion.shareMode(reduceMotion)) { mode = .shareTabs }
        focusToken += 1
    }

    /// Writes a summary for each ticked tab, then goes to Choose Person (or AirDrop).
    func prepareMultiShare(airDrop: Bool) {
        guard let multi = multiShare, multi.phase.canStart else { return }
        let chosen = multi.items.filter(\.included).compactMap { store.conversation($0.id) }
        guard !chosen.isEmpty else { return }
        multi.phase = .summarizing(done: 0, total: chosen.count)
        multi.task = Task { @MainActor in
            var built: [(conversationID: UUID, share: ShareSummary)] = []
            for (index, conversation) in chosen.enumerated() {
                let item = SharePrep(conversation: conversation)
                do {
                    item.apply(try await ShareSummarizer.summarize(conversation, detail: item.detail))
                } catch {
                    if Task.isCancelled { return }
                    let reason = error.userMessage
                    multi.phase = .failed("Couldn’t summarize “\(conversation.title)”. \(reason)")
                    return
                }
                guard !Task.isCancelled, multiShare === multi else { return }
                built.append((conversation.id, item.share(of: conversation, from: store.peers)))
                multi.phase = .summarizing(done: index + 1, total: chosen.count)
            }
            guard let first = built.first else { return }
            if airDrop {
                do { try ShareFile.airDrop(built.map(\.share)) } catch { notices.text = "AirDrop isn’t available on this Mac." }
                multi.phase = .choosing
                return
            }
            extraShares = Array(built.dropFirst())
            peers.clearOutgoing()
            withAnimation(Motion.shareMode(reduceMotion)) { mode = .send(conversationID: first.conversationID, share: first.share) }
        }
    }

    /// ⌘⇧S: widen to the checklist and ask OpenAI for the brief while the panel opens.
    func beginShare(_ id: UUID) {
        multiShare = nil
        extraShares = []
        guard let conversation = store.conversation(id), !conversation.messages.isEmpty else { return }
        let prep = SharePrep(conversation: conversation)
        self.prep = prep
        withAnimation(Motion.shareMode(reduceMotion)) { mode = .share(id) }
        summarize(prep, conversation: conversation)
    }

    /// Brief ↔ Detailed: remembered, and the brief is rewritten at the new level.
    func setShareDetail(_ detail: ShareDetail) {
        guard let prep, prep.detail != detail else { return }
        prep.detail = detail
        AppDefaults.shareDetail = detail
        regenerateSummary()
    }

    func regenerateSummary() {
        guard let prep, let conversation = store.conversation(prep.conversationID) else { return }
        summarize(prep, conversation: conversation)
    }

    private func summarize(_ prep: SharePrep, conversation: Conversation) {
        summaryTask?.cancel()
        let token = UUID()
        summaryToken = token
        let detail = prep.detail
        prep.phase = .summarizing
        summaryTask = Task { @MainActor in
            defer { if summaryToken == token { summaryTask = nil; summaryToken = nil } }
            do {
                let draft = try await ShareSummarizer.summarize(conversation, detail: detail)
                guard !Task.isCancelled, summaryToken == token, self.prep === prep else { return }
                withAnimation(Motion.streaming(reduceMotion)) { prep.apply(draft) }
            } catch {
                guard !Task.isCancelled, summaryToken == token, self.prep === prep else { return }
                prep.phase = .failed(error.userMessage)
                // Still allow a hand-written summary.
                if prep.summary.isEmpty { prep.isEditingSummary = true }
            }
        }
    }

    func choosePerson() {
        guard let prep, let conversation = store.conversation(prep.conversationID) else { return }
        if case .failed = prep.phase, !prep.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prep.phase = .ready }
        guard prep.canContinue else { return }
        let share = prep.share(of: conversation, from: store.peers)
        peers.clearOutgoing()
        withAnimation(Motion.shareMode(reduceMotion)) { mode = .send(conversationID: conversation.id, share: share) }
    }

    func send(to peer: NearbyPeer) {
        guard case .send(_, let share) = mode else { return }
        withAnimation(Motion.drop(reduceMotion)) { peers.send(share, extras: extraShares.map(\.share), to: peer.peerID) }
    }

    /// Called when the transfer is acknowledged: check, haptic, then back to the chat with a badge.
    func deliveryConfirmed() {
        guard case .send(let id, _) = mode, let outgoing = peers.outgoing, outgoing.phase == .delivered else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        store.markShared(id, with: outgoing.peerName)
        for extra in extraShares { store.markShared(extra.conversationID, with: outgoing.peerName) }
        let wasMulti = multiShare != nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard case .send(let current, _) = mode, current == id else { return }
            peers.clearOutgoing()
            prep = nil
            extraShares = []
            if wasMulti {
                // Shared from the window: the tabs are still there, so the panel just goes away.
                multiShare = nil
                workspace.multiSelection.removeAll()
                mode = .home
                actions.hide()
            } else {
                withAnimation(Motion.shareMode(reduceMotion)) { mode = .chat(id) }
            }
            focusToken += 1
        }
    }

    func chooseSomeoneElse() {
        peers.clearOutgoing()
    }
}
