import SwiftUI

/// Board 3: choose someone nearby, watch the drop, then the check.
struct NearbySendView: View {
    @Bindable var model: PanelModel
    let conversationID: UUID
    let share: ShareSummary

    @Namespace private var dropSpace
    @State private var selection = 0
    @State private var appeared: Set<MCPeerKey> = []
    @State private var ringProgress: CGFloat = 0
    @State private var airDropAnchor = ViewAnchor()
    @FocusState private var focused: Bool

    private var peers: [NearbyPeer] { model.peers.nearbyPeers }
    private var outgoing: OutgoingTransfer? { model.peers.outgoing }
    private var reduce: Bool { model.reduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            if let outgoing, outgoing.phase == .declined || outgoing.phase == .failed {
                declinedCard(outgoing)
                    .transition(Motion.pop(reduce))
            } else {
                grid
            }
            HairlineDivider()
            footer
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onChange(of: outgoing?.phase) { _, phase in
            switch phase {
            case .waiting?:
                ringProgress = 0.08
                withAnimation(.linear(duration: PeerService.invitationTimeout)) { ringProgress = 1 }
            case .sending?:
                withAnimation(.easeOut(duration: 0.3)) { ringProgress = max(ringProgress, 0.92) }
            case .delivered?:
                model.deliveryConfirmed()
            default:
                break
            }
        }
    }

    // MARK: Header (summary thumbnail lifts out of here)

    private var header: some View {
        HStack(spacing: 12) {
            if outgoing == nil || reduce {
                Thumbnail()
                    .matchedGeometryEffect(id: "thumb", in: dropSpace, isSource: outgoing == nil)
                    .opacity(outgoing == nil ? 1 : 0)
            } else {
                RoundedRectangle(cornerRadius: 5).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.tertiary).frame(width: 34, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    private var headerTitle: String {
        let extra = model.extraShareCount
        guard let outgoing else { return extra > 0 ? "\(share.title) + \(extra) more tab\(extra == 1 ? "" : "s")" : share.title }
        switch outgoing.phase {
        case .waiting, .sending: return "Sending to \(outgoing.peerName)…"
        case .delivered: return extra > 0 ? "\(outgoing.peerName) has your \(extra + 1) tabs" : "\(outgoing.peerName) is continuing your chat"
        case .declined: return "\(outgoing.peerName) didn’t accept"
        case .failed: return "Couldn’t reach \(outgoing.peerName)"
        }
    }

    private var headerSubtitle: String {
        guard let outgoing else { return share.countsLine }
        switch outgoing.phase {
        case .waiting: return "Waiting for them to accept"
        case .sending: return "Sending the summary…"
        case .delivered: return "They have the summary and your kept items"
        case .declined, .failed: return "Nothing was saved on their Mac"
        }
    }

    // MARK: People

    private var grid: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 14) {
                ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                    personTile(peer, index: index)
                }
                lookingTile
            }
            .padding(.horizontal, 12)
            .padding(.top, 22)
            .padding(.bottom, 12)
            if peers.isEmpty {
                Text("No one nearby is running ContextDrop. Use AirDrop… to send the file instead.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            } else if outgoing?.phase == .waiting || outgoing?.phase == .sending {
                HStack {
                    Text("You can close this panel; sending continues.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.peers.cancelSend() }.controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }

    private func personTile(_ peer: NearbyPeer, index: Int) -> some View {
        let isTarget = outgoing?.peerID == peer.peerID
        let dimmed = outgoing != nil && !isTarget
        let selected = outgoing == nil && index == selection
        let key = MCPeerKey(peer)
        return Button {
            selection = index
            model.send(to: peer)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 3) }
                    if isTarget, let phase = outgoing?.phase {
                        if phase == .delivered {
                            Circle().fill(Color.green).frame(width: 30, height: 30)
                                .overlay(Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(.white))
                                .offset(x: 24, y: 24)
                                .transition(Motion.pop(reduce))
                                .zIndex(2)
                        } else {
                            Circle().stroke(Color.accentColor.opacity(0.18), lineWidth: 3)
                            Circle().trim(from: 0, to: ringProgress)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                    }
                    AvatarView(name: peer.name, size: 60)
                    if isTarget, outgoing?.phase == .waiting || outgoing?.phase == .sending {
                        Thumbnail(small: true)
                            .rotationEffect(.degrees(reduce ? 0 : 8))
                            .matchedGeometryEffect(id: "thumb", in: dropSpace, isSource: outgoing != nil)
                            .offset(x: 26, y: 24)
                            .transition(.opacity)
                    }
                }
                .frame(width: 72, height: 72)
                Text(peer.name).font(.system(size: 13, weight: isTarget || selected ? .semibold : .regular)).lineLimit(1)
                Text(isTarget && outgoing?.phase == .waiting ? "Waiting…" : peer.device)
                    .font(.system(size: 11))
                    .foregroundStyle(isTarget && outgoing?.phase == .waiting ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(outgoing != nil)
        .opacity(dimmed ? 0.4 : 1)
        .scaleEffect(appeared.contains(key) || reduce ? 1 : 0.9)
        .opacity(appeared.contains(key) ? 1 : 0)
        .onAppear {
            withAnimation(Motion.peopleAppear(reduce, index: index)) { _ = appeared.insert(key) }
        }
        .animation(Motion.drop(reduce), value: outgoing?.phase)
    }

    private var lookingTile: some View {
        VStack(spacing: 5) {
            Circle().fill(.quaternary.opacity(0.5)).frame(width: 60, height: 60)
                .overlay(ProgressView().controlSize(.small))
                .frame(width: 72, height: 72)
            Text("Looking…").font(.system(size: 13)).foregroundStyle(.secondary)
            Text(" ").font(.system(size: 11))
        }
        .opacity(outgoing == nil ? 1 : 0.4)
    }

    private func declinedCard(_ outgoing: OutgoingTransfer) -> some View {
        HStack(spacing: 14) {
            AvatarView(name: outgoing.peerName, size: 36).opacity(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(outgoing.phase == .declined ? "\(outgoing.peerName) didn’t accept" : "\(outgoing.peerName) is out of range")
                    .font(.system(size: 13, weight: .semibold))
                Text("Nothing was saved on their Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose someone else") { model.chooseSomeoneElse() }.controlSize(.small)
        }
        .padding(18)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if peers.isEmpty {
                Button { airDrop() } label: { Label("AirDrop…", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { airDrop() } label: { Label("AirDrop…", systemImage: "dot.radiowaves.left.and.right") }
            }
            Button { sharePicker() } label: { HStack(spacing: 4) { Image(systemName: "square.and.arrow.up"); Text("Share"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) } }
                .background(AnchorReader(anchor: airDropAnchor))
                .accessibilityLabel("More ways to share")
            Spacer()
            if outgoing == nil && !peers.isEmpty { Text("↵ send").font(.system(size: 12)).foregroundStyle(.secondary) }
            Kbd("esc")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private func airDrop() {
        do { try ShareFile.airDrop(share) } catch { model.peers.notice = "AirDrop isn’t available on this Mac." }
    }

    private func sharePicker() {
        guard let view = airDropAnchor.view else { return }
        do { try ShareFile.showPicker(share, relativeTo: view) } catch { model.peers.notice = "Couldn’t prepare the share file." }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape: model.escape(); return .handled
        case .leftArrow, .upArrow:
            if !peers.isEmpty { selection = max(0, selection - 1) }; return .handled
        case .rightArrow, .downArrow:
            if !peers.isEmpty { selection = min(peers.count - 1, selection + 1) }; return .handled
        case .return:
            if outgoing == nil, peers.indices.contains(selection) { model.send(to: peers[selection]) }
            return .handled
        default: return .ignored
        }
    }
}

/// Hashable key for an MCPeerID in SwiftUI state.
struct MCPeerKey: Hashable {
    let raw: Int
    init(_ peer: NearbyPeer) { raw = peer.peerID.hash }
}

/// Little "document" standing for the summary package.
struct Thumbnail: View {
    var small = false

    var body: some View {
        VStack(alignment: .leading, spacing: small ? 2 : 3) {
            Capsule().fill(Color.accentColor).frame(height: small ? 2 : 3)
            Capsule().fill(Color.secondary.opacity(0.4)).frame(height: small ? 2 : 3)
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: small ? 10 : 18, height: small ? 2 : 3)
        }
        .padding(.horizontal, small ? 3 : 5)
        .padding(.vertical, small ? 4 : 6)
        .frame(width: small ? 22 : 34, height: small ? 26 : 40, alignment: .top)
        .background(.background, in: RoundedRectangle(cornerRadius: small ? 3 : 5))
        .overlay(RoundedRectangle(cornerRadius: small ? 3 : 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
    }
}
