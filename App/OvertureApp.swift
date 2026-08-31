import SwiftUI
import OvertureDesign
import OvertureKit

@main
struct OvertureApp: App {
    @State private var appState = try? AppState()

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

/// Root composition: services + stores, built once.
@MainActor
@Observable
final class AppState {
    let services: AppServices
    let coordinator: SessionCoordinator
    let projectsStore: ProjectsStore
    var navigationPath = NavigationPath()

    init() throws {
        services = try AppServices()
        coordinator = SessionCoordinator(services: services)
        projectsStore = ProjectsStore(services: services)
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
                             detail: "Run `claude` once in a terminal and "
                                + "sign in, then retry.")
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

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            let running = appState.coordinator.live.filter {
                if case .working = $0.value.activity { return true }
                if case .needsInput = $0.value.activity { return true }
                return false
            }
            if running.isEmpty {
                Text("No agents running")
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
            } else {
                Text("\(running.count) agent\(running.count == 1 ? "" : "s") running")
                    .font(DS.TypeStyle.cardTitle)
            }
        }
        .padding(DS.Space.s400)
        .frame(minWidth: 240)
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
