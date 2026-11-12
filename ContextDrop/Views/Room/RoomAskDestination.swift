import SwiftUI

/// Where the room's ask bar sends what is typed: a new chat tile that answers, or a coding-agent run on this Mac.
enum RoomAskDestination: Hashable {
    case chat
    case run(ProviderKind)

    var provider: ProviderKind? {
        if case .run(let provider) = self { provider } else { nil }
    }

    /// The menu's name for it. A chat names the selection it starts from.
    func title(selected count: Int) -> String {
        switch self {
        case .chat: count == 0 ? "New chat" : "New chat from \(count) selected"
        case .run(let provider): "New \(provider.displayName) run"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .run: "terminal"
        }
    }

    var placeholder: String {
        switch self {
        case .chat: "Ask the room…"
        case .run(let provider): "What should \(provider.displayName) do?"
        }
    }

    /// Coding agents that can start a run from the room, with their status on this Mac.
    /// Ones whose CLI isn't installed are left out.
    @MainActor static func runProviders(_ chats: ChatStore?) -> [(kind: ProviderKind, status: ProviderStatus)] {
        ProviderKind.allCases.filter { $0.roomShare == .liveRun }.compactMap { kind in
            let status = chats?.status(kind) ?? .checking
            if case .notFound = status { return nil }
            return (kind, status)
        }
    }
}

/// The "To" chip: picks between a new chat and a new run.
struct RoomAskDestinationMenu: View {
    let destination: RoomAskDestination
    let selectedCount: Int
    let providers: [(kind: ProviderKind, status: ProviderStatus)]
    let select: (RoomAskDestination) -> Void

    var body: some View {
        Menu {
            option(.chat, detail: "Answers in a new chat tile")
            if !providers.isEmpty { Divider() }
            ForEach(providers, id: \.kind) { provider in
                option(.run(provider.kind), detail: provider.status.isReady ? "Runs in a folder on your Mac" : provider.status.detail)
                    .disabled(!provider.status.isReady)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: destination.symbol)
                Text(destination.title(selected: selectedCount))
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 9).frame(height: 22)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help("Choose what typing here does: start a chat, or start a run on your Mac.")
        .accessibilityLabel("To: \(destination.title(selected: selectedCount))")
    }

    private func option(_ choice: RoomAskDestination, detail: String) -> some View {
        Button {
            select(choice)
        } label: {
            Text(choice.title(selected: selectedCount))
            Text(detail)
            if choice == destination { Image(systemName: "checkmark") }
        }
    }
}

/// "Talks" for a chat, "Acts" for a run, with what that means for everyone in the room.
struct RoomAskBadge: View {
    let acts: Bool

    private var color: Color { acts ? RoomPalette.runLabel : RoomPalette.chatLabel }
    private var detail: String {
        acts ? "Runs on your Mac. Others can watch." : "Answers in a new chat tile. Nothing changes on anyone’s Mac."
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(acts ? "ACTS" : "TALKS")
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .fixedSize()
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(acts ? "Acts" : "Talks"). \(detail)")
    }
}

/// The folder a run from the ask bar works in. Clicking it chooses another.
struct RoomRunFolderChip: View {
    let folder: URL?
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(folder.map(FolderDrop.display) ?? "Choose folder…")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 170)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9).frame(height: 22)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("The project folder the run works in. Click to choose another.")
        .accessibilityLabel(folder.map { "Folder: \(FolderDrop.display($0)). Choose another" } ?? "Choose a folder")
    }
}
