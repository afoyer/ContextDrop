import AppKit
import SwiftUI

// Cards a coding agent's answer can carry (R3 board 1, R2 board 6): permission requests, decisions,
// subagent lanes, and the files it changed.

/// Orange accent shared by everything that is waiting on the user.
enum NeedsYou {
    static let tint = Color.orange
    static let fill = Color.orange.opacity(0.07)
    static let border = Color.orange.opacity(0.55)
}

// MARK: - Permission

/// "Allow an edit to PeerService.swift (+6 −1)?" with the real diff, Deny, Allow and "Always allow".
struct PermissionCard: View {
    let request: PermissionRequest
    let conversation: Conversation
    let store: ChatStore
    var askedBy: String?
    @State private var showDiff = false

    private var pending: Bool { request.status == .pending }
    private var busy: Bool { !request.live && store.isRunning(conversation.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(request.live ? "NEEDS YOUR OK" : "WAS REFUSED")
                    .font(.system(size: 10.5, weight: .bold)).tracking(0.4)
                    .foregroundStyle(pending ? NeedsYou.tint : .secondary)
                if let askedBy { Text("asked by \(askedBy)").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                if request.isEdit, request.added + request.removed > 0 { DiffStat(added: request.added, removed: request.removed) }
            }
            title
            if showDiff, !request.hunks.isEmpty {
                DiffView(hunks: request.hunks, maxHeight: 280)
            }
            HStack(spacing: 8) {
                if request.isEdit, !request.hunks.isEmpty {
                    Button(showDiff ? "Hide diff" : "See diff") { showDiff.toggle() }.controlSize(.small)
                }
                Spacer()
                if pending {
                    if !request.isFolderWide {
                        Menu {
                            Button("Always allow \(request.ruleLabel) in this chat") { store.allow(request.id, in: conversation.id, always: true) }
                        } label: { Text("Always…") }
                        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                        .help("Stop asking about \(request.ruleLabel) in this chat")
                    }
                    Button("Deny") { store.deny(request.id, in: conversation.id) }
                        .controlSize(.small)
                        .disabled(!request.live && busy)
                    Button(request.live ? "Allow" : "Allow and continue") { store.allow(request.id, in: conversation.id) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                } else {
                    statusLabel
                }
            }
        }
        .padding(12)
        .background(pending ? NeedsYou.fill : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(pending ? NeedsYou.border : Color(nsColor: .separatorColor), lineWidth: pending ? 1 : 0.5))
        .onAppear { showDiff = pending && request.isEdit && request.added + request.removed <= 40 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var title: some View {
        if request.isFolderWide {
            Text("\(conversation.provider.displayName) wants to edit files in this folder.").font(.system(size: 13))
        } else if request.isEdit {
            (Text(request.status == .pending ? "Allow an edit to " : "Edit to ")
             + Text(request.summary.isEmpty ? request.fileName : request.summary).font(.system(size: 12.5, design: .monospaced))
             + Text(request.status == .pending ? "?" : ""))
                .font(.system(size: 13))
        } else if request.tool == "Bash" {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.status == .pending ? "Run this command?" : "Command").font(.system(size: 13))
                Text(request.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        } else {
            (Text("Use ") + Text(request.tool).fontWeight(.semibold) + Text(request.summary.isEmpty ? "?" : ": \(request.summary)"))
                .font(.system(size: 13))
                .lineLimit(3)
        }
    }

    private var statusLabel: some View {
        let (text, icon, color): (String, String, Color) = switch request.status {
        case .allowed: ("Allowed", "checkmark", .green)
        case .denied: ("Denied", "xmark", .secondary)
        case .expired: ("No longer waiting", "clock", .secondary)
        case .pending: ("", "", .clear)
        }
        return Label(text, systemImage: icon).font(.system(size: 12)).foregroundStyle(color)
    }
}

// MARK: - Decision

/// Claude asked a question with options: answer with one click, a number key, or by typing.
struct DecisionCard: View {
    let question: AgentQuestion
    let conversationID: UUID
    let store: ChatStore
    var askedBy: String?
    /// Number keys answer while the composer is empty.
    var keysActive = true
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("DECISION").font(.system(size: 10.5, weight: .bold)).tracking(0.4)
                    .foregroundStyle(question.status == .pending ? NeedsYou.tint : .secondary)
                if let askedBy { Text("asked by \(askedBy)").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                if question.items.count > 1 {
                    Text("\(question.items.filter { $0.answer != nil }.count + 1) of \(question.items.count)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ForEach(question.items.filter { $0.answer != nil }) { item in
                HStack(spacing: 6) {
                    Text(item.question).foregroundStyle(.secondary).lineLimit(1)
                    Text("→ \(item.answer ?? "")").fontWeight(.medium)
                }
                .font(.system(size: 12))
            }
            if question.status == .pending, let item = question.current {
                Text(item.question).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                        optionButton(index: index, option: option, item: item)
                    }
                }
                HStack(spacing: 8) {
                    Text(item.multiSelect ? "Pick any, then Answer. Or type your own answer below." : "Or type your own answer below. Also shown in the menu bar.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if item.multiSelect {
                        Button("Answer ↵") { submitPicked(item) }
                            .controlSize(.small).buttonStyle(.borderedProminent)
                            .disabled(picked.isEmpty)
                    }
                }
            } else if question.status == .expired {
                Label("The agent stopped before this was answered.", systemImage: "clock").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(question.status == .pending ? NeedsYou.fill : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(question.status == .pending ? NeedsYou.border : Color(nsColor: .separatorColor), lineWidth: question.status == .pending ? 1 : 0.5))
        .onChange(of: question.current?.question) { picked = [] }
    }

    private func optionButton(index: Int, option: AgentQuestion.Option, item: AgentQuestion.Item) -> some View {
        let isPicked = picked.contains(option.label)
        return Button {
            if item.multiSelect {
                if isPicked { picked.remove(option.label) } else { picked.insert(option.label) }
            } else {
                store.answer(question.id, with: option.label, in: conversationID)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if index < 9 { Kbd("\(index + 1)") }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .semibold))
                    if !option.detail.isEmpty {
                        Text(option.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if item.multiSelect { Image(systemName: isPicked ? "checkmark.square.fill" : "square").foregroundStyle(isPicked ? Color.accentColor : .secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPicked ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isPicked ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isPicked ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Option \(index + 1): \(option.label)")
    }

    private func submitPicked(_ item: AgentQuestion.Item) {
        let answer = item.options.map(\.label).filter(picked.contains).joined(separator: ", ")
        store.answer(question.id, with: answer, in: conversationID)
    }

    /// Number key → option, for the composer's key handler. Returns true if it answered.
    @MainActor
    static func answer(digit: Character, question: AgentQuestion, conversationID: UUID, store: ChatStore) -> Bool {
        guard let item = question.current, !item.multiSelect, let n = digit.wholeNumberValue, n >= 1, n <= item.options.count else { return false }
        store.answer(question.id, with: item.options[n - 1].label, in: conversationID)
        return true
    }
}

// MARK: - Subagents

/// "Claude Code started 3 subagents": one small lane each. Click to filter the Activity log.
struct SubagentLanes: View {
    let subagents: [Subagent]
    /// The lane currently filtering the log, if any.
    let filtered: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Started \(subagents.count) subagent\(subagents.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Click to filter the activity log").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                ForEach(subagents) { agent in lane(agent) }
            }
        }
    }

    private func lane(_ agent: Subagent) -> some View {
        let selected = filtered == agent.id
        return Button { onSelect(agent.id) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    switch agent.status {
                    case .running: ProgressView().controlSize(.mini).frame(width: 11, height: 11)
                    case .done: Image(systemName: "checkmark").foregroundStyle(.green).font(.system(size: 10, weight: .bold))
                    case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 10))
                    }
                    Text(agent.type).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(from: agent.startedAt, to: agent.endedAt ?? context.date))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(agent.task).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !agent.current.isEmpty || agent.status != .running {
                    Text(agent.status == .running ? agent.current : (agent.status == .done ? "Done" : "Failed"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agent.type) subagent: \(agent.task)")
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

// MARK: - Changes

/// What the agent changed in this answer: files with +/− counts, each opening to its diff.
struct ChangesCard: View {
    let changes: [FileChange]
    let folder: URL?
    @State private var expanded: Set<String> = []
    @State private var copied = false

    private var totals: (added: Int, removed: Int) {
        changes.reduce((0, 0)) { ($0.0 + $1.added, $0.1 + $1.removed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.ellipsis").foregroundStyle(.secondary)
                Text("Changed \(Set(changes.map(\.path)).count) file\(Set(changes.map(\.path)).count == 1 ? "" : "s")")
                    .font(.system(size: 12.5, weight: .semibold))
                DiffStat(added: totals.added, removed: totals.removed)
                Spacer()
                Button(copied ? "Copied" : "Copy diff") { copyAll() }
                    .buttonStyle(.borderless).font(.system(size: 12))
                    .disabled(changes.allSatisfy { $0.hunks.isEmpty })
            }
            .padding(.horizontal, 12).frame(height: 34)
            ForEach(changes) { change in
                HairlineDivider()
                row(change)
                if expanded.contains(change.id) {
                    Group {
                        if change.hunks.isEmpty {
                            Text("No diff available for this file.").font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            DiffView(hunks: change.hunks, maxHeight: 320)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                }
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .onAppear { if changes.count == 1, let only = changes.first { expanded = [only.id] } }
    }

    private func row(_ change: FileChange) -> some View {
        HStack(spacing: 8) {
            Button {
                if expanded.contains(change.id) { expanded.remove(change.id) } else { expanded.insert(change.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded.contains(change.id) ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Image(systemName: icon(change.kind)).foregroundStyle(color(change.kind)).frame(width: 14)
                    Text(display(change.path)).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    if change.kind != .modified {
                        Text(change.kind == .created ? "new" : "deleted").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    DiffStat(added: change.added, removed: change.removed)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(change.fileName), \(change.added) lines added, \(change.removed) removed")
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: change.path)) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless)
                .help("Open \(change.fileName)")
                .accessibilityLabel("Open \(change.fileName)")
                .disabled(change.kind == .deleted)
        }
        .padding(.horizontal, 12).frame(height: 30)
    }

    private func display(_ path: String) -> String {
        folder.flatMap { FolderDrop.relative(path, to: $0.path) } ?? (path as NSString).abbreviatingWithTildeInPath
    }

    private func icon(_ kind: FileChange.Kind) -> String {
        switch kind {
        case .created: "plus.square"
        case .modified: "pencil"
        case .deleted: "minus.square"
        }
    }

    private func color(_ kind: FileChange.Kind) -> Color {
        switch kind {
        case .created: .green
        case .modified: .accentColor
        case .deleted: .red
        }
    }

    private func copyAll() {
        let text = changes.filter { !$0.hunks.isEmpty }.map { LineDiff.unifiedText(path: display($0.path), hunks: $0.hunks) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// The run ended early or oddly.
struct WarningRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Skills used with a message (and pinned ones in the composer).
struct SkillChip: View {
    let name: String
    var pinned = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: pinned ? "pin" : "lightbulb").font(.system(size: 10))
            Text(name).font(.system(size: 12))
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(pinned ? "Unpin \(name)" : "Remove \(name)")
            }
        }
        .foregroundStyle(pinned ? Color.secondary : Color.accentColor)
        .padding(.horizontal, 8).frame(height: 24)
        .background(pinned ? Color.clear : Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            if pinned { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])) }
        }
    }
}
