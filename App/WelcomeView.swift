import SwiftUI
import AppKit
import OvertureDesign
import OvertureKit
import ClaudeKit

/// First run (resolution #12): the checks Overture needs before any card can
/// run, as a window rather than a modal.
///
/// Apple's HIG says to "delay sign-in for as long as possible", but also that
/// a launch-time request is right when "your app needs access to private data
/// or resources before it can function". A card *is* a Claude Code session,
/// so without a working signed-in CLI there is no product — a gate is
/// justified. A trap is not, which is why this is a window (the menu bar
/// stays live, ⌘, reaches Settings) with a way past it.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Binding var dismissed: Bool
    @FocusState private var primaryFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s400) {
                header
                checklist
                footer
            }
            .padding(DS.Space.s600)
            .frame(maxWidth: DS.Layout.Sheet.wide, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DS.Color.Surface.canvas)
    }

    /// HIG: "Explain the benefits of creating an account and how to sign up
    /// … Display this message in your sign-in view." This is the moment the
    /// user decides whether to trust Overture with an auth flow, so
    /// SECURITY.md's promise belongs right here.
    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s200) {
            Text("Overture runs Claude Code for you")
                .font(DS.TypeStyle.screenTitle)
            Text("Overture drives the `claude` CLI already installed on this "
                 + "Mac, using the login you already have. It never sees your "
                 + "credentials, and never writes to ~/.claude.")
                .font(DS.TypeStyle.emptyStateBody)
                .foregroundStyle(DS.Color.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            // The escape hatch: a gate, never a dead end.
            Button("Continue Without Signing In") { dismissed = true }
            Spacer()
            Button("Check Again") {
                Task { await appState.services.refreshClaude(reason: .manual) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .focused($primaryFocused)
        }
        .onAppear { primaryFocused = true }
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
        case .signedOut(let account):
            checklistRow(
                icon: DS.Icon.awaitingPermission, tint: DS.Status.caution,
                title: "Claude Code isn't signed in",
                detail: "Sign in below. Your browser opens Anthropic's login "
                    + "page and the CLI stores the credentials — Overture "
                    + "never sees them.")
            SignInView(permittedModes: account.permittedLoginModes)
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

/// App-initiated `claude auth login`.
///
/// Overture drives the CLI and renders a native screen from what it says; it
/// never mirrors the terminal. The credentials go browser → Anthropic → the
/// CLI's own callback and never pass through this process. Even the pasted
/// value is a one-time authorization code, forwarded to the child's stdin and
/// retained nowhere.
struct SignInView: View {
    @Environment(AppState.self) private var appState
    let permittedModes: [AuthLogin.Mode]

    @State private var login: AuthLogin?
    @State private var phase: Phase = .idle
    @State private var authorizationURL: URL?
    @State private var transcript: [String] = []
    @State private var failure: String?
    @State private var codeHint: String?
    @State private var code = ""
    @State private var showDetails = false
    @FocusState private var codeFocused: Bool

    private enum Phase: Equatable { case idle, starting, awaitingBrowser, finished }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s300) {
            switch phase {
            case .idle, .finished:
                methodButtons
            case .starting, .awaitingBrowser:
                activeFlow
            }
            if let failure {
                Label(failure, systemImage: DS.Icon.error)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Status.danger.text)
                    .padding(DS.Space.s300)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Status.danger.tint,
                                in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
            terminalFallback
        }
        .onDisappear {
            // An authorization code must not outlive the screen.
            code = ""
            Task { await login?.cancel() }
        }
    }

    @ViewBuilder private var methodButtons: some View {
        // HIG: "Refer only to authentication methods that are available in
        // the current context" — a policy-pinned org sees only its method.
        ForEach(Array(permittedModes.enumerated()), id: \.offset) { index, mode in
            Button { start(mode) } label: {
                VStack(alignment: .leading, spacing: DS.Space.s050) {
                    Text(mode.buttonTitle).font(DS.TypeStyle.cardTitle)
                    Text(mode.subtitle)
                        .font(DS.TypeStyle.cardMeta)
                        .foregroundStyle(DS.Color.Text.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.s300)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(index == 0 ? DS.Color.Accent.tint : DS.Color.Surface.raised,
                        in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(DS.Color.Border.subtle, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(mode.buttonTitle). \(mode.subtitle)")
        }
    }

    @ViewBuilder private var activeFlow: some View {
        HStack(spacing: DS.Space.s200) {
            ProgressView().controlSize(.small)
            Text(phase == .starting
                 ? "Starting sign-in…"
                 : "Finish signing in in your browser, then come back.")
                .font(DS.TypeStyle.cardMeta)
                .foregroundStyle(DS.Color.Text.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)

        if let authorizationURL {
            HStack {
                // Only ever a host-allowlisted Anthropic URL.
                Link("Open the Sign-In Page", destination: authorizationURL)
                    .buttonStyle(.borderedProminent)
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(authorizationURL.absoluteString,
                                                   forType: .string)
                }
            }
        }

        if codeHint != nil {
            VStack(alignment: .leading, spacing: DS.Space.s100) {
                // Forwarded verbatim: the CLI splits on "#" and rejects a
                // value without both halves.
                TextField("Paste the code from your browser (including the "
                          + "part after #)", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.TypeStyle.code)
                    .focused($codeFocused)
                    .onSubmit(submitCode)
                Text("Only needed if your browser shows a code instead of "
                     + "returning here.")
                    .font(DS.TypeStyle.timestamp)
                    .foregroundStyle(DS.Color.Text.tertiary)
            }
        }

        HStack {
            if codeHint != nil {
                Button("Submit Code") { submitCode() }.disabled(code.isEmpty)
            }
            Spacer()
            Button("Cancel", role: .cancel) { cancel() }
                .keyboardShortcut(.cancelAction)
        }

        if !transcript.isEmpty {
            DisclosureGroup("Show CLI output", isExpanded: $showDetails) {
                ScrollView {
                    Text(transcript.suffix(20).joined(separator: "\n"))
                        .font(DS.TypeStyle.code)
                        .foregroundStyle(DS.Color.Text.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: DS.Layout.consoleHeight)
            }
            .font(DS.TypeStyle.cardMeta)
        }
    }

    /// Always available, never automated. Driving Terminal.app would mean
    /// writing a shell script to disk or asking for Apple Events permission —
    /// both worse security stories than a pipe, and neither works for
    /// everyone's terminal of choice.
    @ViewBuilder private var terminalFallback: some View {
        DisclosureGroup("Having trouble?") {
            VStack(alignment: .leading, spacing: DS.Space.s200) {
                Text("You can sign in from any terminal instead:")
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
                HStack {
                    Text("claude auth login")
                        .font(DS.TypeStyle.code)
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude auth login",
                                                       forType: .string)
                    }
                    Button("Check Again") {
                        Task { await appState.services.refreshClaude(reason: .manual) }
                    }
                }
            }
            .padding(.top, DS.Space.s100)
        }
        .font(DS.TypeStyle.cardMeta)
    }

    private func start(_ mode: AuthLogin.Mode) {
        guard let claudeURL = appState.services.claudeURL else { return }
        let flow = AuthLogin()
        login = flow
        transcript = []
        failure = nil
        codeHint = nil
        phase = .starting
        Task {
            guard let events = try? await flow.start(claudeURL: claudeURL,
                                                     mode: mode) else {
                failure = "Overture couldn't start `claude auth login`."
                phase = .idle
                return
            }
            for await event in events { await handle(event) }
        }
    }

    private func handle(_ event: AuthLogin.Event) async {
        switch event {
        case .opening:
            phase = .awaitingBrowser
        case .authorizationURL(let url):
            authorizationURL = url
            phase = .awaitingBrowser
        case .awaitingCode:
            codeHint = "awaiting"
        case .message(let line):
            transcript.append(line)
        case .invalidCode(let text):
            failure = "Paste the whole code, including the part after `#`."
            transcript.append(text)
            code = ""
            codeFocused = true
        case .failed(let text):
            failure = text
            transcript.append(text)
            showDetails = true
        case .succeeded:
            transcript.append("Login successful.")
        case .ended:
            phase = .finished
            code = ""
            // Never trust the exit code — ask the CLI who it is now.
            let readiness = await appState.services
                .refreshClaude(reason: .afterSignIn)
            if readiness?.auth.isSpawnable != true, failure == nil {
                failure = "Sign-in didn't complete. You can try again, or "
                    + "sign in from a terminal."
            }
        }
    }

    private func submitCode() {
        let pasted = code
        code = ""
        Task { try? await login?.submit(pasted) }
    }

    private func cancel() {
        Task { await login?.cancel() }
        code = ""
        phase = .idle
    }
}

