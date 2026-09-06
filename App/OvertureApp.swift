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
    @State private var setupChecked = false
    @State private var dismissedSetup = false

    var body: some View {
        @Bindable var appState = appState
        Group {
            if !setupChecked {
                // No flash of an empty board before the first probe lands.
                CheckingView()
            } else if appState.services.claude?.canSpawn != true, !dismissedSetup {
                // A full window, not a modal: ⌘, still reaches Settings and
                // the menu bar stays live, so this is a gate and never a trap.
                WelcomeView(dismissed: $dismissedSetup)
            } else {
                board
            }
        }
        .task {
            AppDelegate.shared?.state = appState
            await appState.services.refreshClaude(reason: .launch)
            _ = await appState.services.reconcileOrphans()
            appState.services.autoArchiveDoneCards()
            setupChecked = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // Recovery without a click: install the CLI or sign in from a
            // terminal, ⌘-tab back, and the screen resolves itself.
            Task { await appState.services.refreshClaude(reason: .becameActive) }
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

    @ViewBuilder private var board: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            // Re-entry after "Continue Without Signing In", and the landing
            // place when a running agent's credential dies (spec 01 §7.4).
            if appState.services.claude?.canSpawn != true
                || appState.services.authInterrupted {
                setupBanner
            }
            navigation
        }
    }

    private var setupBanner: some View {
        HStack(spacing: DS.Space.s300) {
            Image(systemName: DS.Icon.awaitingPermission)
                .foregroundStyle(DS.Status.caution.text)
            Text(appState.services.authInterrupted
                 ? "Claude Code could not authenticate. Agents are stopped "
                    + "until you sign in again."
                 : "Claude Code isn't ready. Agents can't run until it is.")
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Color.Text.primary)
            Spacer()
            Button("Set Up\u{2026}") { dismissedSetup = false }
        }
        .padding(.horizontal, DS.Space.s400)
        .padding(.vertical, DS.Space.s300)
        .background(DS.Status.caution.tint)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var navigation: some View {
        @Bindable var appState = appState
        return NavigationStack(path: $appState.navigationPath) {
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
    }
}

/// Shown for the moment before the first probe answers, so the board never
/// flashes empty behind a gate that is about to appear.
struct CheckingView: View {
    var body: some View {
        VStack(spacing: DS.Space.s300) {
            ProgressView().controlSize(.large)
            Text("Checking your Claude Code setup\u{2026}")
                .font(DS.TypeStyle.emptyStateBody)
                .foregroundStyle(DS.Color.Text.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.Surface.canvas)
        .accessibilityElement(children: .combine)
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
