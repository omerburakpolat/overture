import SwiftUI
import UniformTypeIdentifiers
import OvertureDesign
import OvertureKit
import ClaudeKit

/// The macOS HIG describes a settings window as "a toolbar that includes
/// buttons for switching between views — called panes". Only Claude is filled
/// in for now; the other panes exist so later work has an obvious home rather
/// than accreting into one long form.
struct SettingsView: View {
    var body: some View {
        TabView {
            ClaudeSettingsPane()
                .tabItem { Label("Claude", systemImage: DS.Icon.account) }
            PlaceholderPane(
                title: "General",
                detail: "Appearance, notifications and unattended-run "
                    + "settings will live here.")
                .tabItem { Label("General", systemImage: DS.Icon.settings) }
            PlaceholderPane(
                title: "Integrations",
                detail: "GitHub and Vercel status will live here. Overture "
                    + "shells out to your own `gh`; it never stores a GitHub "
                    + "token.")
                .tabItem { Label("Integrations", systemImage: DS.Icon.pullRequest) }
        }
        .frame(width: DS.Layout.Sheet.medium, height: 460)
    }
}

/// Everything about the CLI Overture drives and the account it runs as.
struct ClaudeSettingsPane: View {
    @Environment(AppState.self) private var appState
    @State private var confirmingSignOut = false
    @State private var signOutError: String?
    @State private var choosingCLI = false

    private var readiness: ClaudeReadiness? { appState.services.claude }

    /// Names the login an environment credential is bypassing, when the second
    /// status probe found one.
    private var bypassedLoginText: String {
        if let stored = readiness?.storedLogin, stored.loggedIn {
            let who = stored.email ?? stored.authMethod.displayName
            return "Your signed-in account (\(who)) is not being used."
        }
        return "This overrides the account signed in to Claude Code."
    }

    var body: some View {
        Form {
            accountSection
            credentialSection
            toolSection
        }
        .formStyle(.grouped)
        .task { await appState.services.refreshClaude(reason: .settingsOpened) }
        .fileImporter(isPresented: $choosingCLI,
                      allowedContentTypes: [.unixExecutable, .executable]) { result in
            if case .success(let url) = result {
                appState.services.setClaudeExecutableOverride(url)
                Task { await appState.services.refreshClaude(reason: .manual) }
            }
        }
    }

    // MARK: - Account

    @ViewBuilder private var accountSection: some View {
        Section("Account") {
            switch readiness?.auth {
            case .signedIn(let account):
                LabeledContent("Signed in as") {
                    // The oauth_token case reports no identity at all, so a
                    // bare "signed in" would be a lie by omission.
                    VStack(alignment: .trailing, spacing: DS.Space.s050) {
                        Text(account.email ?? account.authMethod.displayName)
                        if account.isIdentityless {
                            Text("Claude Code didn't report an account for "
                                 + "this credential.")
                                .font(DS.TypeStyle.timestamp)
                                .foregroundStyle(DS.Color.Text.tertiary)
                        }
                    }
                }
                // orgName only — orgId is an opaque identifier with no user
                // value and every reason to stay out of screenshots.
                if let organization = account.orgName {
                    LabeledContent("Organization") { Text(organization) }
                }
                LabeledContent("Plan") {
                    Text(account.subscriptionType
                         ?? account.apiProvider.displayName)
                }
                signOutButton
            case .signedOut(let account):
                if let explanation = account.policyExplanation {
                    Label(explanation, systemImage: DS.Icon.policy)
                        .font(DS.TypeStyle.cardMeta)
                        .foregroundStyle(DS.Color.Text.secondary)
                }
                SignInView(permittedModes: account.permittedLoginModes)
            case .blockedByPolicy(let method):
                Label(ClaudeAccount(loggedIn: false, forcedLoginMethod: method)
                        .policyExplanation ?? "Sign in from a terminal.",
                      systemImage: DS.Icon.policy)
                    .font(DS.TypeStyle.cardMeta)
            case .probeFailed(let failure):
                Label(failure.summary, systemImage: DS.Icon.error)
                    .foregroundStyle(DS.Status.danger.text)
                    .font(DS.TypeStyle.cardMeta)
            case nil:
                ProgressView().controlSize(.small)
            }
            if let signOutError {
                Text(signOutError)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Status.danger.text)
            }
        }
    }

    private var signOutButton: some View {
        Button("Sign Out\u{2026}", role: .destructive) {
            confirmingSignOut = true
        }
        // `claude auth logout` mutates state shared with the user's terminal
        // and every other tool on the machine. A bare "Sign Out" would be a
        // genuinely nasty surprise.
        .confirmationDialog("Sign out of Claude Code?",
                            isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) {
                Task {
                    signOutError = nil
                    if case .failure(let failure) =
                        await appState.services.signOutOfClaude() {
                        signOutError = failure.summary
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out the `claude` CLI everywhere on this Mac, "
                 + "including Terminal and any other app that uses it. "
                 + "Overture can't sign those back in for you.")
        }
    }

    // MARK: - Effective credential

    /// The honest section, and the reason this pane exists: `claude auth
    /// status` alone cannot say which credential a headless spawn will use.
    @ViewBuilder private var credentialSection: some View {
        if let credential = readiness?.effectiveCredential {
            Section("Effective credential") {
                LabeledContent("Agents will use") {
                    Text(credential.explanation)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if credential.overridesReportedLogin {
                    Label(bypassedLoginText,
                          systemImage: DS.Icon.error)
                        .font(DS.TypeStyle.cardMeta)
                        .foregroundStyle(DS.Status.caution.text)
                }
                if !credential.evidence.isEmpty {
                    // Names only. Never a value, not even masked — a masked
                    // key is still a key fragment and serves no user need.
                    LabeledContent("From") {
                        Text(credential.evidence.map(\.rawValue)
                                .joined(separator: ", "))
                            .font(DS.TypeStyle.code)
                    }
                }
                if let divergence = readiness?.shellDivergence,
                   divergence.hasDivergence {
                    ShellDivergenceAdvice(names: divergence.names)
                }
            }
        }
    }

    // MARK: - Command-line tool

    @ViewBuilder private var toolSection: some View {
        Section("Command-line tool") {
            LabeledContent("Path") {
                Text(appState.services.claudeURL?.path ?? "not found")
                    .font(DS.TypeStyle.code)
                    .textSelection(.enabled)
            }
            if let signature = readiness?.cli.signature {
                LabeledContent("Signed by") {
                    switch signature {
                    case .anthropic:
                        Label("Anthropic PBC (\(CodeSignature.anthropicTeamID))",
                              systemImage: DS.Icon.finished)
                            .foregroundStyle(DS.Status.success.text)
                    case .otherDeveloper:
                        Label("Another developer, not Anthropic",
                              systemImage: DS.Icon.info)
                            .foregroundStyle(DS.Status.caution.text)
                    case .unsignedOrModified:
                        Label("Not signed", systemImage: DS.Icon.info)
                            .foregroundStyle(DS.Status.caution.text)
                    case .unverified:
                        Text("Couldn't check")
                            .foregroundStyle(DS.Color.Text.tertiary)
                    }
                }
            }
            if let version = readiness?.cli.version {
                LabeledContent("Version") {
                    switch version {
                    case .supported(let found):
                        Text(found.description)
                    case .untested(let found):
                        VStack(alignment: .trailing, spacing: DS.Space.s050) {
                            Text(found.description)
                            Text("Newer than the version Overture is tested "
                                 + "against (\(ClaudeEnvironmentCheck.minimumTestedVersion)).")
                                .font(DS.TypeStyle.timestamp)
                                .foregroundStyle(DS.Color.Text.tertiary)
                        }
                    case .belowMinimum(let found):
                        Text("\(found) — older than "
                             + "\(ClaudeEnvironmentCheck.minimumTestedVersion)")
                            .foregroundStyle(DS.Status.danger.text)
                    case .unreadable:
                        Text("unreadable").foregroundStyle(DS.Status.caution.text)
                    }
                }
            }
            // Makes the CLAUDE_CONFIG_DIR situation something a user can
            // eyeball, rather than a silent mismatch.
            LabeledContent("Config directory") {
                Text(Redaction.abbreviatingHome(
                    TranscriptStore.configRoot().path))
                    .font(DS.TypeStyle.code)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Choose\u{2026}") { choosingCLI = true }
                if appState.services.hasClaudeExecutableOverride {
                    Button("Use the One Overture Found") {
                        appState.services.setClaudeExecutableOverride(nil)
                        Task { await appState.services.refreshClaude(reason: .manual) }
                    }
                }
                Spacer()
                Button("Check Again") {
                    Task { await appState.services.refreshClaude(reason: .manual) }
                }
            }
        }
    }
}

private struct PlaceholderPane: View {
    let title: String
    let detail: String

    var body: some View {
        Form {
            Section(title) {
                Text(detail)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
