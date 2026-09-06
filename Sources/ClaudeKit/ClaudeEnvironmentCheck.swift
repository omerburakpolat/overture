import Foundation
import ProcessCore

/// The first-run checks (resolution #12): binary → version → auth → which
/// credential will actually be used. Every step degrades to a specific,
/// actionable failure — never a generic error.
///
/// Every side effect goes through `Probes`, so all branches are unit-testable
/// without a `claude` binary on the machine.
public struct ClaudeEnvironmentCheck: Sendable {
    /// The CLI version the protocol layer is tested against (M0 ran against
    /// 2.1.231). Older blocks; newer warns but never blocks (spec 01 §7.1).
    public static let minimumTestedVersion = SemanticVersion(2, 1, 231)

    public struct CaptureResult: Sendable, Equatable {
        public var stdout: String
        public var stderrTail: [String]
        public var exit: SubprocessExit

        public init(stdout: String, stderrTail: [String] = [],
                    exit: SubprocessExit) {
            self.stdout = stdout
            self.stderrTail = stderrTail
            self.exit = exit
        }
    }

    public struct Probes: Sendable {
        public var candidatePaths: @Sendable () -> [String]
        /// A user-chosen CLI path from Settings, tried before the defaults.
        public var overridePath: @Sendable () -> String?
        public var isExecutable: @Sendable (String) -> Bool
        public var loginShellPATH: @Sendable () async -> String?
        public var childEnvironment: @Sendable () -> [String: String]
        public var shellDivergence:
            @Sendable ([String: String]) async -> ShellEnvironmentProbe.Finding
        /// Runs the CLI and returns stdout, a stderr tail, and the exit —
        /// all three, because the exit code alone cannot distinguish "signed
        /// out" from "the probe broke".
        public var capture:
            @Sendable (URL, [String], [String: String]) async -> CaptureResult
        public var now: @Sendable () -> Date

        public init(
            candidatePaths: @escaping @Sendable () -> [String],
            overridePath: @escaping @Sendable () -> String?,
            isExecutable: @escaping @Sendable (String) -> Bool,
            loginShellPATH: @escaping @Sendable () async -> String?,
            childEnvironment: @escaping @Sendable () -> [String: String],
            shellDivergence: @escaping @Sendable ([String: String]) async
                -> ShellEnvironmentProbe.Finding,
            capture: @escaping @Sendable (URL, [String], [String: String]) async
                -> CaptureResult,
            now: @escaping @Sendable () -> Date
        ) {
            self.candidatePaths = candidatePaths
            self.overridePath = overridePath
            self.isExecutable = isExecutable
            self.loginShellPATH = loginShellPATH
            self.childEnvironment = childEnvironment
            self.shellDivergence = shellDivergence
            self.capture = capture
            self.now = now
        }

        public static let live = Probes(
            candidatePaths: { HostEnvironment.claudeCandidatePaths },
            overridePath: { nil },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            loginShellPATH: { await HostEnvironment.loginShellPATH() },
            childEnvironment: { ClaudeChildEnvironment.make() },
            shellDivergence: { environment in
                await ShellEnvironmentProbe.credentialVariableNames(
                    absentFrom: environment)
            },
            capture: { executable, arguments, environment in
                await liveCapture(executable, arguments, environment)
            },
            now: { Date() })
    }

    public var probes: Probes

    public init(probes: Probes = .live) { self.probes = probes }

    public func run() async -> ClaudeReadiness {
        let cli = await locateCLI()
        let environment = probes.childEnvironment()

        guard let executable = cli.executableURL, cli.isUsable else {
            return ClaudeReadiness(
                cli: cli, auth: .signedOut(ClaudeAccount(loggedIn: false)),
                checkedAt: probes.now())
        }

        let auth = await probeAuth(executable: executable,
                                   environment: environment)
        let credential = auth.account.map {
            CredentialPrecedence.resolve(account: $0,
                                         childEnvironment: environment)
        }
        let divergence = await probes.shellDivergence(environment)
        return ClaudeReadiness(cli: cli, auth: auth,
                               effectiveCredential: credential,
                               shellDivergence: divergence,
                               checkedAt: probes.now())
    }

    /// Re-runs only the auth probe — for post-sign-in, wake, and focus.
    public func refreshAuth(claudeURL: URL) async -> AuthState {
        await probeAuth(executable: claudeURL,
                        environment: probes.childEnvironment())
    }

    public func signOut(claudeURL: URL) async -> Result<Void, ProbeFailure> {
        let result = await probes.capture(claudeURL, ["auth", "logout"],
                                          probes.childEnvironment())
        guard case .exited(code: 0) = result.exit else {
            let code: Int32 = if case .exited(let c) = result.exit { c } else { -1 }
            return .failure(ProbeFailure(kind: .nonZeroExitWithNoJSON(code),
                                         rawStderr: result.stderrTail))
        }
        return .success(())
    }

    // MARK: - Steps

    private func locateCLI() async -> CLIStatus {
        var searched: [String] = []
        var found: URL?

        if let override = probes.overridePath() {
            searched.append(override)
            if probes.isExecutable(override) {
                found = URL(fileURLWithPath: override)
            }
        }
        if found == nil {
            for path in probes.candidatePaths() {
                searched.append(path)
                if probes.isExecutable(path) {
                    found = URL(fileURLWithPath: path)
                    break
                }
            }
        }
        if found == nil, let path = await probes.loginShellPATH() {
            searched.append("$PATH")
            found = HostEnvironment.find(executable: "claude", path: path)
        }
        guard let executable = found else {
            return CLIStatus(installation: .missing(searched: searched))
        }

        let result = await probes.capture(executable, ["--version"],
                                          probes.childEnvironment())
        guard case .exited(code: 0) = result.exit,
              let version = SemanticVersion(parsing: result.stdout) else {
            return CLIStatus(installation: .found(executable),
                             version: .unreadable(
                                detail: Redaction.scrub(result.stdout)))
        }
        let classified: CLIStatus.Version =
            if version < Self.minimumTestedVersion { .belowMinimum(version) }
            else if Self.minimumTestedVersion < version { .untested(version) }
            else { .supported(version) }
        return CLIStatus(installation: .found(executable), version: classified)
    }

    private func probeAuth(executable: URL,
                           environment: [String: String]) async -> AuthState {
        let result = await probes.capture(executable,
                                          ["auth", "status", "--json"],
                                          environment)
        if case .failedToLaunch(let detail) = result.exit {
            return .probeFailed(ProbeFailure(kind: .launchFailed(detail),
                                             rawStderr: result.stderrTail))
        }
        // `auth status` prints valid JSON and *then* exits 1 when logged out,
        // so the output is parsed regardless of the exit code. Only when
        // there is nothing to parse does the exit code decide.
        guard let account = ClaudeAccount(json: result.stdout) else {
            if case .exited(let code) = result.exit, code != 0 {
                return .probeFailed(
                    ProbeFailure(kind: .nonZeroExitWithNoJSON(code),
                                 rawStderr: result.stderrTail))
            }
            return .probeFailed(ProbeFailure(kind: .unparseableOutput,
                                             rawStderr: result.stderrTail))
        }
        guard account.loggedIn else {
            if let policy = account.forcedLoginMethod, policy == .gateway {
                return .blockedByPolicy(policy)
            }
            return .signedOut(account)
        }
        return .signedIn(account)
    }
}

private func liveCapture(_ executable: URL,
                         _ arguments: [String],
                         _ environment: [String: String])
    async -> ClaudeEnvironmentCheck.CaptureResult {
    let subprocess = Subprocess(configuration: .init(
        executable: executable, arguments: arguments,
        environment: environment))
    guard let lines = try? await subprocess.start() else {
        return .init(stdout: "", exit: .failedToLaunch("could not start \(executable.lastPathComponent)"))
    }
    var collected: [String] = []
    for await line in lines { collected.append(line) }
    let exit = await subprocess.waitForExit()
    return .init(stdout: collected.joined(separator: "\n"),
                 stderrTail: await subprocess.stderrSnapshot(),
                 exit: exit)
}
