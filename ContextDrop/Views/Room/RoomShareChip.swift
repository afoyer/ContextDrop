import SwiftUI

/// The room chip on a Claude Code or Codex tab: choose how much of the run the room sees and put it in,
/// then show that it's there ("In room · N here") with a menu to open the room, show the log or take it out.
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

    private var peopleHere: String { "\(model.roomPeople) here" }

    var body: some View {
        if visible {
            if let level = model.roomRuns[conversation.id] {
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
            .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .fixedSize()
        .padding(.horizontal, 9).frame(height: 22)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help("Put this run in the room. You choose how much others see.")
        .accessibilityLabel("Put in room")
        .popover(isPresented: $choosing, arrowEdge: .bottom) { sharePopover }
    }

    private var sharePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                Text("\(model.roomName ?? "Room") · \(peopleHere)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(RunShareLevel.allCases) { level in
                    option(.level(level), label: level.label, detail: level.detail)
                }
                option(.lastAnswer, label: "Just the last answer",
                       detail: lastAnswer == nil ? "No finished answer yet" : "One card on the table. The run stays private.")
                    .disabled(lastAnswer == nil)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What to share")
            HStack {
                Spacer()
                // Return puts in what's chosen here. ⌘⇧R, outside the popover, shares the run at the last level.
                Button(action: put) {
                    HStack(spacing: 6) { Text("Put in room"); Text("↵").opacity(0.8) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(choice == .lastAnswer && lastAnswer == nil)
                .help("Put it in the room now. Next time, ⌘⇧R shares the run the same way without opening this.")
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func option(_ value: Choice, label: String, detail: String) -> some View {
        let selected = choice == value
        return Button { choice = value } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 12.5))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(detail)
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
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                Text("In room · \(peopleHere)")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)
            .contentShape(Capsule())
        }
        // A plain button-style menu draws its label in SwiftUI, so the text keeps the accent colour.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 9).frame(height: 22)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
        .help(level == .withLog
              ? "This run is in the room, with its log. Others can watch and ask to continue it."
              : "This run is in the room. Others can watch and ask to continue it.")
        .accessibilityLabel("In room, \(peopleHere). \(level.label)")
    }
}
