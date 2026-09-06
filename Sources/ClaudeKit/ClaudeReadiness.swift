import Foundation

/// What Overture knows about the `claude` CLI it will drive.
///
/// Split along two independent axes — *which CLI* and *what credential* —
/// because collapsing them makes a signed-out user look like a user with no
/// CLI at all, and leaves the sign-in flow with no binary to run.
public struct CLIStatus: Sendable, Equatable {
    public enum Installation: Sendable, Equatable {
        case missing(searched: [String])
        case found(URL)
    }

    public enum Version: Sendable, Equatable {
        case unreadable(detail: String)
        case belowMinimum(SemanticVersion)
        case supported(SemanticVersion)
        /// Newer than the version the protocol layer is tested against. A
        /// soft warning, never a block (spec 01 §7.1).
        case untested(SemanticVersion)

        public var semantic: SemanticVersion? {
            switch self {
            case .unreadable: nil
            case .belowMinimum(let v), .supported(let v), .untested(let v): v
            }
        }
    }

    public var installation: Installation
    /// Nil only when the binary is missing.
    public var version: Version?

    public init(installation: Installation, version: Version? = nil) {
        self.installation = installation
        self.version = version
    }

    /// Set whenever a binary was found — even if its version is too old or
    /// unreadable. Sign-in and the CLI-path override both need it, and
    /// withholding it is what forced the old code to rediscover the binary
    /// behind the store's back.
    public var executableURL: URL? {
        if case .found(let url) = installation { return url }
        return nil
    }

    public var isUsable: Bool {
        guard executableURL != nil, let version else { return false }
        switch version {
        case .supported, .untested: return true
        case .unreadable, .belowMinimum: return false
        }
    }
}

/// Why an auth probe could not answer. Distinct from "signed out", which is a
/// successful probe with a definite answer.
public struct ProbeFailure: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case launchFailed(String)
        case nonZeroExitWithNoJSON(Int32)
        case unparseableOutput
        case timedOut
    }

    public var kind: Kind
    /// Scrubbed on the way in, so an unscrubbed value never exists inside a
    /// type the UI can reach.
    public var stderrTail: [String]

    public init(kind: Kind, rawStderr: [String] = []) {
        self.kind = kind
        self.stderrTail = Redaction.scrub(rawStderr)
    }

    public var summary: String {
        switch kind {
        case .launchFailed:
            "Couldn't run the Claude Code CLI."
        case .nonZeroExitWithNoJSON(let code):
            "The CLI exited with status \(code) without reporting its status."
        case .unparseableOutput:
            "The CLI reported its status in a format Overture didn't understand."
        case .timedOut:
            "The CLI didn't respond in time."
        }
    }
}

public enum AuthState: Sendable, Equatable {
    /// Carries the probe's account even though nobody is signed in: the CLI
    /// reports `forcedLoginMethod` regardless, and the sign-in view needs it
    /// to offer only the methods policy allows.
    case signedOut(ClaudeAccount)
    case signedIn(ClaudeAccount)
    case blockedByPolicy(ClaudeAccount.ForcedLoginMethod)
    case probeFailed(ProbeFailure)

    /// The probe's account, signed in or not.
    public var account: ClaudeAccount? {
        switch self {
        case .signedIn(let account), .signedOut(let account): account
        case .blockedByPolicy, .probeFailed: nil
        }
    }

    /// The signed-in account only — for identity display.
    public var signedInAccount: ClaudeAccount? {
        if case .signedIn(let account) = self { return account }
        return nil
    }

    /// Whether a session could be spawned. A policy block or a broken probe
    /// is not a "maybe" — neither can start work.
    public var isSpawnable: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// One snapshot of everything the first-run screen and the Settings pane need.
public struct ClaudeReadiness: Sendable, Equatable {
    public var cli: CLIStatus
    public var auth: AuthState
    /// Which credential the app's own spawns will actually use.
    public var effectiveCredential: CredentialPrecedence.Resolution?
    public var shellDivergence: ShellEnvironmentProbe.Finding?
    public var checkedAt: Date

    public init(cli: CLIStatus,
                auth: AuthState,
                effectiveCredential: CredentialPrecedence.Resolution? = nil,
                shellDivergence: ShellEnvironmentProbe.Finding? = nil,
                checkedAt: Date) {
        self.cli = cli
        self.auth = auth
        self.effectiveCredential = effectiveCredential
        self.shellDivergence = shellDivergence
        self.checkedAt = checkedAt
    }

    public var canSpawn: Bool { cli.isUsable && auth.isSpawnable }

    /// A paste-into-an-issue summary. Carries variable names, never values;
    /// omits email, organisation name and organisation id entirely.
    public func redactedDiagnostics() -> String {
        var lines: [String] = []
        switch cli.installation {
        case .missing(let searched):
            lines.append("cli: not found")
            lines.append("searched: "
                + searched.map(Redaction.abbreviatingHome).joined(separator: ", "))
        case .found(let url):
            lines.append("cli: \(Redaction.abbreviatingHome(url.path))")
        }
        if let version = cli.version {
            switch version {
            case .unreadable: lines.append("version: unreadable")
            case .belowMinimum(let v): lines.append("version: \(v) (below minimum)")
            case .supported(let v): lines.append("version: \(v)")
            case .untested(let v): lines.append("version: \(v) (newer than tested)")
            }
        }
        switch auth {
        case .signedOut:
            lines.append("auth: signed out")
        case .signedIn(let account):
            lines.append("auth: signed in")
            lines.append("authMethod: \(account.authMethod.rawValue)")
            lines.append("apiProvider: \(account.apiProvider.rawValue)")
            if let plan = account.subscriptionType {
                lines.append("subscriptionType: \(plan)")
            }
            if let source = account.apiKeySource {
                lines.append("apiKeySource: \(source)")
            }
        case .blockedByPolicy(let method):
            lines.append("auth: blocked by policy (\(method.rawValue))")
        case .probeFailed(let failure):
            lines.append("auth: probe failed (\(failure.kind))")
        }
        if let credential = effectiveCredential {
            lines.append("credential: level \(credential.level)")
            if !credential.evidence.isEmpty {
                lines.append("credentialEvidence: "
                    + credential.evidence.map(\.rawValue).joined(separator: ", "))
            }
            lines.append("overridesReportedLogin: \(credential.overridesReportedLogin)")
        }
        if let divergence = shellDivergence, divergence.hasDivergence {
            lines.append("shellOnlyVariables: "
                + divergence.names.map(\.rawValue).joined(separator: ", "))
        }
        lines.append("canSpawn: \(canSpawn)")
        return lines.joined(separator: "\n")
    }
}
