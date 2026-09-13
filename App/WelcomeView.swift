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
///
/// Layout follows the macOS setup-assistant shape: one centred column, a
/// symbol-and-title header, one requirements list, **one** prominent action,
/// and everything else as plain links. Three visual languages only — a list
/// row is status, a prominent button is the action, a link is an alternative
/// — so nothing has to be read twice to know what it is.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Binding var dismissed: Bool

    private var readiness: ClaudeReadiness? { appState.services.claude }

    var body: some View {
        // Centred in the window while it fits (the setup-assistant shape),
        // scrolling only once it doesn't.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: DS.Space.s600) {
                    header
                    requirements
                    if let readiness {
                        nextStep(readiness)
                    }
                    footer
                }
                .frame(maxWidth: DS.Layout.Sheet.narrow)
                .padding(.horizontal, DS.Space.s600)
                .padding(.vertical, DS.Space.s800)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(DS.Color.Surface.canvas)
    }

    // MARK: - Header

    /// HIG: "Explain the benefits of creating an account … Display this
    /// message in your sign-in view." This is the moment the user decides
    /// whether to trust Overture with an auth flow, so SECURITY.md's promise
    /// belongs here — in one sentence.
    private var header: some View {
        VStack(spacing: DS.Space.s300) {
            // The app's own icon, exactly as the Dock shows it — the bundle
            // ships it, so nothing to add to the design system.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: DS.Layout.welcomeIconSize,
                       height: DS.Layout.welcomeIconSize)
                .accessibilityHidden(true)
            Text("Welcome to Overture")
                .font(DS.TypeStyle.screenTitle)
            Text("Overture runs the Claude Code CLI on this Mac with your own "
                 + "login. It never sees your credentials.")
                .font(DS.TypeStyle.emptyStateBody)
                .foregroundStyle(DS.Color.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Requirements

    /// One list, one container. Rows are status, never actions: a leading
    /// symbol says the state, the text says it again in words.
    private var requirements: some View {
        VStack(spacing: 0) {
            if let readiness {
                let rows = Self.rows(for: readiness)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, DS.Space.s1000)
                    }
                    RequirementRow(row)
                }
            } else {
                RequirementRow(.init(
                    state: .pending, title: "Checking your Claude Code setup…",
                    detail: nil))
            }
        }
        .background(DS.Color.Surface.raised,
                    in: RoundedRectangle(cornerRadius: DS.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .stroke(DS.Color.Border.subtle, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Requirements")
    }

    static func rows(for readiness: ClaudeReadiness) -> [Requirement] {
        var rows: [Requirement] = []

        switch readiness.cli.installation {
        case .missing:
            rows.append(.init(
                state: .blocked, title: "Claude Code isn't installed",
                detail: "Install it, then check again.",
                command: "brew install --cask claude-code"))
        case .found(let url):
            switch readiness.cli.version {
            case .belowMinimum(let found):
                rows.append(.init(
                    state: .blocked, title: "Claude Code \(found) is too old",
                    detail: "Overture needs \(ClaudeEnvironmentCheck.minimumTestedVersion) or newer.",
                    command: "brew upgrade --cask claude-code"))
            case .unreadable:
                rows.append(.init(
                    state: .blocked, title: "Couldn't read the Claude Code version",
                    detail: "Check the installation at "
                        + Redaction.abbreviatingHome(url.path) + ".",
                    command: "claude --version"))
            case .supported(let found), .untested(let found):
                // Newer than tested is a footnote, not a warning (spec 01
                // §7.1: warn, never block — and on a first-run screen, only
                // as quietly as that deserves).
                let note: String? = readiness.cli.version?.isUntested == true
                    ? "Newer than the version Overture was tested with." : nil
                rows.append(.init(
                    state: .pass, title: "Claude Code \(found) is installed",
                    detail: Redaction.abbreviatingHome(url.path), note: note))
            case nil:
                break
            }
            switch readiness.cli.signature {
            case .otherDeveloper?, .unsignedOrModified?:
                rows.append(.init(
                    state: .attention, title: "This claude isn't signed by Anthropic",
                    detail: "Overture will still use it. If you didn't build or "
                        + "choose it yourself, reinstall it or pick another in Settings."))
            default:
                break
            }
        }

        if readiness.cli.isUsable {
            switch readiness.auth {
            case .signedIn(let account):
                rows.append(.init(
                    state: .pass,
                    title: "Signed in as " + (account.email ?? account.authMethod.displayName),
                    detail: account.isIdentityless
                        ? "Claude Code didn't report an account for this credential."
                        : [account.orgName, account.subscriptionType]
                            .compactMap { $0 }.joined(separator: " · ")))
            case .signedOut:
                rows.append(.init(
                    state: .attention, title: "Not signed in to Claude Code",
                    detail: "Sign in below. Your browser opens Anthropic's page "
                        + "and the CLI keeps the credentials."))
            case .blockedByPolicy(let method):
                rows.append(.init(
                    state: .attention, title: "Your organization manages sign-in",
                    detail: ClaudeAccount(loggedIn: false, forcedLoginMethod: method)
                        .policyExplanation ?? "Sign in from a terminal.",
                    command: "claude"))
            case .probeFailed(let failure):
                rows.append(.init(
                    state: .blocked, title: "Couldn't ask Claude Code who's signed in",
                    detail: failure.summary,
                    note: failure.stderrTail.suffix(2).joined(separator: "\n")
                        .nilIfEmpty))
            }
        }

        if let credential = readiness.effectiveCredential,
           credential.overridesReportedLogin {
            rows.append(.init(
                state: .attention, title: "Agents will use a different credential",
                detail: credential.explanation))
        }
        if let divergence = readiness.shellDivergence, divergence.hasDivergence {
            rows.append(.init(
                state: .info, title: "Your shell sets variables Overture can't see",
                detail: nil, divergence: divergence.names))
        }
        return rows
    }

    // MARK: - Next step

    /// The one thing to do now. Exactly one prominent control on screen.
    @ViewBuilder private func nextStep(_ readiness: ClaudeReadiness) -> some View {
        if readiness.cli.isUsable, case .signedOut(let account) = readiness.auth {
            SignInView(permittedModes: account.permittedLoginModes)
        } else if readiness.cli.isUsable, case .blockedByPolicy = readiness.auth {
            EmptyView()   // the row already says to sign in from a terminal
        } else if !readiness.canSpawn {
            Button {
                Task { await appState.services.refreshClaude(reason: .manual) }
            } label: {
                Text("Check Again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Footer

    /// Escape hatch and re-check, both quiet: the screen re-probes on its
    /// own when the app regains focus, so "Check Again" is a convenience,
    /// not the way forward.
    private var footer: some View {
        HStack {
            Button("Continue Without Signing In") { dismissed = true }
            Spacer()
            if readiness?.cli.isUsable == true,
               case .signedOut = readiness?.auth {
                Button("Check Again") {
                    Task { await appState.services.refreshClaude(reason: .manual) }
                }
            }
        }
        .padding(.top, DS.Space.s200)
    }
}

// MARK: - Requirement rows

struct Requirement {
    enum State { case pass, attention, blocked, info, pending }
    var state: State
    var title: String
    var detail: String?
    /// A shell command the user can copy — shown in a code field, never run.
    var command: String? = nil
    /// Tertiary footnote under the detail.
    var note: String? = nil
    /// Shell-divergence guidance, when this row is that one.
    var divergence: [EnvVarName]? = nil
}

private struct RequirementRow: View {
    let row: Requirement

    init(_ row: Requirement) { self.row = row }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s300) {
            symbol
                .frame(width: DS.Space.s500)
            VStack(alignment: .leading, spacing: DS.Space.s100) {
                Text(row.title)
                    .font(DS.TypeStyle.cardTitle)
                    .foregroundStyle(DS.Color.Text.primary)
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(DS.TypeStyle.cardMeta)
                        .foregroundStyle(DS.Color.Text.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command = row.command {
                    CommandField(command)
                        .padding(.top, DS.Space.s100)
                }
                if let note = row.note {
                    Text(note)
                        .font(DS.TypeStyle.timestamp)
                        .foregroundStyle(DS.Color.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let names = row.divergence {
                    ShellDivergenceAdvice(names: names)
                        .padding(.top, DS.Space.s100)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s400)
        .padding(.vertical, DS.Space.s300)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var symbol: some View {
        switch row.state {
        case .pass:
            Image(systemName: DS.Icon.statusPass)
                .foregroundStyle(DS.Status.success.text)
        case .attention:
            Image(systemName: DS.Icon.statusAttention)
                .foregroundStyle(DS.Status.caution.text)
        case .blocked:
            Image(systemName: DS.Icon.statusBlocked)
                .foregroundStyle(DS.Status.danger.text)
        case .info:
            Image(systemName: DS.Icon.info)
                .foregroundStyle(DS.Color.Text.tertiary)
        case .pending:
            ProgressView().controlSize(.small)
        }
    }

    private var accessibilityText: String {
        let state: String = switch row.state {
        case .pass: "Done"
        case .attention: "Needs attention"
        case .blocked: "Blocked"
        case .info: "Note"
        case .pending: "Checking"
        }
        return [state, row.title, row.detail, row.command].compactMap { $0 }
            .joined(separator: ". ")
    }
}

/// A command to copy. Read-only by construction: Overture never runs what it
/// shows here.
private struct CommandField: View {
    let command: String
    @State private var copied = false

    init(_ command: String) { self.command = command }

    var body: some View {
        HStack(spacing: DS.Space.s200) {
            Text(command)
                .font(DS.TypeStyle.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.s300)
        .padding(.vertical, DS.Space.s200)
        .background(DS.Color.Surface.sunken,
                    in: RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}

private extension CLIStatus.Version {
    var isUntested: Bool {
        if case .untested = self { return true }
        return false
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Sign-in

/// App-initiated `claude auth login`.
///
/// Overture drives the CLI and renders a native screen from what it says; it
/// never mirrors the terminal. The credentials go browser → Anthropic → the
/// CLI's own callback and never pass through this process. Even the pasted
/// value is a one-time authorization code, forwarded to the child's stdin and
/// retained nowhere.
///
/// One prominent button for the method most people have, the other method as
/// a link, the terminal route as a link. HIG: "Always identify the
/// authentication method you offer", and offer only what policy allows.
struct SignInView: View {
    @Environment(AppState.self) private var appState
    let permittedModes: [AuthLogin.Mode]

    @State private var login: AuthLogin?
    @State private var phase: Phase = .idle
    @State private var authorizationURL: URL?
    @State private var transcript: [String] = []
    @State private var failure: String?
    @State private var awaitingCode = false
    @State private var code = ""
    @State private var showDetails = false
    @State private var showTerminal = false
    @FocusState private var codeFocused: Bool

    private enum Phase: Equatable { case idle, starting, awaitingBrowser, finished }

    var body: some View {
        VStack(spacing: DS.Space.s300) {
            switch phase {
            case .idle, .finished:
                methodButtons
            case .starting, .awaitingBrowser:
                activeFlow
            }
            if let failure {
                Label(failure, systemImage: DS.Icon.statusAttention)
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Status.danger.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            terminalFallback
        }
        .onDisappear {
            // An authorization code must not outlive the screen.
            code = ""
            Task { await login?.cancel() }
        }
    }

    // MARK: Idle

    /// Subscription is the default when policy allows both — it's what most
    /// people have — and Console becomes a link. Under a policy that permits
    /// one method, that method is the button and there is no link.
    @ViewBuilder private var methodButtons: some View {
        if let primary = permittedModes.first {
            Button { start(primary) } label: {
                Text(primary.buttonTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(primary.subtitle)
            ForEach(permittedModes.dropFirst(), id: \.self) { mode in
                Button(mode.linkTitle) { start(mode) }
                    .buttonStyle(.link)
                    .font(DS.TypeStyle.cardMeta)
                    .accessibilityHint(mode.subtitle)
            }
        }
    }

    // MARK: Active

    @ViewBuilder private var activeFlow: some View {
        VStack(spacing: DS.Space.s300) {
            HStack(spacing: DS.Space.s200) {
                ProgressView().controlSize(.small)
                Text(phase == .starting
                     ? "Starting sign-in…"
                     : "Finish signing in in your browser, then come back here.")
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)

            if let authorizationURL {
                // Only ever a host-allowlisted Anthropic URL.
                Link(destination: authorizationURL) {
                    Text("Open the Sign-In Page").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(authorizationURL.absoluteString,
                                                   forType: .string)
                }
                .buttonStyle(.link)
                .font(DS.TypeStyle.cardMeta)
            }

            if awaitingCode {
                VStack(alignment: .leading, spacing: DS.Space.s100) {
                    HStack {
                        // Forwarded verbatim: the CLI splits on "#" and
                        // rejects a value without both halves.
                        TextField("Code from your browser, if it shows one",
                                  text: $code)
                            .textFieldStyle(.roundedBorder)
                            .font(DS.TypeStyle.code)
                            .focused($codeFocused)
                            .onSubmit(submitCode)
                        Button("Submit") { submitCode() }
                            .disabled(code.isEmpty)
                    }
                    Text("Only needed if the browser shows a code instead of "
                         + "returning here. Paste all of it, including the part "
                         + "after #.")
                        .font(DS.TypeStyle.timestamp)
                        .foregroundStyle(DS.Color.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if !transcript.isEmpty {
                    Button(showDetails ? "Hide CLI Output" : "Show CLI Output") {
                        showDetails.toggle()
                    }
                    .buttonStyle(.link)
                    .font(DS.TypeStyle.cardMeta)
                }
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
            }

            if showDetails, !transcript.isEmpty {
                ScrollView {
                    Text(transcript.suffix(20).joined(separator: "\n"))
                        .font(DS.TypeStyle.code)
                        .foregroundStyle(DS.Color.Text.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.s200)
                }
                .frame(height: DS.Layout.consoleHeight)
                .background(DS.Color.Surface.sunken,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
        }
    }

    // MARK: Terminal route

    /// Always available, never automated. Driving Terminal.app would mean
    /// writing a shell script to disk or asking for Apple Events permission —
    /// both worse security stories than a pipe, and neither works for
    /// everyone's terminal of choice.
    @ViewBuilder private var terminalFallback: some View {
        Button(showTerminal ? "Hide terminal instructions" : "Sign in from a terminal") {
            withAnimation(DS.Motion.fade) { showTerminal.toggle() }
        }
        .buttonStyle(.link)
        .font(DS.TypeStyle.cardMeta)
        if showTerminal {
            VStack(alignment: .leading, spacing: DS.Space.s200) {
                Text("Run this in any terminal, sign in, then come back — "
                     + "Overture notices on its own.")
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CommandField("claude auth login")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Flow

    private func start(_ mode: AuthLogin.Mode) {
        guard let claudeURL = appState.services.claudeURL else { return }
        let flow = AuthLogin()
        login = flow
        transcript = []
        failure = nil
        awaitingCode = false
        authorizationURL = nil
        showDetails = false
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
            awaitingCode = true
        case .message(let line):
            transcript.append(line)
        case .invalidCode(let text):
            failure = "That code wasn't accepted. Paste the whole code, "
                + "including the part after #."
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
                failure = "Sign-in didn't complete. Try again, or sign in "
                    + "from a terminal."
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

private extension AuthLogin.Mode {
    /// The same method named as an alternative, for the link under the
    /// primary button.
    var linkTitle: String {
        switch self {
        case .subscription: "Sign in with a Claude subscription"
        case .console: "Sign in with Anthropic Console"
        }
    }
}
