import SwiftUI
import OvertureDesign
import OvertureKit
import ClaudeKit
import ProcessCore

@main
struct OvertureApp: App {
    @State private var appState = try? AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ThemeResolver {
                if let appState {
                    RootView()
                        .environment(appState)
                } else {
                    ContentUnavailableView(
                        "Could not open the Overture store",
                        systemImage: DS.Icon.error)
                }
            }
            .frame(minWidth: 960, minHeight: 620)
            .background(DS.Color.Surface.canvas)
        }

        Settings {
            if let appState {
                SettingsView().environment(appState)
            }
        }

        MenuBarExtra("Overture", systemImage: "square.grid.3x3") {
            if let appState {
                MenuBarView().environment(appState)
            }
        }
        .menuBarExtraStyle(.window)
    }

}

/// Quit flow (resolution #7): with agents running, offer Interrupt & Quit
/// (≤10 s grace) or Cancel; dev servers always stop — nothing survives quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    weak var state: AppState?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        let liveCount = state.coordinator.live.values.filter {
            $0.activity == .working || $0.activity == .needsInput
        }.count
        if liveCount > 0 {
            let alert = NSAlert()
            alert.messageText = liveCount == 1
                ? "An agent is still running"
                : "\(liveCount) agents are still running"
            alert.informativeText = "Overture will interrupt them cleanly; "
                + "every session can be resumed later from its card."
            alert.addButton(withTitle: "Interrupt & Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn {
                return .terminateCancel
            }
        }
        Task {
            _ = await state.services.processManager.interruptAndQuit()
            await state.devServers.stopAll()
            await MainActor.run {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

/// Root composition: services + stores, built once.
@MainActor
@Observable
final class AppState {
    let services: AppServices
    let coordinator: SessionCoordinator
    let projectsStore: ProjectsStore
    var navigationPath = NavigationPath()
    /// Card a notification/menu-bar click wants opened (BoardView consumes).
    var pendingCardFocus: UUID?
    var notificationManager: NotificationManager?
    let devServers = DevServerManager()

    init() throws {
        services = try AppServices()
        coordinator = SessionCoordinator(services: services)
        projectsStore = ProjectsStore(services: services)
        enableNotifications()
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var onboardingDone = false

    var body: some View {
        @Bindable var appState = appState
        NavigationStack(path: $appState.navigationPath) {
            HomeView()
                .navigationDestination(for: Project.ID.self) { projectID in
                    if let project = appState.projectsStore.projects
                        .first(where: { $0.id == projectID }) {
                        BoardView(store: BoardStore(
                            project: project,
                            services: appState.services,
                            coordinator: appState.coordinator))
                    }
                }
        }
        .task {
            AppDelegate.shared?.state = appState
            await appState.services.runOnboarding()
            _ = await appState.services.reconcileOrphans()
            onboardingDone = true
        }
        .sheet(isPresented: .constant(needsOnboardingSheet)) {
            OnboardingView()
        }
    }

    private var needsOnboardingSheet: Bool {
        guard onboardingDone else { return false }
        if case .ready = appState.services.onboarding { return false }
        return true
    }
}

/// First-run checklist (resolution #12): each failure is specific and
/// actionable; the sheet re-probes on demand.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s400) {
            Text("Welcome to Overture")
                .font(DS.TypeStyle.screenTitle)
            Text("Overture drives your own Claude Code CLI. One check first:")
                .font(DS.TypeStyle.emptyStateBody)
                .foregroundStyle(DS.Color.Text.secondary)

            switch appState.services.onboarding {
            case .binaryMissing(let searched):
                checklistRow(icon: DS.Icon.error, tint: DS.Status.danger,
                             title: "Claude Code not found",
                             detail: "Install it (brew install claude-code), "
                                + "then retry. Searched: "
                                + searched.joined(separator: ", "))
            case .versionBelowMinimum(let found):
                checklistRow(icon: DS.Icon.error, tint: DS.Status.danger,
                             title: "Claude Code \(found) is too old",
                             detail: "Overture needs \(OnboardingMinimum.text)+."
                                + " Update with: brew upgrade claude-code")
            case .versionUnreadable:
                checklistRow(icon: DS.Icon.error, tint: DS.Status.caution,
                             title: "Could not read the CLI version",
                             detail: "Run `claude --version` in a terminal to "
                                + "check the installation.")
            case .notAuthenticated:
                checklistRow(icon: DS.Icon.awaitingPermission,
                             tint: DS.Status.caution,
                             title: "Claude Code isn’t signed in",
                             detail: "Sign in below — your browser opens on "
                                + "Anthropic’s login page and the CLI stores "
                                + "the credentials. Overture never sees them.")
                SignInSection()
            case .ready, .none:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Retry") {
                    Task { await appState.services.runOnboarding() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s600)
        .frame(width: 480)
        .background(DS.Color.Surface.overlay)
    }

    private func checklistRow(icon: String, tint: DS.StatusColor,
                              title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s300) {
            Image(systemName: icon)
                .foregroundStyle(tint.text)
            VStack(alignment: .leading, spacing: DS.Space.s100) {
                Text(title).font(DS.TypeStyle.cardTitle)
                Text(detail)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(DS.Space.s300)
        .background(tint.tint, in: RoundedRectangle(
            cornerRadius: DS.Radius.panel))
    }
}

enum OnboardingMinimum {
    static let text = "2.1.231"
}

/// App-initiated `claude auth login` (see AuthLogin): relays CLI output and
/// forwards the confirmation code if the flow asks for one.
struct SignInSection: View {
    @Environment(AppState.self) private var appState
    @State private var login: AuthLogin?
    @State private var output: [String] = []
    @State private var code = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s300) {
            if running {
                ScrollView {
                    Text(output.suffix(12).joined(separator: "\n"))
                        .font(DS.TypeStyle.code)
                        .foregroundStyle(DS.Color.Text.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 96)
                .padding(DS.Space.s200)
                .background(DS.Color.Surface.sunken,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                HStack {
                    TextField("Paste the confirmation code here if asked",
                              text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.TypeStyle.code)
                        .onSubmit(submitCode)
                    Button("Submit") { submitCode() }
                        .disabled(code.isEmpty)
                    Button("Cancel", role: .cancel) {
                        Task { await login?.cancel() }
                        running = false
                    }
                }
            } else {
                HStack {
                    Button("Sign In with Claude") { start(.subscription) }
                        .buttonStyle(.borderedProminent)
                    Button("Use API Console instead") { start(.console) }
                }
            }
        }
    }

    private func start(_ mode: AuthLogin.Mode) {
        guard let claudeURL = claudeExecutable() else { return }
        let flow = AuthLogin()
        login = flow
        output = []
        running = true
        Task {
            guard let events = try? await flow.start(claudeURL: claudeURL,
                                                     mode: mode) else {
                running = false
                return
            }
            for await event in events {
                switch event {
                case .outputLine(let line):
                    output.append(line)
                case .finished:
                    running = false
                    await appState.services.runOnboarding()
                }
            }
        }
    }

    private func submitCode() {
        let text = code
        code = ""
        Task { await login?.submit(text) }
    }

    /// Auth probing can fail before onboarding resolves a URL — rediscover.
    private func claudeExecutable() -> URL? {
        if let url = appState.services.claudeURL { return url }
        return HostEnvironment.claudeCandidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            let entries = appState.coordinator.live.compactMap {
                (id, state) -> (Card, SessionCoordinator.LiveState)? in
                guard state.activity == .working
                    || state.activity == .needsInput,
                    let card = appState.card(id) else { return nil }
                return (card, state)
            }
            if entries.isEmpty {
                Text("No agents running")
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
            } else {
                ForEach(entries, id: \.0.id) { card, state in
                    Button {
                        appState.focusCard(card.id)
                    } label: {
                        HStack(spacing: DS.Space.s200) {
                            Image(systemName: state.activity == .needsInput
                                  ? DS.Icon.awaitingPermission
                                  : DS.Icon.sparkles)
                                .foregroundStyle(
                                    state.activity == .needsInput
                                    ? DS.Status.caution.text
                                    : DS.Color.Accent.text)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(card.title)
                                    .font(DS.TypeStyle.cardMeta)
                                    .foregroundStyle(DS.Color.Text.primary)
                                    .lineLimit(1)
                                Text(card.project?.name ?? "")
                                    .font(DS.TypeStyle.timestamp)
                                    .foregroundStyle(DS.Color.Text.tertiary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(DS.Space.s400)
        .frame(minWidth: 260)
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("CLI") {
                    Text(appState.services.claudeURL?.path ?? "not found")
                        .font(DS.TypeStyle.code)
                }
                if let auth = appState.services.authStatus {
                    LabeledContent("Account") {
                        Text(auth.email ?? "signed in")
                    }
                    LabeledContent("Billing") {
                        Text(auth.isSubscription
                             ? "Subscription (\(auth.subscriptionType ?? ""))"
                             : "API key")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 280)
    }
}
