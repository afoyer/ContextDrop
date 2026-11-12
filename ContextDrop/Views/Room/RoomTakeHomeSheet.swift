import SwiftUI

/// When a room ends, each person picks what to bring into a new chat of their own:
/// a summary of the room written by OpenAI (with this Mac's key), plus the tiles they choose.
struct RoomTakeHomeSheet: View {
    let store: RoomStore
    let onOpen: (ShareSummary) -> Void
    let onClose: () -> Void

    @State private var includeSummary = true
    @State private var chosen: Set<UUID> = []
    @State private var seeded = false
    @State private var working = false

    private var tiles: [RoomTile] { store.tiles }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Room ended · take home").font(.system(size: 15, weight: .semibold))
                Text("Pick what goes into a new chat of your own. Nothing else from the room is kept.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: $includeSummary) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Room summary (OpenAI)").font(.system(size: 12.5, weight: .medium))
                            Text("Written now from everything on the canvas, with your key")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                    Divider().padding(.vertical, 4)
                    ForEach(tiles) { tile in
                        Toggle(isOn: Binding(get: { chosen.contains(tile.id) },
                                             set: { if $0 { chosen.insert(tile.id) } else { chosen.remove(tile.id) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(RoomTakeHome.title(of: tile)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(RoomTakeHome.detail(of: tile)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 300)

            HStack(spacing: 8) {
                Button(chosen.count == tiles.count ? "Select None" : "Select All") {
                    chosen = chosen.count == tiles.count ? [] : Set(tiles.map(\.id))
                }
                .controlSize(.small)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Not Now", action: onClose).keyboardShortcut(.cancelAction)
                Button("Open as Chat", action: open)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || (!includeSummary && chosen.isEmpty))
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            // Start with what is most likely wanted: chats, and this person's own cards.
            chosen = Set(tiles.filter { $0.chat != nil || $0.addedBy == store.localName }.map(\.id))
        }
    }

    private func open() {
        guard let room = store.room else { return }
        let picked = tiles.filter { chosen.contains($0.id) }
        let all = tiles
        let wantsSummary = includeSummary
        let name = store.localName
        let device = store.peers.localDevice
        working = true
        Task {
            let summary = wantsSummary ? await RoomTakeHome.summarize(room: room, tiles: all) : nil
            working = false
            onOpen(RoomTakeHome.share(room: room, picked: picked, summary: summary, by: name, device: device))
        }
    }
}

/// Builds what a person takes home from a room: the same handoff brief a share uses, so it opens as a normal chat.
enum RoomTakeHome {
    static func title(of tile: RoomTile) -> String {
        switch tile.content {
        case .card(let body): "\(body.kind.label): \(body.text.prefix(60))"
        case .chat(let chat): "Chat: \(chat.title)"
        case .run(let run): "\(run.agent) run: \(run.title)"
        }
    }

    static func detail(of tile: RoomTile) -> String {
        switch tile.content {
        case .card:
            return "by \(tile.addedBy)"
        case .chat(let chat):
            let count = chat.messages.filter { $0.kind != .event }.count
            return "\(chat.ownerName)’s · \(count) message\(count == 1 ? "" : "s")"
                + (chat.files.isEmpty ? "" : " · \(chat.files.count) file name\(chat.files.count == 1 ? "" : "s") (not the files)")
        case .run(let run):
            return "\(run.ownerName)’s Mac · \(run.planDone) of \(run.plan.count) steps · \(run.changes.count) files changed"
        }
    }

    static func summarize(room: RoomState, tiles: [RoomTile]) async -> String? {
        await OpenAISettings.preload()
        guard let client = try? OpenAIClient.fromSettings() else { return nil }
        var digest = ""
        var length = 0
        for tile in tiles {
            let entry = "[\(title(of: tile)) · \(detail(of: tile))]\n\(tile.contextText(limit: 3_000))\n\n"
            length += entry.count
            if length > 40_000 { break }
            digest += entry
        }
        guard !digest.isEmpty else { return nil }
        let turns = [
            ChatTurn(role: "system", content: """
            A few people worked together on a shared canvas. Everything that was on it follows. \
            Write a summary one of them can take away: what the group was working on, what was concluded or decided, \
            and what is still open. Two short paragraphs, then a short list of next steps if there are any. \
            Keep names, numbers and file names. Plain text, no headings.
            """),
            ChatTurn(role: "user", content: digest),
        ]
        let text = try? await client.complete(turns, jsonMode: false, maxTokens: 700, timeout: 60)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func share(room: RoomState, picked: [RoomTile], summary: String?, by name: String, device: String) -> ShareSummary {
        let people = room.members.map(\.name).filter { $0 != name }
        let fallback = "Taken home from the room “\(room.name)”"
            + (people.isEmpty ? "." : " with \(people.joined(separator: ", ")).")
        var files: [String] = []
        for tile in picked {
            for file in tile.chat?.files ?? [] where !files.contains(file.name) { files.append(file.name) }
        }
        return ShareSummary(
            id: UUID(),
            title: String(room.name.prefix(60)),
            senderName: "the room “\(room.name)”",
            senderDevice: device,
            createdAt: Date(),
            summary: summary ?? fallback,
            kept: [],
            decisions: [],
            openQuestions: [],
            notes: picked.map { ShareNote(id: UUID(), title: "\(title(of: $0)) (\(detail(of: $0)))", body: $0.contextText(limit: 6_000)) },
            fileNames: files,
            transcript: nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
