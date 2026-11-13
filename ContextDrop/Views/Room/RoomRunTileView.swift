import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A Claude Code or Codex run someone put in the room. Everyone watches; only its owner approves edits or stops it.
/// Anyone can ask to continue it with a follow-up and files (`RoomRunContinueSheet`); it runs on the owner's Mac,
/// in the same session, once the owner accepts. The owner's own follow-ups run at once.
/// Three states: running (the full tile), waiting on its owner (orange, with the reason), done (a result line
/// over the summary and changed files; collapsing it leaves the line).
struct RoomRunTileView: View {
    let store: RoomStore
    let tile: RoomTile
    let run: RoomRunTile
    var onWatch: () -> Void = {}
    /// The owner only: jump to the real chat, where the run can be approved or stopped.
    var onOpenOwnRun: (() -> Void)?

    @State private var asking = false
    @State private var note = ""
    @State private var continuing = false
    /// Files dropped on the tile, waiting in the follow-up composer.
    @State private var droppedFiles: [URL] = []
    @State private var dropTargeted = false
    @State private var showAllRequests = false
    /// The room's own appearance. The tile itself is always dark; its popovers follow the room.
    @Environment(\.colorScheme) private var roomScheme

    private var isMine: Bool { run.ownerID == store.localID }
    private var ownerLabel: String { isMine ? "Your Mac" : "\(run.ownerName)’s Mac" }

    private var accent: Color {
        switch run.state {
        case .running, .done: RoomTerminal.green
        case .waiting, .failed: RoomTerminal.amber
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RoomMetrics.runRadius, style: .continuous)
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
        .foregroundStyle(RoomTerminal.text)
        .frame(width: RoomMetrics.runWidth)
        .overlay { if dropTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .background(RoomTerminal.surface, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(run.isLive ? accent.opacity(0.55) : RoomTerminal.border, lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }

    // MARK: Header

    /// The window's title bar: a status light, the agent's command ("claude", "codex"), the run's title, the owner,
    /// and the clock while it runs. Monospaced type is wide, so a running header shows just the clock; whose Mac it
    /// is moves to the line under it (`footer`, `compact`).
    private func header(showTime: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 7, height: 7)
            Text(RoomTerminal.command(for: run.agent))
                .font(RoomTerminal.font(12, .bold))
                .foregroundStyle(accent)
                .fixedSize()
                .accessibilityLabel(run.agent)
            Text(run.title)
                .font(RoomTerminal.font(12, .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            AvatarView(name: run.ownerName, size: 16)
                .help(ownerLabel)
            Group {
                if showTime, let started = run.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(started)))
                    }
                } else {
                    Text(ownerLabel)
                }
            }
            .font(RoomTerminal.font(11))
            .foregroundStyle(RoomTerminal.dim)
            .fixedSize()
            if case .running = run.state {
                RoomCollapseButton(collapsed: tile.collapsed, noun: "run") { store.setCollapsed(tile.id, !tile.collapsed) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoomTerminal.titleBar)
        .overlay(alignment: .bottom) { TerminalRule() }
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
                TerminalRule()
            }
            if !run.subagents.isEmpty {
                subagents
                TerminalRule()
            }
            if !run.changes.isEmpty {
                changes
                TerminalRule()
            }
            log
            if !run.notes.isEmpty {
                TerminalRule()
                notes
            }
            if !run.pendingRequests.isEmpty {
                TerminalRule()
                requests
            }
            TerminalRule()
            footer
        }
    }

    private func section(_ title: String) -> some View {
        TerminalSectionLabel(text: title)
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                section("Plan")
                Spacer(minLength: 4)
                Text(run.folder)
                    .font(RoomTerminal.font(11))
                    .foregroundStyle(RoomTerminal.cyan)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            TerminalProgressBar(done: run.planDone, total: run.plan.count)
                .padding(.bottom, 2)
            ForEach(Array(run.plan.suffix(8).enumerated()), id: \.offset) { _, step in
                HStack(spacing: 8) {
                    TerminalStepMark(status: step.status)
                    Text(step.text)
                        .font(RoomTerminal.font(12, step.status == .active ? .semibold : .regular))
                        .foregroundStyle(step.status == .active ? RoomTerminal.text : RoomTerminal.dim)
                        .lineLimit(1)
                }
                .frame(height: 19)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subagents: some View {
        VStack(alignment: .leading, spacing: 3) {
            section("Subagents · \(run.subagents.count)")
            ForEach(Array(run.subagents.suffix(4).enumerated()), id: \.offset) { _, agent in
                HStack(spacing: 6) {
                    Text("⎿").foregroundStyle(RoomTerminal.faint)
                    if agent.running {
                        TerminalSpinner().foregroundStyle(RoomTerminal.cyan)
                    } else {
                        Text("✓").foregroundStyle(RoomTerminal.green)
                    }
                    (Text(agent.type).foregroundStyle(RoomTerminal.cyan) + Text(" \(agent.task)").foregroundStyle(RoomTerminal.dim))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(RoomTerminal.font(11.5))
                .frame(height: 19)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 3) {
            section("Files changed · \(run.changes.count)")
            ForEach(Array(run.changes.suffix(6).enumerated()), id: \.offset) { _, change in
                RoomRunChangeRow(change: change)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                section("Live log")
                Spacer()
                if !run.log.isEmpty {
                    Text("last \(min(run.log.count, 6)) events").font(RoomTerminal.font(10.5)).foregroundStyle(RoomTerminal.dim)
                }
            }
            if run.log.isEmpty {
                // Either nothing has happened yet, or the owner shares steps only.
                Text("No log lines shared").font(RoomTerminal.font(11)).foregroundStyle(RoomTerminal.dim)
            }
            ForEach(run.log.suffix(6)) { line in
                RoomRunLogLine(text: line.text)
            }
            if case .running = run.state {
                HStack(spacing: 6) {
                    Text("❯").font(RoomTerminal.font(11, .bold)).foregroundStyle(RoomTerminal.green)
                    TerminalCursor()
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoomTerminal.well)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(run.notes.suffix(3)) { note in
                HStack(alignment: .top, spacing: 6) {
                    AvatarView(name: note.from, size: 15)
                    (Text("\(note.from): ").foregroundStyle(RoomTerminal.amber) + Text(note.text))
                        .font(RoomTerminal.font(11.5))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isMine ? "# on your Mac · only you can approve edits or stop this run"
                        : "# on \(run.ownerName)’s Mac · only \(run.ownerName) can approve edits or stop this run")
                .font(RoomTerminal.font(10.5))
                .foregroundStyle(RoomTerminal.dim)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoomTerminal.titleBar)
    }

    @ViewBuilder
    private var actions: some View {
        continueButton
        if isMine {
            if let onOpenOwnRun {
                Button("Open in Quick Chat", action: onOpenOwnRun)
                    .buttonStyle(TerminalButtonStyle())
                    .help("Open this run’s chat to approve edits or stop it")
            }
        } else {
            Button("Ask \(run.ownerName)…") { asking = true }
                .buttonStyle(TerminalButtonStyle())
                .disabled(!store.isActive || !store.isPresent(run.ownerID))
                .popover(isPresented: $asking, arrowEdge: .bottom) { askPopover.environment(\.colorScheme, roomScheme) }
        }
        Button("Watch", action: onWatch)
            .buttonStyle(TerminalButtonStyle())
            .help("Open the full log in a side panel")
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

    // MARK: Continuing the run

    /// Why this Mac can't send a follow-up now, or nil.
    private var continueBlocker: String? { store.continueBlocker(tile.id) }

    private var continueButton: some View {
        Button(isMine ? "Continue…" : "Ask to continue…") { continuing = true }
            .buttonStyle(TerminalButtonStyle())
            .disabled(continueBlocker != nil)
            .help(continueBlocker ?? (isMine
                ? "Send \(run.agent) a follow-up in this session, with files if you like"
                : "Send \(run.ownerName) a follow-up for \(run.agent), with files. It runs on their Mac once they OK it."))
            .popover(isPresented: $continuing, arrowEdge: .bottom) {
                RoomRunContinueSheet(store: store, tileID: tile.id, run: run, files: $droppedFiles) { continuing = false }
                    .environment(\.colorScheme, roomScheme)
            }
    }

    /// Follow-ups waiting on the owner. The owner runs or dismisses each; everyone else sees who is waiting.
    /// Oldest first, so the one waiting longest is on top; past four, the rest fold behind "+N more".
    private var requests: some View {
        let pending = run.pendingRequests
        let shown = showAllRequests ? pending : Array(pending.prefix(Self.foldedRequests))
        return VStack(alignment: .leading, spacing: 8) {
            section("Follow-ups · \(pending.count) waiting")
            ForEach(shown) { request in
                RoomRunRequestRow(store: store, tileID: tile.id, run: run, request: request)
            }
            if pending.count > Self.foldedRequests {
                Button(showAllRequests ? "Show fewer" : "+\(pending.count - Self.foldedRequests) more") { showAllRequests.toggle() }
                    .buttonStyle(.plain)
                    .font(RoomTerminal.font(11))
                    .foregroundStyle(RoomTerminal.cyan)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static let foldedRequests = 4

    private var dropOverlay: some View {
        RoomDropOverlay(title: isMine ? "Continue with these files" : "Ask \(run.ownerName) to continue with these files",
                        detail: isMine ? "They go with your next follow-up" : "They go to \(run.ownerName)’s Mac only")
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard continueBlocker == nil else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task { @MainActor in
            let urls = await FileDropDelegate.urls(from: files)
            guard !urls.isEmpty else { return }
            droppedFiles = RoomRunContinueSheet.merge(droppedFiles, urls)
            continuing = true
        }
        return true
    }

    // MARK: Waiting on its owner (and collapsed)

    private func compact(reason: String?) -> some View {
        VStack(spacing: 0) {
            header(showTime: reason == nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if reason == nil { TerminalSpinner() } else { Text("!") }
                    }
                    .font(RoomTerminal.font(12, .bold))
                    .foregroundStyle(accent)
                    Text(reason ?? run.plan.first(where: { $0.status == .active })?.text ?? "Running")
                        .font(RoomTerminal.font(12))
                        .foregroundStyle(reason == nil ? RoomTerminal.text : RoomTerminal.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    // A running header shows only the clock, so say whose Mac it is here.
                    Text(reason == nil ? "\(ownerLabel) · \(progressLine)" : progressLine)
                        .foregroundStyle(RoomTerminal.dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RoomRunChangeCounts(added: run.added, removed: run.removed)
                }
                .font(RoomTerminal.font(11))
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    actions
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if !run.pendingRequests.isEmpty {
                TerminalRule()
                requests
            }
        }
    }

    private var progressLine: String {
        var parts: [String] = []
        if !run.plan.isEmpty { parts.append("Plan \(run.planDone) of \(run.plan.count)") }
        if !run.changes.isEmpty { parts.append("\(run.changes.count) file\(run.changes.count == 1 ? "" : "s") changed") }
        return parts.isEmpty ? "Just started" : parts.joined(separator: " · ")
    }

    // MARK: Done

    /// The result line, then (unless collapsed) the run's summary and the files it changed, right on the tile.
    private var finished: some View {
        VStack(spacing: 0) {
            finishedRow
            if !tile.collapsed {
                TerminalRule()
                RoomRunSummary(summary: run.summary)
                if !run.changes.isEmpty {
                    TerminalRule()
                    changes
                }
            }
            if !run.pendingRequests.isEmpty {
                TerminalRule()
                requests
            }
        }
    }

    /// Two lines, since monospaced type is wide: "✓ claude <title>" with the owner, then the result and Continue.
    private var finishedRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(run.state == .done ? "✓" : "✗")
                    .font(RoomTerminal.font(13, .bold))
                    .foregroundStyle(accent)
                    .accessibilityLabel(run.state == .done ? "Done" : "Stopped")
                (Text(RoomTerminal.command(for: run.agent) + " ").foregroundStyle(accent).fontWeight(.bold)
                    + Text(run.title).fontWeight(.semibold))
                    .font(RoomTerminal.font(12))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AvatarView(name: run.ownerName, size: 16)
                    .help(ownerLabel)
                RoomCollapseButton(collapsed: tile.collapsed, noun: "run") { store.setCollapsed(tile.id, !tile.collapsed) }
            }
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(doneLine(now: context.date))
                }
                .font(RoomTerminal.font(10.5))
                .foregroundStyle(RoomTerminal.dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                continueButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoomTerminal.titleBar)
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

}

/// A finished run's final answer, inside its tile. Short summaries take their own height; longer ones stop at
/// `maxHeight` and scroll (the canvas lets scrolling over an open finished run reach it).
struct RoomRunSummary: View {
    let summary: String?

    @State private var textHeight: CGFloat = 0

    static let maxHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TerminalSectionLabel(text: "Summary")
            if let summary, !summary.isEmpty {
                ScrollView {
                    MarkdownView(summary, fontSize: 12.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { textHeight = proxy.size.height }
                                    .onChange(of: proxy.size.height) { _, height in textHeight = height }
                            }
                        }
                }
                .frame(height: min(max(textHeight, 16), Self.maxHeight))
                .scrollDisabled(textHeight <= Self.maxHeight)
            } else {
                Text("The run left no written summary.").font(RoomTerminal.font(11.5)).foregroundStyle(RoomTerminal.dim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One follow-up waiting on the owner: who sent it, what it asks, its files, and (for the owner) Run / Dismiss.
struct RoomRunRequestRow: View {
    let store: RoomStore
    let tileID: UUID
    let run: RoomRunTile
    let request: RunRequest

    /// The follow-up text's full height, measured, so the scroll view around it is exactly as tall as it needs.
    @State private var textHeight: CGFloat = 0

    private var isOwner: Bool { run.ownerID == store.localID }

    var body: some View {
        // Worked out once per draw; both the hint and the Run button use it.
        let blocker = isOwner ? store.inbox.blocker(for: tileID) : nil
        let canRun = request.filesSettled && blocker == nil
        let ownerHint = request.filesSettled ? (blocker ?? "Runs on your Mac with this chat’s permission level") : "Files on their way…"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                AvatarView(name: request.from, size: 16)
                // The owner reads all of it before it runs on their Mac, so it is never cut off: short text
                // takes its own height, longer text stops at `maxTextHeight` and scrolls.
                ScrollView {
                    requestText.background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { textHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in textHeight = height }
                        }
                    }
                }
                .frame(height: min(max(textHeight, 16), Self.maxTextHeight))
                .scrollDisabled(textHeight <= Self.maxTextHeight)
            }
            ForEach(request.files) { file in
                HStack(spacing: 5) {
                    Image(systemName: file.status == .sending ? "arrow.up.circle" : file.isProblem ? "exclamationmark.triangle" : "doc")
                        .font(.system(size: 10))
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(file.status == .sending ? "on its way" : file.isProblem ? "won’t be included" : ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .foregroundStyle(.tertiary)
                }
                .font(RoomTerminal.font(10.5))
                .foregroundStyle(file.isProblem ? RoomTerminal.amber : RoomTerminal.dim)
                .padding(.leading, 22)
            }
            HStack(spacing: 6) {
                if isOwner {
                    Text(ownerHint)
                        .font(RoomTerminal.font(10.5))
                        .foregroundStyle(RoomTerminal.dim)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { store.dismissRunRequest(request.id, in: tileID) }
                        .buttonStyle(TerminalButtonStyle())
                    Button("Run") { store.acceptRunRequest(request.id, in: tileID) }
                        .buttonStyle(TerminalButtonStyle(prominent: true))
                        .disabled(!canRun)
                        .help(canRun ? "Ask \(run.agent) this in the same session, on your Mac" : ownerHint)
                } else {
                    Text("Waiting for \(run.ownerName) to run it")
                        .font(RoomTerminal.font(10.5))
                        .foregroundStyle(RoomTerminal.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .background(RoomTerminal.well, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(RoomTerminal.rule, lineWidth: 1))
    }

    private static let maxTextHeight: CGFloat = 140

    private var requestText: some View {
        Text(request.text.isEmpty ? "\(request.from) sent files" : "\(request.from): \(request.text)")
            .font(RoomTerminal.font(11.5))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The follow-up composer: a prompt for the run's agent and files to go with it.
struct RoomRunContinueSheet: View {
    let store: RoomStore
    let tileID: UUID
    let run: RoomRunTile
    @Binding var files: [URL]
    let onDone: () -> Void

    @State private var text = ""
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    private var isMine: Bool { run.ownerID == store.localID }
    private var blocker: String? { store.continueBlocker(tileID) }
    private var sendable: Bool {
        blocker == nil && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty)
    }

    static func merge(_ current: [URL], _ new: [URL]) -> [URL] {
        var all = current
        for url in new where !all.contains(url) { all.append(url) }
        return Array(all.prefix(RoomLimits.maxFilesPerRequest))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isMine ? "Continue “\(run.title)”" : "Ask \(run.ownerName) to continue “\(run.title)”")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                Text(isMine
                     ? "\(run.agent) picks up this session on your Mac."
                     : "\(run.agent) picks up this session on \(run.ownerName)’s Mac once they OK it. Your files go only to their Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("e.g. Now add tests for the new endpoint", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .focused($focused)
                .onSubmit(send)
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(systemName: Attachments.isImage(url) ? "photo" : "doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                files.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(url.lastPathComponent)")
                        }
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            HStack(spacing: 8) {
                Button {
                    files = Self.merge(files, FilePicker.files(prompt: "Add",
                        message: isMine ? "Files for \(run.agent) to look at in this session."
                                        : "Files go to \(run.ownerName)’s Mac with your follow-up."))
                } label: {
                    Label("Add Files…", systemImage: "paperclip")
                }
                .controlSize(.small)
                .disabled(files.count >= RoomLimits.maxFilesPerRequest)
                if let blocker {
                    Text(blocker)
                        .font(.system(size: 11))
                        .foregroundStyle(RoomPalette.waitingLabel)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(isMine ? "Run" : "Send to \(run.ownerName)", action: send)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!sendable)
            }
        }
        .padding(12)
        .frame(width: 320)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in files = Self.merge(files, await FileDropDelegate.urls(from: providers)) }
            return true
        }
        .onAppear { focused = true }
    }

    private func send() {
        guard sendable, store.continueRun(text, files: files, in: tileID) else { return }
        text = ""
        files = []
        onDone()
    }
}

/// "+84 −2": lines added and removed, each shown only when there are any.
struct RoomRunChangeCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        if added > 0 { Text("+\(added)").foregroundStyle(RoomTerminal.green) }
        if removed > 0 { Text("−\(removed)").foregroundStyle(RoomTerminal.red) }
    }
}

struct RoomRunChangeRow: View {
    let change: RunChangeInfo

    var body: some View {
        HStack(spacing: 8) {
            Text(change.path)
                .foregroundStyle(RoomTerminal.text)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            RoomRunChangeCounts(added: change.added, removed: change.removed)
        }
        .font(RoomTerminal.font(11))
        .frame(height: 17)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(change.path), \(change.added) added, \(change.removed) removed")
    }
}

/// One masked log line, in terminal colors: the tool name in cyan when it starts with "› ", warnings in amber.
struct RoomRunLogLine: View {
    let text: String

    var body: some View {
        Group {
            if text.hasPrefix("› "), let space = text.dropFirst(2).firstIndex(of: " ") {
                Text(text[..<space]).foregroundStyle(RoomTerminal.cyan) + Text(text[space...]).foregroundStyle(RoomTerminal.text)
            } else if text.hasPrefix("! ") {
                Text(text).foregroundStyle(RoomTerminal.amber)
            } else {
                Text(text).foregroundStyle(text.hasPrefix("› ") ? RoomTerminal.cyan : RoomTerminal.dim)
            }
        }
        .font(RoomTerminal.font(11))
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
                    Text(run.map { "\($0.agent) on \($0.ownerID == store.localID ? "your" : "\($0.ownerName)’s") Mac" } ?? "This run was removed")
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
            RoomTranscriptScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty {
                        Text("No log lines yet. They appear here as the run works.")
                            .font(RoomTerminal.font(11)).foregroundStyle(RoomTerminal.dim)
                    }
                    ForEach(lines) { line in
                        RoomRunLogLine(text: line.text).id(line.seq)
                    }
                }
                .padding(12)
            }
            .id(tileID)
            // The same terminal well as the tile's live log, in both appearances.
            .background(RoomTerminal.well)
            .environment(\.colorScheme, .dark)
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

// MARK: Terminal look

/// Run tiles look like a terminal window: a fixed dark surface in both appearances, monospaced type and
/// ANSI-style colors. The colors are fixed (not light/dark pairs) because the tile is always dark.
enum RoomTerminal {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Color {
        Color(nsColor: NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
    }

    static let surface = rgb(0.08, 0.085, 0.095)
    /// The title bar and footer: one step lighter than the surface.
    static let titleBar = rgb(0.12, 0.125, 0.14)
    /// The live log and follow-ups: one step darker.
    static let well = rgb(0.055, 0.06, 0.065)
    static let rule = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.14)
    static let text = Color.white.opacity(0.9)
    /// Secondary text; still readable at 10.5 pt on the surface.
    static let dim = Color.white.opacity(0.6)
    /// Decoration only (empty progress cells, tree glyphs), never text that has to be read.
    static let faint = Color.white.opacity(0.3)
    static let green = rgb(0.37, 0.83, 0.59)
    static let amber = rgb(1.0, 0.72, 0.3)
    static let red = rgb(1.0, 0.45, 0.4)
    static let cyan = rgb(0.45, 0.78, 1.0)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// What you'd type to start the agent: "Claude Code" → "claude", "Codex" → "codex".
    static func command(for agent: String) -> String {
        agent.split(separator: " ").first.map { $0.lowercased() } ?? agent.lowercased()
    }
}

/// A one-point rule between the tile's sections.
struct TerminalRule: View {
    var body: some View { Rectangle().fill(RoomTerminal.rule).frame(height: 1) }
}

/// A section heading inside a run tile ("PLAN", "LIVE LOG").
struct TerminalSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(RoomTerminal.font(10, .semibold))
            .kerning(0.6)
            .foregroundStyle(RoomTerminal.dim)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A braille spinner, like a CLI's. Holds still on "›" when Reduce Motion is on.
struct TerminalSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    var body: some View {
        Group {
            if reduceMotion {
                Text("›")
            } else {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let index = Int(context.date.timeIntervalSinceReferenceDate * 10) % Self.frames.count
                    Text(String(Self.frames[index]))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A blinking block cursor at the end of a live log. Steady when Reduce Motion is on.
struct TerminalCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            block(visible: true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.55)) { context in
                block(visible: Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0)
            }
        }
    }

    private func block(visible: Bool) -> some View {
        Rectangle().fill(RoomTerminal.green).frame(width: 7, height: 13).opacity(visible ? 0.9 : 0)
    }
}

/// "[x]", "[⠹]", "[ ]": a plan step's state, as a CLI checklist.
struct TerminalStepMark: View {
    let status: RunPlanStep.Status

    var body: some View {
        HStack(spacing: 0) {
            Text("[")
            switch status {
            case .done: Text("x").foregroundStyle(RoomTerminal.green)
            case .active: TerminalSpinner().foregroundStyle(RoomTerminal.amber)
            case .pending: Text(" ")
            }
            Text("]")
        }
        .font(RoomTerminal.font(11.5, .bold))
        .foregroundStyle(status == .pending ? RoomTerminal.faint : RoomTerminal.dim)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status == .done ? "Done" : status == .active ? "In progress" : "To do")
    }
}

/// "████████░░░░░░░░ 2/5": plan progress as a text bar.
struct TerminalProgressBar: View {
    let done: Int
    let total: Int
    var cells = 30

    var body: some View {
        let filled = total > 0 ? min(cells, Int((Double(done) / Double(total) * Double(cells)).rounded())) : 0
        HStack(spacing: 8) {
            Text(String(repeating: "█", count: filled)).foregroundStyle(RoomTerminal.green)
                + Text(String(repeating: "░", count: cells - filled)).foregroundStyle(RoomTerminal.faint)
            Text("\(done)/\(total)").foregroundStyle(RoomTerminal.dim)
        }
        .font(RoomTerminal.font(10))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plan progress")
        .accessibilityValue("\(done) of \(total) steps")
    }
}

/// A run tile's buttons: monospaced labels in a thin outlined box; `prominent` fills it green.
struct TerminalButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        TerminalButton(configuration: configuration, prominent: prominent)
    }

    private struct TerminalButton: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            configuration.label
                .font(RoomTerminal.font(11, prominent ? .bold : .medium))
                .foregroundStyle(prominent ? RoomTerminal.surface : RoomTerminal.text)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(fill, in: shape)
                .overlay(shape.strokeBorder(prominent ? Color.clear : RoomTerminal.border, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if prominent { return RoomTerminal.green.opacity(configuration.isPressed ? 0.75 : hovering && isEnabled ? 0.9 : 1) }
            return Color.white.opacity(configuration.isPressed ? 0.16 : hovering && isEnabled ? 0.09 : 0.03)
        }
    }
}
