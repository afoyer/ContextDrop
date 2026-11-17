import Foundation
import Observation

/// The first-launch setup window's state: which step is shown, and the installs and sign-ins it started.
/// Every choice is written to the same settings Settings uses, so the two never disagree.
@MainActor
@Observable
final class SetupModel {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, providers, shortcuts, nearby, concepts, ready

        var id: Int { rawValue }

        /// The steps listed in the sidebar (Welcome has none).
        static let numbered: [Step] = [.providers, .shortcuts, .nearby, .concepts, .ready]

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .providers: "Connect your AI"
            case .shortcuts: "Shortcuts"
            case .nearby: "Nearby Macs"
            case .concepts: "How it works"
            case .ready: "Ready"
            }
        }
    }

    /// What setup is doing for one coding CLI.
    enum Task: Equatable {
        case idle
        case installing
        case signingIn
        case failed(String, retry: Action)
        /// No way to install it from here (Codex without Homebrew or npm).
        case unavailable
    }

    enum Action: Equatable { case install, signIn }

    let store: ChatStore
    let shortcuts: ShortcutSettings

    var step: Step = .welcome
    private(set) var tasks: [ProviderKind: Task] = [:]
    /// Cards showing the Terminal commands.
    var showingCommands: Set<ProviderKind> = []
    var apiKey = ""
    private(set) var keyMessage: String?
    var openAtLogin = true
    var name = ""

    /// Set Up Later, or the window's close button before finishing.
    @ObservationIgnored var onLater: () -> Void = {}
    /// Open Quick Chat on the last step.
    @ObservationIgnored var onFinish: () -> Void = {}
    /// Allow Access… on Nearby Macs: start looking for Macs, which makes macOS ask for Local Network access.
    @ObservationIgnored var onStartDiscovery: () -> Void = {}

    @ObservationIgnored private var jobs: [ProviderKind: SetupJob] = [:]

    init(store: ChatStore, shortcuts: ShortcutSettings) {
        self.store = store
        self.shortcuts = shortcuts
    }

    var peers: PeerService { store.peers }

    /// Opening the window again starts from the top with fresh values.
    func reset() {
        step = .welcome
        name = peers.localDisplayName
        apiKey = ""
        keyMessage = nil
        openAtLogin = LoginItem.isEnabled || !AppDefaults.didFinishSetup
        showingCommands = []
        tasks = tasks.filter { $0.value == .installing || $0.value == .signingIn }
        Swift.Task { await CLIRunner.resetLoginPATH(); store.refreshProviderStatus() }
    }

    // MARK: Navigation

    func next() {
        leaving(step)
        if let following = Step(rawValue: step.rawValue + 1) { step = following }
    }

    func back() {
        leaving(step)
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    func finish() {
        leaving(step)
        if LoginItem.isEnabled != openAtLogin, let problem = LoginItem.set(openAtLogin) {
            store.notices.text = "Couldn’t change Open at Login: \(problem)"
        }
        AppDefaults.didFinishSetup = true
        AppDefaults.setupDeferred = false
        onFinish()
    }

    func later() {
        leaving(step)
        if !AppDefaults.didFinishSetup { AppDefaults.setupDeferred = true }
        onLater()
    }

    private func leaving(_ step: Step) {
        if step == .nearby { saveName() }
    }

    // MARK: Coding CLIs

    func task(_ kind: ProviderKind) -> Task { tasks[kind] ?? .idle }

    var isBusy: Bool { tasks.values.contains { $0 == .installing || $0 == .signingIn } }

    func install(_ kind: ProviderKind) {
        guard let agent = CLISetup.agent(for: kind), !isBusy(kind) else { return }
        let job = SetupJob()
        jobs[kind] = job
        tasks[kind] = .installing
        Swift.Task {
            let outcome = await CLISetup.install(agent, job: job)
            finished(kind, outcome, action: .install)
            // Installed and found: go straight on to signing in, as the card promised.
            if outcome == .done {
                store.refreshProviderStatus()
                if case .notSignedIn = await CLIRunner.status(of: agent) { signIn(kind) }
            }
        }
    }

    func signIn(_ kind: ProviderKind) {
        guard let agent = CLISetup.agent(for: kind), !isBusy(kind) else { return }
        let job = SetupJob()
        jobs[kind] = job
        tasks[kind] = .signingIn
        Swift.Task {
            let outcome = await CLISetup.signIn(agent, job: job)
            finished(kind, outcome, action: .signIn)
            store.refreshProviderStatus()
        }
    }

    func cancel(_ kind: ProviderKind) {
        jobs[kind]?.cancel()
    }

    func retry(_ kind: ProviderKind, _ action: Action) {
        tasks[kind] = .idle
        switch action {
        case .install: install(kind)
        case .signIn: signIn(kind)
        }
    }

    func manualCommands(_ kind: ProviderKind) -> String {
        CLISetup.agent(for: kind).map(CLISetup.manualCommands(for:)) ?? ""
    }

    func checkAgain() {
        Swift.Task {
            await CLIRunner.resetLoginPATH()
            store.refreshProviderStatus()
        }
    }

    private func isBusy(_ kind: ProviderKind) -> Bool {
        task(kind) == .installing || task(kind) == .signingIn
    }

    private func finished(_ kind: ProviderKind, _ outcome: CLISetup.Outcome, action: Action) {
        jobs[kind] = nil
        switch outcome {
        case .done, .cancelled: tasks[kind] = .idle
        case .failed(let message):
            tasks[kind] = .failed(message, retry: action)
            showingCommands.insert(kind)
        case .unavailable:
            tasks[kind] = .unavailable
            showingCommands.insert(kind)
        }
    }

    /// While the window is open, picks up a CLI installed or signed in from Terminal.
    func watchProviders() async {
        while !Swift.Task.isCancelled {
            try? await Swift.Task.sleep(for: .seconds(3))
            guard !Swift.Task.isCancelled else { return }
            let watching = step == .providers || step == .ready
            let missing = ProviderKind.deep.contains { !store.status($0).isReady }
            if watching, missing, !isBusy { store.refreshProviderStatus() }
        }
    }

    // MARK: OpenAI

    func saveKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyMessage = OpenAISettings.store(key) ? "Saved in your Keychain." : "Couldn’t save to the Keychain."
        apiKey = ""
        store.refreshProviderStatus()
    }

    // MARK: Nearby

    func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != peers.localDisplayName else { return }
        peers.updateDisplayName(trimmed)
        name = peers.localDisplayName
    }

    func startDiscovery() {
        saveName()
        onStartDiscovery()
    }
}
