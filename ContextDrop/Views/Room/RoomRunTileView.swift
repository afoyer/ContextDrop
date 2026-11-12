import SwiftUI

/// A Claude Code run someone put in the room. Everyone watches; only its owner approves edits or stops it.
/// Three states: running (the full tile), waiting on its owner (orange, with the reason), done (one line).
struct RoomRunTileView: View {
    let store: RoomStore
    let tile: RoomTile
    let run: RoomRunTile
    var onWatch: () -> Void = {}
    /// The owner only: jump to the real chat, where the run can be approved or stopped.
    var onOpenOwnRun: (() -> Void)?

    @State private var asking = false
    @State private var note = ""
    @State private var showSummary = false

    private var isMine: Bool { run.ownerName == store.localName }
    private var ownerLabel: String { isMine ? "Your Mac" : "\(run.ownerName)’s Mac" }

    private var accent: Color {
        switch run.state {
        case .running, .done: RoomPalette.running
        case .waiting, .failed: RoomPalette.waiting
        }
    }

    var body: some View {
        Group {
            switch run.state {
            case .running:
                if tile.collapsed { compact(reason: nil) } else { full }
            case .waiting(let reason):
                compact(reason: reason)
            case .done, .failed:
                finished
            }
        }
        .frame(width: RoomMetrics.runWidth)
        .background(RoomPalette.tile, in: RoundedRectangle(cornerRadius: RoomMetrics.tileRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: RoomMetrics.tileRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RoomMetrics.tileRadius, style: .continuous)
                .strokeBorder(run.isLive ? accent.opacity(0.5) : RoomPalette.border, lineWidth: run.isLive ? 1 : 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }

    // MARK: Header

    private func header(showTime: Bool) -> some View {
        HStack(spacing: 8) {
            RoomKindLabel(text: "Claude Code", color: RoomPalette.labelColor(for: tile))
            Text(run.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            AvatarView(name: run.ownerName, size: 18)
            if showTime, let started = run.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(ownerLabel) · \(Self.clock(context.date.timeIntervalSince(started)))")
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            } else {
                Text(ownerLabel).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize()
            }
            if case .running = run.state {
                RoomCollapseButton(collapsed: tile.collapsed, noun: "run") { store.setCollapsed(tile.id, !tile.collapsed) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoomPalette.tileHeader)
    }

    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Running

    private var full: some View {
        VStack(spacing: 0) {
            header(showTime: true)
            if !run.plan.isEmpty {
                plan
                HairlineDivider()
            }
            if !run.subagents.isEmpty {
                subagents
                HairlineDivider()
            }
            if !run.changes.isEmpty {
                changes
                HairlineDivider()
            }
            log
            if !run.notes.isEmpty {
                HairlineDivider()
                notes
            }
            HairlineDivider()
            footer
        }
    }

    private func section(_ title: String) -> some View {
        RoomKindLabel(text: title, color: .secondary)
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                section("Plan · \(run.planDone) of \(run.plan.count)")
                Spacer(minLength: 4)
                Text(run.folder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            ProgressView(value: Double(run.planDone), total: Double(max(run.plan.count, 1)))
                .progressViewStyle(.linear)
                .tint(RoomPalette.running)
                .accessibilityLabel("Plan progress")
                .accessibilityValue("\(run.planDone) of \(run.plan.count) steps")
            ForEach(Array(run.plan.suffix(8).enumerated()), id: \.offset) { _, step in
                HStack(spacing: 8) {
                    switch step.status {
                    case .done:
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(RoomPalette.running).frame(width: 12)
                    case .active:
                        ProgressView().controlSize(.mini).frame(width: 12)
                    case .pending:
                        Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5).frame(width: 11, height: 11).frame(width: 12)
                    }
                    Text(step.text)
                        .font(.system(size: 12.5, weight: step.status == .active ? .semibold : .regular))
                        .foregroundStyle(step.status == .active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .frame(height: 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subagents: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("Subagents · \(run.subagents.count)")
            ForEach(Array(run.subagents.suffix(4).enumerated()), id: \.offset) { _, agent in
                HStack(spacing: 6) {
                    if agent.running {
                        ProgressView().controlSize(.mini).frame(width: 12)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(RoomPalette.running).frame(width: 12)
                    }
                    Text("\(agent.type) · \(agent.task)").font(.system(size: 11.5)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("Files changed · \(run.changes.count)")
            ForEach(Array(run.changes.suffix(6).enumerated()), id: \.offset) { _, change in
                RoomRunChangeRow(change: change)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                section("Live log")
                Spacer()
                Text("last \(min(run.log.count, 6)) events").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if run.log.isEmpty {
                Text("Nothing yet").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            ForEach(run.log.suffix(6)) { line in
                RoomRunLogLine(text: line.text)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.terminalFill)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(run.notes.suffix(3)) { note in
                HStack(alignment: .top, spacing: 6) {
                    AvatarView(name: note.from, size: 15)
                    Text("\(note.from): \(note.text)").font(.system(size: 11.5)).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(isMine ? "Only you can approve edits or stop this run" : "Only \(run.ownerName) can approve edits or stop this run")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actions: some View {
        if isMine {
            if let onOpenOwnRun { Button("Open", action: onOpenOwnRun).controlSize(.small).help("Open this run’s chat to approve edits or stop it") }
        } else {
            Button("Ask \(run.ownerName)…") { asking = true }
                .controlSize(.small)
                .disabled(!store.isActive || !store.isPresent(run.ownerName))
                .popover(isPresented: $asking, arrowEdge: .bottom) { askPopover }
        }
        Button("Watch", action: onWatch).controlSize(.small).help("Open the full log in a side panel")
    }

    private var askPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send \(run.ownerName) a note").font(.system(size: 12.5, weight: .semibold))
            Text("It shows on the tile and on their Mac. It doesn’t change what the run does.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("e.g. Can you keep the old API too?", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(sendNote)
            HStack {
                Spacer()
                Button("Send", action: sendNote)
                    .buttonStyle(.borderedProminent)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func sendNote() {
        store.sendRunNote(note, to: tile.id)
        note = ""
        asking = false
    }

    // MARK: Waiting on its owner (and collapsed)

    private func compact(reason: String?) -> some View {
        VStack(spacing: 0) {
            header(showTime: reason == nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(accent).frame(width: 8, height: 8)
                    Text(reason ?? run.plan.first(where: { $0.status == .active })?.text ?? "Running")
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Text(progressLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RoomRunChangeCounts(added: run.added, removed: run.removed)
                    actions
                }
                .font(.system(size: 11, design: .monospaced))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var progressLine: String {
        var parts: [String] = []
        if !run.plan.isEmpty { parts.append("Plan \(run.planDone) of \(run.plan.count)") }
        if !run.changes.isEmpty { parts.append("\(run.changes.count) file\(run.changes.count == 1 ? "" : "s") changed") }
        return parts.isEmpty ? "Just started" : parts.joined(separator: " · ")
    }

    // MARK: Done

    private var finished: some View {
        HStack(spacing: 10) {
            Image(systemName: run.state == .done ? "checkmark" : "exclamationmark.triangle")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(doneLine(now: context.date))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AvatarView(name: run.ownerName, size: 18)
            Button("Summary") { showSummary = true }
                .controlSize(.small)
                .popover(isPresented: $showSummary, arrowEdge: .bottom) { summaryPopover }
        }
        .padding(.horizontal, 14)
        .frame(height: 66)
    }

    private func doneLine(now: Date) -> String {
        var parts: [String] = []
        let word = run.state == .done ? "Done" : "Stopped"
        if let ended = run.endedAt {
            let minutes = max(0, Int(now.timeIntervalSince(ended) / 60))
            parts.append(minutes < 1 ? "\(word) just now" : minutes < 60 ? "\(word) \(minutes)m ago" : "\(word) \(minutes / 60)h ago")
        } else {
            parts.append(word)
        }
        if !run.changes.isEmpty { parts.append("\(run.changes.count) file\(run.changes.count == 1 ? "" : "s")") }
        if !run.plan.isEmpty { parts.append("\(run.planDone) of \(run.plan.count) steps") }
        return parts.joined(separator: " · ")
    }

    private var summaryPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(run.title).font(.system(size: 13, weight: .semibold))
                if let summary = run.summary, !summary.isEmpty {
                    MarkdownView(summary, fontSize: 12.5)
                } else {
                    Text("The run left no written summary.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                if !run.changes.isEmpty {
                    Divider()
                    ForEach(Array(run.changes.enumerated()), id: \.offset) { _, change in
                        RoomRunChangeRow(change: change)
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 360)
        .frame(maxHeight: 380)
    }
}

/// "+84 −2": lines added and removed, each shown only when there are any.
struct RoomRunChangeCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        if added > 0 { Text("+\(added)").foregroundStyle(RoomPalette.running) }
        if removed > 0 { Text("−\(removed)").foregroundStyle(RoomPalette.removed) }
    }
}

struct RoomRunChangeRow: View {
    let change: RunChangeInfo

    var body: some View {
        HStack(spacing: 8) {
            Text(change.path).lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
            RoomRunChangeCounts(added: change.added, removed: change.removed)
        }
        .font(.system(size: 11, design: .monospaced))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(change.path), \(change.added) added, \(change.removed) removed")
    }
}

/// One masked log line: the tool name in blue when it starts with "› ".
struct RoomRunLogLine: View {
    let text: String

    var body: some View {
        Group {
            if text.hasPrefix("› "), let space = text.dropFirst(2).firstIndex(of: " ") {
                Text(text[..<space]).foregroundStyle(Color.accentColor) + Text(text[space...]).foregroundStyle(.primary)
            } else if text.hasPrefix("! ") {
                Text(text).foregroundStyle(RoomPalette.waitingLabel)
            } else {
                Text(text).foregroundStyle(text.hasPrefix("› ") ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Watch": the log lines this Mac has seen for a run, in a side panel. Read-only.
struct RoomRunWatchPanel: View {
    let store: RoomStore
    let tileID: UUID
    let onClose: () -> Void

    var body: some View {
        let run = store.tile(tileID)?.run
        let lines = store.runLogs[tileID] ?? []
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(run?.title ?? "Run").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(run.map { "Running on \($0.ownerName == store.localName ? "your" : "\($0.ownerName)’s") Mac · watch only" } ?? "This run was removed")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close log")
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            HairlineDivider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if lines.isEmpty {
                            Text("No log lines yet. They appear here as the run works.")
                                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        }
                        ForEach(lines) { line in
                            RoomRunLogLine(text: line.text).id(line.seq)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                }
                .background(Palette.terminalFill)
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: lines.last?.seq) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HairlineDivider()
            Text("Secrets are hidden before a log leaves its Mac. You see lines from when you started watching the room.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 340)
        .background(RoomPalette.header)
    }
}
