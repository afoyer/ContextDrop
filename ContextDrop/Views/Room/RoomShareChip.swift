import SwiftUI

/// The room chip on a Claude Code or Codex tab: choose how much of the run the room sees and put it in,
/// then show that it's there ("In room · 2 watching") with a menu to open the room, show the log or take it out.
/// Shown only while you're in a room and the run has started.
struct RoomShareChip: View {
    let model: PanelModel
    let conversation: Conversation

    @State private var choosing = false
    @State private var choice: Choice = .level(.steps)

    /// What "Put in room" shares.
    enum Choice: Hashable {
        case level(RunShareLevel)
        case lastAnswer
    }

    private var visible: Bool {
        model.roomActive && conversation.provider.roomShare == .liveRun && !conversation.messages.isEmpty
    }

    /// The answer "Just the last answer" puts on the table: the latest one that finished with text.
    private var lastAnswer: Message? {
        conversation.messages.last(where: { $0.role == .assistant && $0.error == nil && !$0.text.isEmpty })
    }

    private var people: Int { model.room?.people ?? 0 }

    /// Everyone else in the room: the ones who can watch the run.
    private var watching: String {
        let others = max(0, people - 1)
        return others == 0 ? "In room" : "In room · \(others) watching"
    }

    var body: some View {
        if visible {
            if let level = model.room?.runs[conversation.id] {
                sharedMenu(level)
            } else {
                shareButton
            }
        }
    }

    // MARK: Not in the room yet

    private var shareButton: some View {
        Button {
            choice = .level(model.lastShareLevel)
            choosing = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                Text("Room")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(RoomPalette.chatLabel)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chipCapsule(tint: .accentColor, outlined: true)
        .help("Put this run in the room. You choose how much others see.")
        .accessibilityLabel("Put in room")
        .popover(isPresented: $choosing, arrowEdge: .bottom) { sharePopover }
    }

    private var sharePopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.room?.name ?? "Room") · \(people) here")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(RunShareLevel.allCases) { level in
                    option(.level(level), label: level.label, detail: level.detail)
                }
                option(.lastAnswer, label: "Just the last answer",
                       detail: lastAnswer == nil ? "No finished answer yet" : nil)
                    .disabled(lastAnswer == nil)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What to share")
            HStack {
                Spacer()
                // Return puts in what's chosen here. ⌘⇧R, outside the popover, shares the run at the last level.
                Button(action: put) {
                    HStack(spacing: 6) { Text("Put in room").fontWeight(.semibold); Text("↵").opacity(0.8) }
                }
                .buttonStyle(.borderedProminent)
                .tint(RoomPalette.go)
                .keyboardShortcut(.defaultAction)
                .disabled(choice == .lastAnswer && lastAnswer == nil)
                .help("Put it in the room now. Next time, ⌘⇧R shares the run the same way without opening this.")
            }
        }
        .padding(8)
        .frame(width: 260)
    }

    private func option(_ value: Choice, label: String, detail: String?) -> some View {
        let selected = choice == value
        return Button { choice = value } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 12))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(detail ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func put() {
        switch choice {
        case .level(let level):
            model.actions.shareRun(conversation, level)
        case .lastAnswer:
            guard let lastAnswer else { return }
            model.actions.sendToRoom(lastAnswer, conversation)
        }
        choosing = false
    }

    // MARK: In the room

    private func sharedMenu(_ level: RunShareLevel) -> some View {
        Menu {
            Button("Open Room") { model.actions.openRoom() }
            Toggle("Show Live Log", isOn: Binding(
                get: { level == .withLog },
                set: { model.actions.setShareLevel(conversation.id, $0 ? .withLog : .steps) }
            ))
            Divider()
            Button("Take Out of Room", role: .destructive) { model.actions.unshareRun(conversation.id) }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(RoomPalette.running).frame(width: 6, height: 6)
                Text(watching)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(RoomPalette.chatLabel)
            .contentShape(Capsule())
        }
        // A plain button-style menu draws its label in SwiftUI, so the text keeps its colour.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .chipCapsule(tint: .accentColor)
        .help(level == .withLog
              ? "This run is in the room, with its log. Others can watch and ask to continue it."
              : "This run is in the room. Others can watch and ask to continue it.")
        .accessibilityLabel("\(watching). \(level.label)")
    }
}
