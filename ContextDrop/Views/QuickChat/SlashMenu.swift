import SwiftUI

/// "/" completion list (R3 board 2): folder shortcuts, skills, then ContextDrop actions, with the
/// highlighted skill's description on the right. ↑↓ move, tab or ↵ add, ⌘↵ run now, ⌥↵ pin to the chat.
struct SlashMenu: View {
    let model: PanelModel
    let session: ChatSession

    var body: some View {
        let items = model.slashMatches(in: session)
        let selectedIndex = items.isEmpty ? 0 : min(session.slashSelection, items.count - 1)
        let selected = items.isEmpty ? nil : items[selectedIndex]
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            if items.isEmpty {
                                Text("Nothing named “\(session.slashQuery ?? "")”. Type /add to make a folder shortcut.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).frame(height: 32)
                            }
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || items[index - 1].kind != item.kind {
                                    Text(sectionTitle(item.kind))
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 10).padding(.top, index == 0 ? 2 : 8).padding(.bottom, 2)
                                }
                                row(item, index: index, selected: index == selectedIndex)
                                    .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: session.slashSelection) {
                        if let selected { proxy.scrollTo(selected.id) }
                    }
                }
                .frame(maxWidth: .infinity)
                if let selected, selected.kind == .skill {
                    Divider()
                    detail(selected)
                        .frame(width: 220, alignment: .topLeading)
                }
            }
            if !items.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    HStack(spacing: 4) { Kbd("↵"); Text("Add") }
                    if selected?.kind == .skill {
                        HStack(spacing: 4) { Kbd("⌘↵"); Text("Run now") }
                        if session.conversationID != nil { HStack(spacing: 4) { Kbd("⌥↵"); Text("Pin to this chat") } }
                    }
                    Spacer()
                    HStack(spacing: 4) { Kbd("esc"); Text("Close") }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 28)
            }
        }
    }

    private func sectionTitle(_ kind: SlashItem.Kind) -> String {
        switch kind {
        case .folder: "Folders"
        case .skill: "Skills · Claude Code"
        case .command: "ContextDrop"
        }
    }

    private func row(_ item: SlashItem, index: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon).frame(width: 18)
            Text(item.title).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
            Text(item.kind == .skill ? item.detail : item.subtitle)
                .font(.system(size: 12)).lineLimit(1).truncationMode(item.kind == .folder ? .middle : .tail)
                .opacity(selected ? 0.9 : 0.6)
            Spacer(minLength: 8)
            if selected { Kbd("tab") }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            session.slashSelection = index
            model.completeSlash(in: session)
        }
        .onHover { if $0 { session.slashSelection = index } }
    }

    private func detail(_ item: SlashItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.system(size: 13, weight: .semibold, design: .monospaced))
            Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            if !item.detail.isEmpty {
                Text(item.detail).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .lineLimit(8)
            }
            if item.takesImages {
                Label("Works on the attached image", systemImage: "photo").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Runs with Claude Code.").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    /// Shared key handling for the inputs that show this list.
    @MainActor
    static func handle(_ press: KeyPress, model: PanelModel, session: ChatSession) -> KeyPress.Result? {
        guard let query = session.slashQuery else { return nil }
        switch press.key {
        case .upArrow: model.moveSlash(-1, in: session); return .handled
        case .downArrow: model.moveSlash(1, in: session); return .handled
        case .tab: model.completeSlash(in: session); return .handled
        case .return:
            let item = model.selectedSlashItem(in: session)
            if press.modifiers.contains(.option), item?.kind == .skill {
                return model.pinSelectedSkill(in: session) ? .handled : nil
            }
            if press.modifiers.contains(.command) {
                // ⌘↵ on a skill: add it and send now.
                guard item?.kind == .skill else { return nil }
                model.completeSlash(in: session)
                model.submit(session)
                return .handled
            }
            // An exact command typed in full runs as-is (e.g. "/web" ↵ sets the folder); otherwise complete.
            let lower = query.lowercased()
            if item?.kind != .skill, lower != "add",
               SlashCommand.command(for: lower, folders: model.store.folders) != nil {
                return nil
            }
            model.completeSlash(in: session); return .handled
        case .escape:
            if let slash = session.draft.lastIndex(of: "/") { session.draft = String(session.draft[..<slash]) }
            return .handled
        default: return nil
        }
    }
}

/// "/web ~/Code/web ✕": the folder the next question will use (home), set with a slash command.
struct FolderTag: View {
    let shortcut: FolderShortcut
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text("/\(shortcut.name)").font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(shortcut.display).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Button(action: onRemove) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Don’t use this folder")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9).frame(height: 24)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

/// Auto mode caption under the first question: where it went and why, with a way back to a quick answer.
struct RouteCaption: View {
    let decision: RouteDecision
    let conversation: Conversation
    let model: PanelModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text(text).lineLimit(1).truncationMode(.tail)
            if decision.provider.isDeep {
                Button("Use OpenAI instead") { model.store.useQuickAnswer(in: conversation.id) }
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var text: String {
        if decision.fellBack { return "Auto unavailable · used \(decision.provider.displayName)" }
        var parts = ["Auto → \(decision.provider.displayName)"]
        if decision.provider.isDeep, let folder = conversation.folder { parts.append(FolderDrop.display(folder)) }
        if !decision.reason.isEmpty { parts.append(decision.reason) }
        return parts.joined(separator: " · ")
    }
}
