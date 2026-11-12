import AppKit
import SwiftUI

/// Right-hand pane of a deep chat (R3 board 1): what the agent and its subagents are doing, the raw
/// CLI events, and the files it changed. Agent messages stay in the chat.
struct TerminalPane: View {
    enum Segment: String, CaseIterable { case log = "Log", changes = "Changes" }

    let model: PanelModel
    let conversation: Conversation
    @State private var segment: Segment = .log
    @State private var raw = false
    @State private var follow = true

    private var state: TerminalState { model.store.terminals[conversation.id] ?? TerminalState() }
    private var running: Bool { model.store.isRunning(conversation.id) }
    private var filter: String? { model.activityFilter[conversation.id] }

    private var visibleLines: [TerminalLine] {
        if raw { return state.rawLines }
        let lines = state.lines.filter { $0.kind != .text || $0.agentID != nil }
        switch filter {
        case nil: return lines
        case "main": return lines.filter { $0.agentID == nil }
        case let id?: return lines.filter { $0.agentID == id }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            statusStrip
            if segment == .log {
                filterRow
                if conversation.provider.needsActivityHeartbeat && state.run.isActive && !raw { activityStatus }
            }
            HairlineDivider()
            switch segment {
            case .log: log
            case .changes: changes
            }
        }
        .background(Palette.terminalFill)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Activity").font(.system(size: 13, weight: .semibold))
            phaseBadge
            Picker("", selection: $segment) {
                Text("Log").tag(Segment.log)
                Text(state.changes.isEmpty ? "Changes" : "Changes \(Set(state.changes.map(\.path)).count)").tag(Segment.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            Spacer(minLength: 4)
            if running {
                Button { model.store.stop(conversation.id) } label: { Image(systemName: "stop.fill") }
                    .help("Stop (⌘.)")
                    .accessibilityLabel("Stop the agent")
            }
            Button { copyLog() } label: { Image(systemName: "doc.on.doc") }
                .help(raw ? "Copy the raw events" : "Copy the log")
                .accessibilityLabel("Copy the log")
                .disabled(visibleLines.isEmpty)
            Button { model.store.clearTerminal(conversation.id) } label: { Image(systemName: "trash") }
                .help("Clear")
                .accessibilityLabel("Clear the log")
                .disabled(state.lines.isEmpty || running)
            Button { model.toggleTerminal() } label: { Image(systemName: "sidebar.right") }
                .help("Hide activity (⌥⌘A)")
                .accessibilityLabel("Hide activity")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var phaseBadge: some View {
        let (label, color): (String, Color) = switch state.run.phase {
        case .idle: ("idle", .secondary)
        case .starting: ("starting", .orange)
        case .running: (conversation.needsUser ? "needs you" : "running", conversation.needsUser ? NeedsYou.tint : .green)
        case .finished: ("done", .secondary)
        case .stopped: ("stopped", .orange)
        case .failed: ("failed", .red)
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).frame(height: 18)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    // MARK: Status

    private var statusStrip: some View {
        let run = state.run
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let pid = run.pid { chip("pid \(pid)") }
                    if let model = run.model { chip(model) }
                    chip(run.level.chip, tint: run.level == .acceptEdits ? .orange : nil)
                    if let elapsed = elapsed(run, now: context.date) { chip(elapsed) }
                    if let input = run.inputTokens { chip("\(Self.compact(input)) in · \(Self.compact(run.outputTokens ?? 0)) out") }
                    if let cost = run.costUSD, cost > 0 { chip(String(format: "$%.3f", cost)) }
                    if let code = run.exitCode, !run.isActive { chip("exit \(code)", tint: code == 0 ? nil : .red) }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .opacity(run.phase == .idle && run.pid == nil ? 0.6 : 1)
    }

    /// All · Main · one per subagent, then Raw JSON and Follow.
    private var filterRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    filterButton("All", value: nil)
                    if !state.subagents.isEmpty {
                        filterButton("Main", value: "main")
                        ForEach(state.subagents) { agent in
                            filterButton(agent.type, value: agent.id, status: agent.status)
                        }
                    }
                }
            }
            .disabled(raw)
            .opacity(raw ? 0.5 : 1)
            Toggle("Raw JSON", isOn: $raw)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("The CLI’s events exactly as they arrived")
            Button { follow.toggle() } label: {
                HStack(spacing: 3) { Text("Follow"); Image(systemName: "arrow.down.to.line") }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(follow ? Color.accentColor : Color.secondary)
            .help(follow ? "Following new lines. Click to stop." : "Scroll to new lines as they arrive")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    private func filterButton(_ title: String, value: String?, status: Subagent.Status? = nil) -> some View {
        let selected = filter == value
        return Button {
            model.activityFilter[conversation.id] = value
        } label: {
            HStack(spacing: 4) {
                if let status {
                    Circle().fill(status == .running ? Color.accentColor : (status == .failed ? .red : .green)).frame(width: 5, height: 5)
                }
                Text(title).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(height: 20)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var activityStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lastEvent = state.run.lastEventAt ?? state.run.startedAt ?? context.date
            let quietSeconds = max(0, Int(context.date.timeIntervalSince(lastEvent)))
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(conversation.needsUser ? "Waiting for you in the chat"
                     : quietSeconds < 10 ? "Waiting for Codex’s next event…"
                     : "No new Codex event for \(quietSeconds)s · process still active")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 24)
        }
    }

    private func chip(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(tint ?? .secondary)
            .lineLimit(1)
            .padding(.horizontal, 6).frame(height: 18)
            .background((tint ?? .secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func elapsed(_ run: TerminalRun, now: Date) -> String? {
        guard let start = run.startedAt else { return nil }
        let seconds = Int((run.endedAt ?? now).timeIntervalSince(start))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    static func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    // MARK: Log

    private var log: some View {
        let lines = visibleLines
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if lines.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    ForEach(lines) { line in
                        if raw {
                            Text(line.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).id(line.id)
                        } else {
                            TerminalLineView(line: line, agent: agentLabel(line.agentID)).id(line.id)
                        }
                    }
                    if running {
                        Text("▍").foregroundStyle(Color.accentColor).id("cursor")
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Keyed on the last line, so it keeps following once the log is full and lines roll off the top.
            .onChange(of: lines.last?.id) { if follow { scrollToEnd(proxy, lines) } }
            .onChange(of: follow) { if follow { scrollToEnd(proxy, lines) } }
            .onAppear { scrollToEnd(proxy, lines) }
        }
    }

    private var emptyText: String {
        if raw { return "Raw events from the CLI appear here." }
        if conversation.folder == nil { return "Choose a project folder, then ask. What the agent does appears here; its answer stays in the chat." }
        if filter != nil { return "Nothing from this agent yet." }
        return "What the agent does appears here; its answer stays in the chat."
    }

    private func agentLabel(_ id: String?) -> String? {
        guard filter == nil, let id else { return nil }
        return state.subagents.first(where: { $0.id == id })?.type ?? "subagent"
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ lines: [TerminalLine]) {
        if running { proxy.scrollTo("cursor", anchor: .bottom) } else if let last = lines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
    }

    private func copyLog() {
        let text = visibleLines.map { raw ? $0.text : "\(TerminalLineView.prefix($0.kind))\($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Changes

    private var changes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if state.changes.isEmpty {
                    Text(running ? "No files changed yet." : "The last run didn’t change any files.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ChangesCard(changes: state.changes, folder: conversation.folder)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TerminalLineView: View {
    let line: TerminalLine
    /// Shown before the line when the log mixes agents.
    var agent: String? = nil

    static func prefix(_ kind: TerminalLine.Kind) -> String {
        switch kind {
        case .command: ""
        case .tool: "› "
        case .text: "● "
        case .result: "✓ "
        case .error: "✗ "
        case .info, .output, .stderr: ""
        }
    }

    var body: some View {
        switch line.kind {
        case .output:
            VStack(alignment: .leading, spacing: 4) {
                Text("Tool output")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(line.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .padding(.vertical, 3)
        default:
            ((agent.map { Text("[\($0)] ").foregroundStyle(.purple) } ?? Text(""))
                + Text(Self.prefix(line.kind) + line.text)
                .foregroundStyle(color)
                .fontWeight(line.kind == .command || line.kind == .tool ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, line.kind == .command ? 6 : 0)
        }
    }

    private var color: Color {
        switch line.kind {
        case .command: .primary
        case .tool: .accentColor
        case .text: .primary
        case .result: .green
        case .error: .red
        case .stderr: .orange
        case .info, .output: .secondary
        }
    }
}
