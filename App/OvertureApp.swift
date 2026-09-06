import SwiftUI
import Sparkle
import OvertureDesign
import OvertureKit
import ClaudeKit
import ProcessCore

@main
struct OvertureApp: App {
    @State private var appState = try? AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Sparkle. Automatic checks are disabled via Info.plist until the
    /// first release ships a real appcast; manual checks work now.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
            .frame(minWidth: DS.Layout.windowMinWidth,
                   minHeight: DS.Layout.windowMinHeight)
            .background(DS.Color.Surface.canvas)
        }
        .commands {
            CheckForUpdatesCommand(updater: updater.updater)
            CommandGroup(after: .toolbar) {
                Button("Jump to Card or Project…") {
                    appState?.showCommandPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            if let appState {
                SettingsView().environment(appState)
            }
        }

        MenuBarExtra("Overture", systemImage: DS.Icon.project) {
            if let appState {
                MenuBarView().environment(appState)
            }
        }
        .menuBarExtraStyle(.window)
    }

}

struct CheckForUpdatesCommand: Commands {
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
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
    var showCommandPalette = false
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
    @Environment(\.overtureTheme) private var theme
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
            await appState.services.refreshClaude(reason: .launch)
            _ = await appState.services.reconcileOrphans()
            appState.services.autoArchiveDoneCards()
            onboardingDone = true
        }
        .sheet(isPresented: .constant(needsOnboardingSheet)) {
            OnboardingView()
        }
        .overlay {
            if appState.showCommandPalette {
                ZStack(alignment: .top) {
                    DS.Color.Text.primary.opacity(DS.Opacity.scrim)
                        .ignoresSafeArea()
                        .onTapGesture { appState.showCommandPalette = false }
                        .accessibilityHidden(true)
                    CommandPalette()
                        .padding(.top, DS.Space.s1600)
                }
                .transition(.opacity)
            }
        }
        // The toggle comes from a menu command, not a `withAnimation`
        // block; without this the `.opacity` transition never runs.
        .animation(DS.Motion.fade, value: appState.showCommandPalette)
    }

    private var needsOnboardingSheet: Bool {
        guard onboardingDone else { return false }
        return appState.services.claude?.canSpawn != true
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

            checklist

            HStack {
                Spacer()
                Button("Retry") {
                    Task { await appState.services.refreshClaude(reason: .manual) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s600)
        .frame(width: DS.Layout.Sheet.narrow)
        .background(DS.Color.Surface.overlay)
    }

    /// Resolution #12, on the two-axis model: the CLI row and the sign-in row
    /// are independent, so a signed-out user still sees where their CLI is.
    @ViewBuilder private var checklist: some View {
        if let readiness = appState.services.claude {
            switch readiness.cli.installation {
            case .missing(let searched):
                checklistRow(icon: DS.Icon.error, tint: DS.Status.danger,
                             title: "Claude Code not found",
                             detail: "Install it with `brew install --cask "
                                + "claude-code`, then check again. Searched: "
                                + searched.joined(separator: ", "))
            case .found(let url):
                cliVersionRow(readiness.cli, path: url.path)
            }

            if readiness.cli.isUsable {
                authRow(readiness.auth)
            }
            credentialRow(readiness)
        } else {
            checklistRow(icon: DS.Icon.idle, tint: DS.Status.neutral,
                         title: "Checking your Claude Code setup…",
                         detail: "Looking for the CLI and asking who it is "
                            + "signed in as.")
        }
    }

    @ViewBuilder
    private func cliVersionRow(_ cli: CLIStatus, path: String) -> some View {
        switch cli.version {
        case .belowMinimum(let found):
            checklistRow(
                icon: DS.Icon.error, tint: DS.Status.danger,
                title: "Claude Code \(found) is too old",
                detail: "Overture is tested against "
                    + "\(ClaudeEnvironmentCheck.minimumTestedVersion) and newer. "
                    + "Update with `brew upgrade --cask claude-code`.")
        case .unreadable:
            checklistRow(
                icon: DS.Icon.error, tint: DS.Status.caution,
                title: "Could not read the CLI version",
                detail: "Run `claude --version` in a terminal to check the "
                    + "installation at \(path).")
        case .untested(let found):
            // Newer than tested warns, never blocks (spec 01 §7.1).
            checklistRow(
                icon: DS.Icon.info, tint: DS.Status.caution,
                title: "Claude Code \(found)",
                detail: "Newer than the version Overture is tested against "
                    + "(\(ClaudeEnvironmentCheck.minimumTestedVersion)). This "
                    + "should be fine — please report anything that looks off.")
        case .supported(let found):
            checklistRow(icon: DS.Icon.finished, tint: DS.Status.success,
                         title: "Claude Code \(found)", detail: path)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func authRow(_ auth: AuthState) -> some View {
        switch auth {
        case .signedIn(let account):
            checklistRow(
                icon: DS.Icon.finished, tint: DS.Status.success,
                title: account.email ?? account.authMethod.displayName,
                detail: account.isIdentityless
                    ? "Claude Code didn't report an account for this credential."
                    : [account.orgName, account.subscriptionType]
                        .compactMap { $0 }.joined(separator: " · "))
        case .signedOut:
            checklistRow(
                icon: DS.Icon.awaitingPermission, tint: DS.Status.caution,
                title: "Claude Code isn't signed in",
                detail: "Sign in below. Your browser opens Anthropic's login "
                    + "page and the CLI stores the credentials — Overture "
                    + "never sees them.")
            SignInSection()
        case .blockedByPolicy(let method):
            checklistRow(
                icon: DS.Icon.error, tint: DS.Status.caution,
                title: "Your organization manages this sign-in",
                detail: ClaudeAccount(loggedIn: false,
                                      forcedLoginMethod: method)
                    .policyExplanation ?? "Sign in from a terminal.")
        case .probeFailed(let failure):
            checklistRow(
                icon: DS.Icon.error, tint: DS.Status.danger,
                title: "Couldn't ask the CLI who's signed in",
                detail: failure.summary
                    + (failure.stderrTail.isEmpty ? ""
                       : "\n" + failure.stderrTail.suffix(3).joined(separator: "\n")))
        }
    }

    /// Shown only when it changes what the user should expect — an
    /// environment credential outranking their login, or a shell that
    /// defines credentials Overture cannot see.
    @ViewBuilder
    private func credentialRow(_ readiness: ClaudeReadiness) -> some View {
        if let credential = readiness.effectiveCredential,
           credential.overridesReportedLogin {
            checklistRow(icon: DS.Icon.info, tint: DS.Status.caution,
                         title: "Check which credential your agents will use",
                         detail: credential.explanation)
        }
        if let divergence = readiness.shellDivergence, divergence.hasDivergence {
            checklistRow(
                icon: DS.Icon.info, tint: DS.Status.neutral,
                title: "Your login shell defines credentials Overture can't see",
                detail: divergence.names.map(\.rawValue)
                    .joined(separator: ", ")
                    + " — `claude` in Terminal and agents in Overture may use "
                    + "different credentials.")
        }
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
                .frame(height: DS.Layout.consoleHeight)
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
                    .keyboardShortcut(.cancelAction)
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
        guard let claudeURL = appState.services.claudeURL else { return }
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
                    await appState.services.refreshClaude(reason: .afterSignIn)
                }
            }
        }
    }

    private func submitCode() {
        let text = code
        code = ""
        Task { await login?.submit(text) }
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
                            VStack(alignment: .leading,
                                   spacing: DS.Space.s050) {
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
        .frame(minWidth: DS.Layout.menuMinWidth)
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
                        .textSelection(.enabled)
                }
                if let version = appState.services.claude?.cli.version?.semantic {
                    LabeledContent("Version") { Text(version.description) }
                }
                if let account = appState.services.account {
                    LabeledContent("Signed in as") {
                        Text(account.email ?? account.authMethod.displayName)
                    }
                    if let organization = account.orgName {
                        LabeledContent("Organization") { Text(organization) }
                    }
                    LabeledContent("Plan") {
                        Text(account.subscriptionType
                             ?? account.apiProvider.displayName)
                    }
                }
            }

            // The honest row: which credential the app's own agents will use.
            // `claude auth status` alone can't answer this, because an
            // environment credential outranks the login it reports.
            if let credential = appState.services.claude?.effectiveCredential {
                Section("Effective credential") {
                    LabeledContent("Agents will use") {
                        Text(credential.explanation)
                            .multilineTextAlignment(.trailing)
                    }
                    if credential.overridesReportedLogin {
                        Label("This overrides the account signed in above.",
                              systemImage: DS.Icon.error)
                            .font(DS.TypeStyle.cardMeta)
                            .foregroundStyle(DS.Status.caution.text)
                    }
                    if !credential.evidence.isEmpty {
                        LabeledContent("From") {
                            Text(credential.evidence.map(\.rawValue)
                                    .joined(separator: ", "))
                                .font(DS.TypeStyle.code)
                        }
                    }
                }
            }

            Section {
                Button("Check Again") {
                    Task { await appState.services.refreshClaude(reason: .manual) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: DS.Layout.Sheet.narrow, height: 380)
        .task { await appState.services.refreshClaude(reason: .becameActive) }
    }
}
