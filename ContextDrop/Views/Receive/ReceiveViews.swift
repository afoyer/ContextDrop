import SwiftUI

// MARK: - Notification (board 4 · 01), shown in a non-activating top-right panel

struct ShareNotificationView: View {
    let model: PanelModel
    let offer: IncomingOffer
    let onClose: () -> Void
    @State private var previewing = false

    var body: some View {
        VStack(spacing: 0) {
            if previewing {
                previewBody
            } else {
                summaryBody
            }
        }
        .frame(width: 380)
        .background(MaterialBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .animation(Motion.summon(model.reduceMotion), value: previewing)
    }

    private var summaryBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(name: offer.senderName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(offer.senderName) shared a chat with you").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text("now").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(offer.preview.title).font(.system(size: 13)).italic().lineLimit(1)
                    Text(offer.preview.countsLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(14)
            HairlineDivider()
            HStack(spacing: 0) {
                notificationButton("Decline") { model.decline(offer); onClose() }
                Divider()
                notificationButton("Preview") { previewing = true }
                Divider()
                notificationButton("Continue", primary: true) { model.accept(offer, open: true); onClose() }
            }
            .frame(height: 36)
        }
    }

    private var previewBody: some View {
        VStack(spacing: 0) {
            OfferPreviewContent(preview: offer.preview).padding(16)
            HairlineDivider()
            HStack(spacing: 8) {
                Button("Decline") { model.decline(offer); onClose() }
                Button("Save for Later") { model.accept(offer, open: false); onClose() }
                Spacer()
                Button("Continue Chat ↵") { model.accept(offer, open: true); onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func notificationButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: primary ? .semibold : .regular))
                .foregroundStyle(primary ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(primary ? Color.accentColor.opacity(0.1) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shared by the notification preview and the in-panel preview (board 4 · 02).
struct OfferPreviewContent: View {
    let preview: SharePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AvatarView(name: preview.senderName, size: 24)
                Text(preview.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Spacer()
            }
            Text(preview.summary).font(.system(size: 13)).lineSpacing(2).foregroundStyle(.primary.opacity(0.9))
            if !preview.openQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Still open").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(preview.openQuestions, id: \.self) { Text($0).foregroundStyle(Color.accentColor) }
                }
                .font(.system(size: 12))
            }
            if !preview.noteTitles.isEmpty { FlowChips(items: preview.noteTitles) }
            Text("From \(preview.senderName) · \(preview.senderDevice)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - In-panel previews (opened from the Quick Chat list)

struct OfferPreviewView: View {
    let model: PanelModel
    let offer: IncomingOffer
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            OfferPreviewContent(preview: offer.preview).padding(18)
            HairlineDivider()
            HStack(spacing: 8) {
                if case .receiving = offer.phase {
                    ProgressView().controlSize(.small)
                    Text("Receiving from \(offer.senderName)…").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                } else if offer.phase == .failed {
                    Text("Couldn’t receive this chat. Ask \(offer.senderName) to send it again.").font(.system(size: 12)).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { model.peers.dismissFailedOffer(offer); model.escape() }
                } else {
                    Button("Decline") { model.decline(offer) }
                    Button("Save for Later") { model.accept(offer, open: false) }
                    Spacer()
                    Button("Continue Chat ↵") { model.accept(offer, open: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 16).frame(height: 50)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .escape: model.escape(); return .handled
            case .return:
                if offer.phase == .pending { model.accept(offer, open: true) }
                return .handled
            default: return .ignored
            }
        }
    }
}

struct ReceivedPreviewView: View {
    let model: PanelModel
    let share: ShareSummary
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { SharePreviewCard(share: share).padding(18) }
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
            HairlineDivider()
            HStack(spacing: 8) {
                Button("Remove") {
                    model.store.removeReceived(share.id)
                    model.escape()
                }
                Spacer()
                Button("Continue Chat ↵") { model.continueChat(share) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.horizontal, 16).frame(height: 50)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .escape: model.escape(); return .handled
            case .return: model.continueChat(share); return .handled
            default: return .ignored
            }
        }
    }
}

// MARK: - Continued chat pieces (board 4 · 03)

/// Pinned, foldable. Shows the brief, and on request the exact text the AI receives.
struct PickedUpBlock: View {
    let share: ShareSummary
    let reduceMotion: Bool
    @State private var expanded = true
    @State private var showExact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Motion.resize(reduceMotion)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Text("Picked up from \(share.senderName) · \(share.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("The AI starts from this").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.fromTint.opacity(0.06))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(share.summary).foregroundStyle(.primary.opacity(0.9))
                    ForEach(share.kept) { item in
                        (Text("Kept answer · ").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.keptText) + Text(item.text))
                            .lineLimit(4)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.keptTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(alignment: .leading) {
                                UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7).fill(Palette.keptRule).frame(width: 3)
                            }
                    }
                    if !share.decisions.isEmpty { chipRow("Decided", share.decisions) }
                    if !share.notes.isEmpty { chipRow("Notes", share.notes.map(\.title)) }
                    if !share.fileNames.isEmpty { chipRow("Files", share.fileNames) }
                    Button(showExact ? "Hide exact AI context" : "Show exact AI context") { showExact.toggle() }
                        .buttonStyle(.link).font(.system(size: 11))
                    if showExact {
                        Text(share.contextPrompt())
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .font(.system(size: 13))
                .lineSpacing(2)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .transition(.opacity)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func chipRow(_ label: String, _ items: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            FlowChips(items: items)
        }
    }
}

struct AskThisRow: View {
    let question: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Open question").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text(question).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            Button("Ask this", action: action).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
