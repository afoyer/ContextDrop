import SwiftUI

/// R3 board 4: tick the tabs to drop together. Each gets its own summary; a tab that is still
/// working shares what it has up to now.
struct ShareTabsView: View {
    let model: PanelModel
    let multi: MultiSharePrep
    @FocusState private var focused: Bool

    private var store: ChatStore { model.store }
    private var busy: Bool { !multi.phase.canStart }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "drop").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share tabs").font(.system(size: 14, weight: .semibold))
                    Text("Each tab is sent as its own summary. Nothing else leaves this Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                PrivateBadge()
            }
            .padding(.horizontal, 18).frame(height: 56)
            HairlineDivider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(multi.items.enumerated()), id: \.element.id) { index, item in
                        if let conversation = store.conversation(item.id) { row(conversation, item: item, index: index) }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            if case .failed(let message) = multi.phase {
                HairlineDivider()
                NoticeRow(text: message) { multi.phase = .choosing }
            }
            HairlineDivider()
            footer
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    private func row(_ conversation: Conversation, item: MultiSharePrep.Item, index: Int) -> some View {
        let selected = multi.focused == index
        let running = store.isRunning(conversation.id)
        return HStack(spacing: 10) {
            Image(systemName: item.included ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(item.included ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail(conversation, running: running)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if running { Text("shares up to now").font(.system(size: 11)).foregroundStyle(NeedsYou.tint) }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(selected ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            multi.focused = index
            multi.toggle(item.id)
        }
        .opacity(busy ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.included ? [.isButton, .isSelected] : .isButton)
    }

    private func detail(_ conversation: Conversation, running: Bool) -> String {
        var parts = [conversation.provider.displayName]
        let answers = conversation.messages.filter { $0.role != .user && $0.error == nil }.count
        parts.append("\(answers) answer\(answers == 1 ? "" : "s")")
        if conversation.keptCount > 0 { parts.append("\(conversation.keptCount) kept") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if case .summarizing(let done, let total) = multi.phase {
                ProgressView().controlSize(.small)
                Text("Writing summaries… \(done) of \(total)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.escape() }
            } else {
                HStack(spacing: 4) { Kbd("space"); Text("Tick") }.font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.escape() }
                if ShareFile.airDropAvailable {
                    Button { model.prepareMultiShare(airDrop: true) } label: { Label("AirDrop…", systemImage: "dot.radiowaves.left.and.right") }
                        .disabled(multi.includedCount == 0)
                }
                Button { model.prepareMultiShare(airDrop: false) } label: {
                    Text(multi.includedCount == 1 ? "Choose Person ↵" : "Share \(multi.includedCount) Tabs ↵")
                }
                .buttonStyle(.borderedProminent)
                .disabled(multi.includedCount == 0)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16).frame(height: 50)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape: model.escape(); return .handled
        case .upArrow: multi.focused = max(0, multi.focused - 1); return .handled
        case .downArrow: multi.focused = min(multi.items.count - 1, multi.focused + 1); return .handled
        case .space:
            if multi.items.indices.contains(multi.focused) { multi.toggle(multi.items[multi.focused].id) }
            return .handled
        case .return: model.prepareMultiShare(airDrop: false); return .handled
        default: return .ignored
        }
    }
}
