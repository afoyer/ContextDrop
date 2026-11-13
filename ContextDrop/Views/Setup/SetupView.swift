import AppKit
import SwiftUI

/// The first-launch setup window: Welcome, then five steps with a sidebar.
struct SetupView: View {
    @Bindable var model: SetupModel

    static let size = CGSize(width: 860, height: 600)

    var body: some View {
        Group {
            if model.step == .welcome {
                SetupWelcome(model: model)
            } else {
                HStack(spacing: 0) {
                    SetupSidebar(model: model)
                    Divider()
                    VStack(spacing: 0) {
                        ScrollView {
                            stepContent
                                .padding(.horizontal, 36)
                                .padding(.top, 30)
                                .padding(.bottom, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        SetupFooter(model: model)
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.watchProviders() }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome: EmptyView()
        case .providers: SetupProvidersStep(model: model)
        case .shortcuts: SetupShortcutsStep(model: model)
        case .nearby: SetupNearbyStep(model: model)
        case .concepts: SetupConceptsStep()
        case .ready: SetupReadyStep(model: model)
        }
    }
}

// MARK: - Frame

private struct SetupWelcome: View {
    let model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Welcome to ContextDrop")
                    .font(.system(size: 30, weight: .bold))
                    .padding(.top, 18)
                Text("AI chat in your menu bar, and a way to hand what you worked out to the Macs around you. No server in between.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.top, 8)
                HStack(alignment: .top, spacing: 14) {
                    SetupFeature(symbol: "bubble.left", tint: .blue, title: "Ask",
                                 text: "Quick answers from OpenAI, or Claude Code and Codex working in a folder on your Mac.")
                    SetupFeature(symbol: "drop", tint: .orange, title: "Drop",
                                 text: "Turn a chat into a summary you choose, and hand it to a Mac nearby so they can pick it up.")
                    SetupFeature(symbol: "square.grid.2x2", tint: .green, title: "Room",
                                 text: "A shared canvas for people nearby: cards, chats everyone can join, and agent runs you can watch.")
                }
                .padding(.top, 34)
            }
            .padding(.horizontal, 72)
            .padding(.top, 56)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("5 short steps. Everything can be changed later in Settings.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Set Up Later") { model.later() }
                Button("Get Started") { model.next() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
    }
}

private struct SetupFeature: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupCard()
    }
}

private struct SetupSidebar: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text("ContextDrop Setup").font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.top, 40)
            .padding(.bottom, 16)
            ForEach(Array(SetupModel.Step.numbered.enumerated()), id: \.element) { index, step in
                row(step, number: index + 1)
            }
            Spacer()
            if model.step != .ready {
                Button("Set Up Later") { model.later() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup steps")
    }

    private func row(_ step: SetupModel.Step, number: Int) -> some View {
        let current = model.step == step
        let done = step.rawValue < model.step.rawValue
        return HStack(spacing: 10) {
            ZStack {
                if done {
                    Circle().fill(Color.green)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                } else if current {
                    Circle().fill(Color.accentColor)
                    Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                    Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(step.title)
                .font(.system(size: 13, weight: current ? .semibold : .regular))
                .foregroundStyle(current || done ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(current ? Color(nsColor: .controlBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number): \(step.title)\(done ? ", done" : current ? ", current" : "")")
    }
}

private struct SetupFooter: View {
    let model: SetupModel

    var body: some View {
        HStack(spacing: 10) {
            Text(hint).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Back") { model.back() }
            if model.step == .ready {
                Button("Open Quick Chat") { model.finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { model.next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 36)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    private var hint: String {
        switch model.step {
        case .welcome: ""
        case .providers: "You can skip this and add them later in Settings › Providers."
        case .shortcuts: "Tip: drop a file on the menu bar icon to ask about it."
        case .nearby: "You can skip this if you only use ContextDrop alone."
        case .concepts: "Chats are kept in memory and clear when you quit."
        case .ready: "Reopen this from Settings › General."
        }
    }
}

private struct SetupHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Step 1: Connect your AI

private struct SetupProvidersStep: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeader(title: "Connect your AI",
                        subtitle: "Use any mix. ContextDrop checks each one on this Mac and updates as soon as something changes.")
            ForEach(ProviderKind.deep) { kind in
                SetupCLICard(model: model, kind: kind)
            }
            SetupOpenAICard(model: model)
        }
    }
}

private struct SetupCLICard: View {
    let model: SetupModel
    let kind: ProviderKind

    private enum Phase { case checking, notInstalled, notSignedIn, ready, installing, signingIn, failed(String, SetupModel.Action), unavailable }

    private var phase: Phase {
        switch model.task(kind) {
        case .installing: return .installing
        case .signingIn: return .signingIn
        case .failed(let message, let action): return .failed(message, action)
        case .unavailable: return .unavailable
        case .idle: break
        }
        switch model.store.status(kind) {
        case .ready: return .ready
        case .notSignedIn: return .notSignedIn
        case .notFound: return .notInstalled
        case .checking, .missingKey: return .checking
        }
    }

    private var summary: String {
        switch kind {
        case .claudeCode: "Works in a folder on your Mac: reads files, edits with your OK, runs commands."
        default: "Works in a folder on your Mac, in a sandbox until you allow edits."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName).font(.system(size: 14, weight: .semibold))
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                action
                pill
            }
            detail
            if showsTrack {
                HStack(spacing: 6) {
                    trackStep(1, "Install", state: installState)
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 18, height: 1).accessibilityHidden(true)
                    trackStep(2, "Sign in", state: signInState)
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 18, height: 1).accessibilityHidden(true)
                    trackStep(3, "Ready", state: .upcoming)
                    Spacer()
                    Button(model.showingCommands.contains(kind) ? "Hide command" : "Prefer Terminal? Show command") {
                        if model.showingCommands.contains(kind) { model.showingCommands.remove(kind) } else { model.showingCommands.insert(kind) }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
            }
            if model.showingCommands.contains(kind), !isReady {
                SetupCommandBox(text: model.manualCommands(kind)) { model.checkAgain() }
            }
        }
        .setupCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.displayName)
    }

    private var isReady: Bool { if case .ready = phase { true } else { false } }
    private var showsTrack: Bool { if case .ready = phase { false } else if case .checking = phase { false } else { true } }

    @ViewBuilder
    private var action: some View {
        switch phase {
        case .notInstalled:
            Button("Install") { model.install(kind) }.buttonStyle(.borderedProminent)
        case .notSignedIn:
            Button("Sign In…") { model.signIn(kind) }.buttonStyle(.borderedProminent)
        case .signingIn:
            Button("Cancel") { model.cancel(kind) }
        case .failed(_, let retry):
            Button("Try Again") { model.retry(kind, retry) }
        case .unavailable:
            Button("Check Again") { model.checkAgain() }
        case .checking, .ready, .installing:
            EmptyView()
        }
    }

    @ViewBuilder
    private var pill: some View {
        switch phase {
        case .checking: SetupPill(text: "Checking…", tint: .secondary)
        case .notInstalled: SetupPill(text: "Not installed", tint: .secondary)
        case .notSignedIn: SetupPill(text: "Not signed in", tint: .orange)
        case .ready: SetupPill(text: "Ready", tint: .green)
        case .installing: SetupPill(text: "Installing…", tint: .blue)
        case .signingIn: SetupPill(text: "Signing in…", tint: .blue)
        case .failed: SetupPill(text: "Didn’t finish", tint: .red)
        case .unavailable: SetupPill(text: "Needs a tool", tint: .orange)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch phase {
        case .installing:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("Installing \(kind.displayName)")
                Text("Installing. You can keep going; we’ll ask you to sign in when it’s done.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser, then come back here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .failed(let message, _):
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
        case .unavailable:
            Text("Installing \(kind.displayName) needs Homebrew or Node. Install one of them, or run the command below in Terminal.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .checking, .notInstalled, .notSignedIn, .ready:
            EmptyView()
        }
    }

    private enum TrackState { case done, current, upcoming }

    private var installState: TrackState {
        switch phase {
        case .notInstalled, .installing, .unavailable: .current
        case .failed(_, let action): action == .install ? .current : .done
        default: .done
        }
    }

    private var signInState: TrackState {
        switch phase {
        case .notSignedIn, .signingIn: .current
        case .failed(_, let action): action == .signIn ? .current : .upcoming
        default: .upcoming
        }
    }

    private func trackStep(_ number: Int, _ label: String, state: TrackState) -> some View {
        HStack(spacing: 6) {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(Color.green)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                case .current:
                    Circle().fill(Color.accentColor)
                    Text("\(number)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                case .upcoming:
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                    Text("\(number)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(label)
                .font(.system(size: 12, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(state == .upcoming ? Color.secondary : Color.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(state == .done ? "done" : state == .current ? "current step" : "to do")")
    }
}

private struct SetupCommandBox: View {
    let text: String
    let checkAgain: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy Commands") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                Button("Check Again", action: checkAgain)
                Text("Run these in Terminal; this card updates by itself.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SetupOpenAICard: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "bolt")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .frame(width: 34, height: 34)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenAI API key").font(.system(size: 14, weight: .semibold))
                    Text("Quick answers without file access, share summaries, room chats and Auto mode.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if OpenAISettings.apiKey() != nil {
                    SetupPill(text: "Saved", tint: .green)
                } else {
                    SetupPill(text: "Optional", tint: .secondary)
                }
            }
            HStack(spacing: 8) {
                SecureField("OpenAI API key", text: $model.apiKey, prompt: Text("Paste your key (sk-…)"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveKey() }
                Button("Save Key") { model.saveKey() }
                    .disabled(model.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 4) {
                Text(model.keyMessage ?? "Kept in your Keychain, never sent to other Macs.")
                Link("Get a key", destination: URL(string: "https://platform.openai.com/api-keys")!)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .setupCard()
    }
}

// MARK: - Step 2: Shortcuts

private struct SetupShortcutsStep: View {
    @Bindable var model: SetupModel
    @AppStorage(AppDefaults.permissionLevelKey) private var permissionLevel = PermissionLevel.ask.rawValue
    @State private var folder = AppDefaults.folder

    private static let keys: [(key: String, label: String)] = [
        ("⌘T", "New chat tab"),
        ("⌃Tab", "Next chat that needs you"),
        ("⌘⇧S", "Share a chat nearby"),
        ("⌘⌥A", "Activity: steps and changes"),
        ("/", "/claude, /codex, skills and more"),
        ("⌘1–9", "Jump to a tab"),
    ]

    private var level: PermissionLevel { PermissionLevel(rawValue: permissionLevel) ?? .ask }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeader(title: "Shortcuts and defaults",
                        subtitle: "One key opens ContextDrop from any app. The rest work once it’s open.")
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Quick Chat").font(.system(size: 14, weight: .semibold))
                        Text("Works in every app. Pick a key you don’t already use.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(settings: model.shortcuts)
                }
                if let message = model.shortcuts.message {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Divider()
                Toggle("Open ContextDrop at login", isOn: $model.openAtLogin)
                    .toggleStyle(.switch)
            }
            .setupCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("KEYS TO KNOW").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(Self.keys, id: \.key) { item in
                        HStack(spacing: 10) {
                            Kbd(item.key).frame(minWidth: 48)
                            Text(item.label).font(.system(size: 12.5))
                        }
                    }
                }
            }
            .setupCard()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What coding agents may do").font(.system(size: 13, weight: .semibold))
                        Text(level.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("What coding agents may do", selection: $permissionLevel) {
                        ForEach(PermissionLevel.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default folder").font(.system(size: 13, weight: .semibold))
                        Text("Where an agent starts when you don’t name a folder.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if let chosen = FilePicker.folders(prompt: "Use Folder", message: "Choose the folder coding agents start in.").first {
                            AppDefaults.folder = chosen
                            folder = chosen
                        }
                    } label: {
                        Label(folder.map(FolderDrop.display) ?? "Choose Folder…", systemImage: "folder")
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: 200)
                    }
                }
            }
            .setupCard()
        }
    }
}

// MARK: - Step 3: Nearby Macs

private struct SetupNearbyStep: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeader(title: "Find Macs nearby",
                        subtitle: "Drops and rooms go straight between Macs over Wi-Fi or Bluetooth, encrypted. Nothing passes through a server.")
            HStack(spacing: 14) {
                AvatarView(name: model.name.isEmpty ? model.peers.localDisplayName : model.name, size: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your name").font(.system(size: 13, weight: .semibold))
                    TextField("Your name", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onSubmit { model.saveName() }
                    Text("People nearby see this when you share or join a room.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .setupCard()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "wifi")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.blue)
                        .frame(width: 34, height: 34)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow local network access").font(.system(size: 14, weight: .semibold))
                        Text(model.peers.isDiscovering
                             ? "Looking for Macs nearby. If macOS asked, click Allow."
                             : "macOS asks once. Click Allow so ContextDrop can find Macs around you.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if model.peers.isDiscovering {
                        SetupPill(text: "On", tint: .green)
                    } else {
                        Button("Allow Access…") { model.startDiscovery() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Be on the same Wi-Fi, or keep Wi-Fi and Bluetooth on.")
                    bullet("Campus and office networks sometimes block discovery. A phone hotspot works.")
                    bullet("Clicked Don’t Allow? Turn it on in System Settings › Privacy & Security › Local Network.")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .setupCard()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
                Text("Anyone nearby can pick any name. Accept drops and room invitations only from people you expect.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 4: How it works

private struct SetupConceptsStep: View {
    private static let concepts: [(symbol: String, title: String, text: String)] = [
        ("macwindow", "Quick Chat and tabs",
         "⌥Space opens a chat over any app. Its tabs are the same as the workspace window’s, so nothing gets lost."),
        ("chevron.left.forwardslash.chevron.right", "Quick answers or agents",
         "OpenAI answers fast without touching files. Claude Code and Codex work in a folder. Auto mode picks for you."),
        ("lock", "Permission levels",
         "Each chat has one, from Read-only to Auto-approve. Every edit shows as a diff you can review."),
        ("drop", "Drops",
         "⌘⇧S turns a chat into a summary you check, then hands it to a Mac nearby. They press Continue and carry on."),
        ("square.grid.2x2", "Rooms",
         "A shared canvas for people nearby: cards, chats anyone can join, and runs to watch. It lasts while its host stays."),
        ("person.2", "Chats talk, runs act",
         "A room chat talks. A run acts, on its owner’s Mac only. Others can ask to continue it; the owner decides."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeader(title: "How ContextDrop works", subtitle: "Six ideas cover the whole app.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Self.concepts, id: \.title) { concept in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: concept.symbol).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                            Text(concept.title).font(.system(size: 13.5, weight: .semibold))
                        }
                        Text(concept.text).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                    .setupCard(padding: 12)
                }
            }
        }
    }
}

// MARK: - Step 5: Ready

private struct SetupReadyStep: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeader(title: "You’re set",
                        subtitle: "ContextDrop lives in your menu bar. It shows what needs you, what’s running and what arrived.")
            VStack(spacing: 0) {
                ForEach(ProviderKind.deep) { kind in
                    let status = model.store.status(kind)
                    summaryRow(kind.displayName, ok: status.isReady,
                               value: status.isReady ? "Ready · signed in" : status.detail)
                    Divider()
                }
                summaryRow("OpenAI", ok: OpenAISettings.apiKey() != nil,
                           value: OpenAISettings.apiKey() != nil ? "Key saved" : "No key: quick answers and room chats are off")
                Divider()
                HStack(spacing: 10) {
                    dot(true)
                    Text("Quick Chat").font(.system(size: 13))
                    Spacer()
                    Kbd(model.shortcuts.shortcut.display)
                }
                .frame(height: 38)
                Divider()
                summaryRow("Nearby Macs", ok: model.peers.isDiscovering,
                           value: model.peers.isDiscovering ? "Visible as \(model.peers.localDisplayName)" : "Off until you allow it")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))

            Text("TRY ONE").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                tryCard("/claude", "Pick a project and ask “What does this repo do?”", tint: .blue)
                tryCard("Drop a file", "Drag one onto the menu bar icon to ask about it.", tint: .orange)
                tryCard("Open a room", "Invite someone nearby and think on one canvas.", tint: .green)
            }
        }
    }

    private func summaryRow(_ title: String, ok: Bool, value: String) -> some View {
        HStack(spacing: 10) {
            dot(ok)
            Text(title).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(ok ? Color.green : Color.secondary).lineLimit(1)
        }
        .frame(height: 38)
        .accessibilityElement(children: .combine)
    }

    private func dot(_ ok: Bool) -> some View {
        Circle().fill(ok ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8).accessibilityHidden(true)
    }

    private func tryCard(_ title: String, _ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupCard(padding: 12)
    }
}

// MARK: - Pieces

private struct SetupPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background((tint == .secondary ? Color.primary : tint).opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

private extension View {
    func setupCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}
