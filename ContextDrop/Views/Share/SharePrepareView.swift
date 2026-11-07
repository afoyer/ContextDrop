import SwiftUI

/// Board 2: "Keep the important stuff". Checklist on the left, exactly-what-they-get preview on the right.
struct SharePrepareView: View {
    @Bindable var model: PanelModel
    @Bindable var prep: SharePrep
    @FocusState private var focus: Field?

    enum Field: Hashable { case list, summary, note }

    private var conversation: Conversation? { model.store.conversation(prep.conversationID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            HStack(spacing: 0) {
                checklist
                    .frame(width: 540)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                previewColumn
            }
            .frame(height: 620)
            HairlineDivider()
            footer
        }
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear { focus = prep.isEditingSummary ? .summary : .list }
        .onChange(of: prep.isEditingSummary) { _, editing in focus = editing ? .summary : .list }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.escape() } label: { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to chat")
            Text("Share “\(prep.title)”").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer()
            Text("Summary by OpenRouter").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(prep.countsLine).font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Cancel") { model.escape() }
            Button { model.choosePerson() } label: { Text("Choose Person ↵") }
                .buttonStyle(.borderedProminent)
                .disabled(!canChoose)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var canChoose: Bool {
        !prep.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prep.phase != .summarizing
    }

    // MARK: Checklist

    private var checklist: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("Summary")
                    summaryCard.id(SharePrep.Row.summary)

                    if !prep.kept.isEmpty {
                        sectionLabel("Kept by you", star: true)
                        ForEach(prep.kept) { item in
                            CheckRow(checked: true, locked: true, focused: prep.focused == .kept(item.id), trailing: "answer") {
                                Text(item.text).lineLimit(2)
                            }
                            .id(SharePrep.Row.kept(item.id))
                        }
                    }

                    if !prep.decisions.isEmpty {
                        sectionLabel("Decisions")
                        ForEach($prep.decisions) { $item in
                            CheckRow(checked: item.included, focused: prep.focused == .decision(item.id), onToggle: { prep.toggle(.decision(item.id)) }) {
                                Text(item.value)
                            }
                            .id(SharePrep.Row.decision(item.id))
                        }
                    }

                    if !prep.questions.isEmpty {
                        sectionLabel("Open questions")
                        ForEach($prep.questions) { $item in
                            CheckRow(checked: item.included, focused: prep.focused == .question(item.id), onToggle: { prep.toggle(.question(item.id)) }) {
                                Text(item.value)
                            }
                            .id(SharePrep.Row.question(item.id))
                        }
                    }

                    sectionLabel("Notes")
                    ForEach(prep.notes) { note in
                        CheckRow(checked: note.included, focused: prep.focused == .note(note.id), trailing: "card", onToggle: { prep.toggle(.note(note.id)) }) {
                            Text(note.value.title).fontWeight(.medium)
                        }
                        .id(SharePrep.Row.note(note.id))
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 16)
                        TextField("Add a note card…", text: $prep.newNoteTitle)
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .note)
                            .onSubmit { prep.addNote(); focus = .list }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 6)

                    if !prep.fileNames.isEmpty {
                        sectionLabel("Files")
                        CheckRow(checked: prep.includeFileNames, focused: prep.focused == .fileNames, trailing: "names only", onToggle: { prep.toggle(.fileNames) }) {
                            Text(prep.fileNames.prefix(4).joined(separator: ", ") + (prep.fileNames.count > 4 ? "…" : ""))
                                .font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        }
                        .id(SharePrep.Row.fileNames)
                    }

                    HairlineDivider().padding(.horizontal, 10).padding(.vertical, 8)
                    CheckRow(checked: prep.includeTranscript, focused: prep.focused == .transcript, onToggle: { prep.toggle(.transcript) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Full conversation · \(prep.transcriptCount) messages").foregroundStyle(.secondary)
                            Text(prep.includeTranscript ? "Every word will be sent." : "Not sent. Turn on only if they need every word.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .id(SharePrep.Row.transcript)
                }
                .padding(12)
            }
            .onChange(of: prep.focused) { _, row in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(row) } }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch prep.phase {
            case .summarizing where prep.summary.isEmpty:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("OpenRouter is writing the summary…").foregroundStyle(.secondary)
                }
                ThinkingLine(reduceMotion: model.reduceMotion)
            case .failed(let error) where prep.summary.isEmpty && !prep.isEditingSummary:
                Text("Couldn’t write a summary: \(error)").foregroundStyle(.red)
            default:
                if prep.isEditingSummary {
                    TextEditor(text: $prep.summary)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                        .focused($focus, equals: .summary)
                        .overlay(alignment: .topLeading) {
                            if prep.summary.isEmpty {
                                Text("Write a short summary…").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                } else {
                    Text(prep.summary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button(prep.isEditingSummary ? "Done ⌘E" : "Edit ⌘E") { prep.isEditingSummary.toggle() }
                Button("Regenerate ⌘R") { model.regenerateSummary() }
                    .disabled(prep.phase == .summarizing)
                if case .failed = prep.phase {
                    Button("Settings…") { model.onOpenSettings?() }
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
        .font(.system(size: 13))
        .lineSpacing(2)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(prep.focused == .summary ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: prep.focused == .summary ? 1.5 : 0.5)
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func sectionLabel(_ title: String, star: Bool = false) -> some View {
        HStack(spacing: 5) {
            if star { Image(systemName: "star.fill").foregroundStyle(Palette.keptRule).font(.system(size: 10)) }
            Text(title)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What they will get").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                if let conversation {
                    SharePreviewCard(share: model.store.buildShare(from: prep, conversation: conversation), placeholder: prep.phase == .summarizing)
                        .animation(Motion.streaming(model.reduceMotion), value: prep.summary)
                }
            }
            Label("Your chat stays on your Mac. They continue in their own copy.", systemImage: "lock.fill")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
    }

    // MARK: Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let cmd = press.modifiers.contains(.command)
        if cmd, press.characters == "e" { prep.isEditingSummary.toggle(); return .handled }
        if cmd, press.characters == "r" { model.regenerateSummary(); return .handled }
        if press.key == .escape {
            if focus == .summary || focus == .note { prep.isEditingSummary = false; focus = .list; return .handled }
            model.escape(); return .handled
        }
        guard focus == .list else { return .ignored } // typing in a field
        switch press.key {
        case .upArrow: prep.move(-1); return .handled
        case .downArrow: prep.move(1); return .handled
        case .space: prep.toggleFocused(); return .handled
        case .return: model.choosePerson(); return .handled
        default: return .ignored
        }
    }
}

struct CheckRow<Content: View>: View {
    let checked: Bool
    var locked = false
    let focused: Bool
    var trailing: String?
    var onToggle: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { onToggle?() } label: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(checked ? Color.accentColor : Color.clear)
                    .overlay {
                        if checked {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .opacity(locked ? 0.55 : 1)
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .accessibilityLabel(checked ? "Included" : "Not included")
            content.font(.system(size: 13)).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary) }
            if focused && !locked { Kbd("space") }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(focused ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
    }
}

/// The card the recipient sees: shared by board 2 (preview), board 3 thumbnail and board 4 preview.
struct SharePreviewCard: View {
    let share: ShareSummary
    var placeholder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AvatarView(name: share.senderName, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(share.title).font(.system(size: 15, weight: .semibold))
                    Text("From \(share.senderName) · ready to continue").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if placeholder && share.summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([0.9, 0.75, 0.6], id: \.self) { w in
                        RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(height: 8).frame(maxWidth: .infinity, alignment: .leading).scaleEffect(x: w, anchor: .leading)
                    }
                }
            } else {
                Text(share.summary).font(.system(size: 13)).lineSpacing(3).foregroundStyle(.primary.opacity(0.9))
            }
            ForEach(share.kept) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kept answer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.keptText)
                    Text(item.text).font(.system(size: 13)).lineSpacing(2).lineLimit(6)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.keptTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(Palette.keptRule).frame(width: 3)
                }
            }
            if !share.decisions.isEmpty || !share.openQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !share.decisions.isEmpty {
                        Text("Decided").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(share.decisions, id: \.self) { Text("· \($0)") }
                    }
                    if !share.openQuestions.isEmpty {
                        Text("Still open").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(share.openQuestions, id: \.self) { Text("· \($0)").foregroundStyle(Color.accentColor) }
                    }
                }
                .font(.system(size: 13))
            }
            if !share.notes.isEmpty || !share.fileNames.isEmpty {
                FlowChips(items: share.notes.map(\.title) + share.fileNames)
            }
            if let transcript = share.transcript {
                Label("Full conversation · \(transcript.count) messages", systemImage: "text.bubble")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }
}

struct FlowChips: View {
    let items: [String]

    var body: some View {
        // Simple wrapping row (few items): HStack with wrapping via ViewThatFits fallback to two rows.
        let rows = items.chunked(into: 3)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in
                        Text(item).font(.system(size: 12)).lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
