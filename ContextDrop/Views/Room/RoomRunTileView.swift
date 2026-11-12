import SwiftUI
import UniformTypeIdentifiers

/// A Claude Code or Codex run someone put in the room. Everyone watches; only its owner approves edits or stops it.
/// Anyone can ask to continue it with a follow-up and files (`RoomRunContinueSheet`); it runs on the owner's Mac,
/// in the same session, once the owner accepts. The owner's own follow-ups run at once.
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
    @State private var continuing = false
    /// Files dropped on the tile, waiting in the follow-up composer.
    @State private var droppedFiles: [URL] = []
    @State private var dropTargeted = false
    @State private var showAllRequests = false

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
        .overlay { if dropTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
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
            RoomKindLabel(text: run.agent, color: RoomPalette.labelColor(for: tile))
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
            if !run.pendingRequests.isEmpty {
                HairlineDivider()
                requests
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
        VStack(alignment: .leading, spacing: 8) {
            Text(isMine ? "Only you can approve edits or stop this run" : "Only \(run.ownerName) can approve edits or stop this run")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actions: some View {
        continueButton
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

    // MARK: Continuing the run

    /// Why this Mac can't send a follow-up now, or nil.
    private var continueBlocker: String? { store.continueBlocker(tile.id) }

    private var continueButton: some View {
        Button(isMine ? "Continue…" : "Ask to continue…") { continuing = true }
            .controlSize(.small)
            .disabled(continueBlocker != nil)
            .help(continueBlocker ?? (isMine
                ? "Send \(run.agent) a follow-up in this session, with files if you like"
                : "Send \(run.ownerName) a follow-up for \(run.agent), with files. It runs on their Mac once they OK it."))
            .popover(isPresented: $continuing, arrowEdge: .bottom) {
                RoomRunContinueSheet(store: store, tileID: tile.id, run: run, files: $droppedFiles) { continuing = false }
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
                    .buttonStyle(.borderless)
                    .controlSize(.small)
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
                }
                .font(.system(size: 11, design: .monospaced))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actions
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if !run.pendingRequests.isEmpty {
                HairlineDivider()
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

    private var finished: some View {
        VStack(spacing: 0) {
            finishedRow
            if !run.pendingRequests.isEmpty {
                HairlineDivider()
                requests
            }
        }
    }

    private var finishedRow: some View {
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
            continueButton
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

/// One follow-up waiting on the owner: who sent it, what it asks, its files, and (for the owner) Run / Dismiss.
struct RoomRunRequestRow: View {
    let store: RoomStore
    let tileID: UUID
    let run: RoomRunTile
    let request: RunRequest

    /// The follow-up text's full height, measured, so the scroll view around it is exactly as tall as it needs.
    @State private var textHeight: CGFloat = 0

    private var isOwner: Bool { run.ownerName == store.localName }

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
                .font(.system(size: 11))
                .foregroundStyle(file.isProblem ? AnyShapeStyle(RoomPalette.waitingLabel) : AnyShapeStyle(.secondary))
                .padding(.leading, 22)
            }
            HStack(spacing: 8) {
                if isOwner {
                    Text(ownerHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { store.dismissRunRequest(request.id, in: tileID) }
                        .controlSize(.small)
                    Button("Run") { store.acceptRunRequest(request.id, in: tileID) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRun)
                        .help(canRun ? "Ask \(run.agent) this in the same session, on your Mac" : ownerHint)
                } else {
                    Text("Waiting for \(run.ownerName) to run it")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static let maxTextHeight: CGFloat = 140

    private var requestText: some View {
        Text(request.text.isEmpty ? "\(request.from) sent files" : "\(request.from): \(request.text)")
            .font(.system(size: 12))
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

    private var isMine: Bool { run.ownerName == store.localName }
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
                    Text(run.map { "\($0.agent) on \($0.ownerName == store.localName ? "your" : "\($0.ownerName)’s") Mac" } ?? "This run was removed")
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
