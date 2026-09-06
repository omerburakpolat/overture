import Foundation
import Testing
import ProcessCore
@testable import ClaudeKit

/// Every branch, with no `claude` binary on the machine — the point of the
/// `Probes` seam. The old `OnboardingCheck` took an `environment:` parameter
/// its body never used, so only the happy path was reachable.
@Suite struct ClaudeEnvironmentCheckTests {
    private static let executablePath = "/opt/homebrew/bin/claude"

    /// A probe set that finds a CLI and answers `--version` and
    /// `auth status` from the values given.
    private static func probes(
        executableExists: Bool = true,
        versionStdout: String = "2.1.236 (Claude Code)",
        versionExit: SubprocessExit = .exited(code: 0),
        authStdout: String = #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "user@example.com", "subscriptionType": "max"}"#,
        authExit: SubprocessExit = .exited(code: 0),
        authStderr: [String] = [],
        childEnvironment: [String: String] = [:]
    ) -> ClaudeEnvironmentCheck.Probes {
        ClaudeEnvironmentCheck.Probes(
            candidatePaths: { [executablePath] },
            overridePath: { nil },
            isExecutable: { _ in executableExists },
            loginShellPATH: { nil },
            childEnvironment: { childEnvironment },
            shellDivergence: { _ in .init(names: [], probeSucceeded: true) },
            capture: { _, arguments, _ in
                if arguments == ["--version"] {
                    return .init(stdout: versionStdout, exit: versionExit)
                }
                return .init(stdout: authStdout, stderrTail: authStderr,
                             exit: authExit)
            },
            now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func findsTheCLIAndReachesSignedIn() async {
        let readiness = await ClaudeEnvironmentCheck(probes: Self.probes()).run()
        #expect(readiness.cli.executableURL?.path == Self.executablePath)
        #expect(readiness.cli.version == .untested(SemanticVersion(2, 1, 236)))
        #expect(readiness.cli.isUsable)
        #expect(readiness.auth.account?.email == "user@example.com")
        #expect(readiness.canSpawn)
    }

    @Test func missingBinaryListsWhatWasSearched() async {
        let check = ClaudeEnvironmentCheck(
            probes: Self.probes(executableExists: false))
        let readiness = await check.run()
        #expect(readiness.cli.executableURL == nil)
        #expect(readiness.canSpawn == false)
        guard case .missing(let searched) = readiness.cli.installation else {
            Issue.record("expected .missing, got \(readiness.cli.installation)")
            return
        }
        #expect(searched.contains(Self.executablePath))
    }

    /// The defect this model exists to fix: a CLI whose version can't be read
    /// is still a CLI. Its path must survive so sign-in and the path override
    /// have something to work with.
    @Test func unreadableVersionKeepsTheExecutablePath() async {
        let check = ClaudeEnvironmentCheck(probes: Self.probes(
            versionStdout: "", versionExit: .exited(code: 127)))
        let readiness = await check.run()
        #expect(readiness.cli.executableURL?.path == Self.executablePath)
        #expect(readiness.cli.isUsable == false)
        if case .unreadable = readiness.cli.version {} else {
            Issue.record("expected .unreadable, got \(String(describing: readiness.cli.version))")
        }
    }

    @Test func tooOldIsBlockedButStillLocated() async {
        let check = ClaudeEnvironmentCheck(
            probes: Self.probes(versionStdout: "2.1.100 (Claude Code)"))
        let readiness = await check.run()
        #expect(readiness.cli.version == .belowMinimum(SemanticVersion(2, 1, 100)))
        #expect(readiness.cli.isUsable == false)
        #expect(readiness.cli.executableURL != nil)
    }

    /// Newer than tested warns but never blocks (spec 01 §7.1).
    @Test func newerThanTestedIsUsable() async {
        let check = ClaudeEnvironmentCheck(
            probes: Self.probes(versionStdout: "9.9.9 (Claude Code)"))
        let readiness = await check.run()
        #expect(readiness.cli.version == .untested(SemanticVersion(9, 9, 9)))
        #expect(readiness.cli.isUsable)
    }

    @Test func exactMinimumVersionIsSupported() async {
        let check = ClaudeEnvironmentCheck(
            probes: Self.probes(versionStdout: "2.1.231 (Claude Code)"))
        let readiness = await check.run()
        #expect(readiness.cli.version == .supported(SemanticVersion(2, 1, 231)))
    }

    /// The real CLI prints valid JSON and *then* exits 1 when logged out.
    /// Reading the exit code first — as the old code did — reports a working
    /// probe as a broken one.
    @Test func loggedOutJSONWithExitOneIsSignedOutNotAFailure() async {
        let check = ClaudeEnvironmentCheck(probes: Self.probes(
            authStdout: #"{"loggedIn": false}"#, authExit: .exited(code: 1)))
        let readiness = await check.run()
        #expect(readiness.auth == .signedOut(ClaudeAccount(loggedIn: false)))
    }

    @Test func nonZeroExitWithNoOutputIsAProbeFailure() async {
        let check = ClaudeEnvironmentCheck(probes: Self.probes(
            authStdout: "", authExit: .exited(code: 1)))
        let readiness = await check.run()
        guard case .probeFailed(let failure) = readiness.auth else {
            Issue.record("expected .probeFailed, got \(readiness.auth)")
            return
        }
        #expect(failure.kind == .nonZeroExitWithNoJSON(1))
        #expect(readiness.canSpawn == false)
    }

    @Test func garbageOutputIsAProbeFailure() async {
        let check = ClaudeEnvironmentCheck(probes: Self.probes(
            authStdout: "totally not json", authExit: .exited(code: 0)))
        let readiness = await check.run()
        guard case .probeFailed(let failure) = readiness.auth else {
            Issue.record("expected .probeFailed, got \(readiness.auth)")
            return
        }
        #expect(failure.kind == .unparseableOutput)
    }

    @Test func launchFailureIsDistinctFromSignedOut() async {
        let check = ClaudeEnvironmentCheck(probes: Self.probes(
            authStdout: "", authExit: .failedToLaunch("no such file")))
        let readiness = await check.run()
        guard case .probeFailed(let failure) = readiness.auth else {
            Issue.record("expected .probeFailed, got \(readiness.auth)")
            return
        }
        #expect(failure.kind == .launchFailed("no such file"))
    }

    @Test func gatewayPolicyIsReportedSeparatelyFromSignedOut() async {
        let check = ClaudeEnvironmentCheck(probes: Self.probes(
            authStdout: #"{"loggedIn": false, "forcedLoginMethod": "gateway"}"#,
            authExit: .exited(code: 1)))
        let readiness = await check.run()
        #expect(readiness.auth == .blockedByPolicy(.gateway))
        #expect(readiness.canSpawn == false)
    }

    /// Anything the CLI wrote to stderr is scrubbed before it can reach a
    /// type the UI renders.
    @Test func stderrIsScrubbedBeforeItReachesTheUI() async {
        let check = ClaudeEnvironmentCheck(probes: Self.probes(
            authStdout: "", authExit: .exited(code: 1),
            authStderr: ["failed with ANTHROPIC_API_KEY=sk-ant-CANARYabcdefgh"]))
        let readiness = await check.run()
        guard case .probeFailed(let failure) = readiness.auth else {
            Issue.record("expected .probeFailed")
            return
        }
        #expect(!failure.stderrTail.joined().contains("CANARY"))
        #expect(failure.stderrTail.joined().contains("ANTHROPIC_API_KEY"))
    }

    /// The credential resolution is computed from the same dictionary the
    /// spawns will use, so the reported answer describes a real process.
    @Test func theEffectiveCredentialReflectsTheChildEnvironment() async {
        let check = ClaudeEnvironmentCheck(probes: Self.probes(
            authStdout: #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "apiKeySource": "ANTHROPIC_API_KEY", "email": "user@example.com", "subscriptionType": "max"}"#,
            childEnvironment: ["ANTHROPIC_API_KEY": "sk-ant-CANARYabcdefgh"]))
        let readiness = await check.run()
        #expect(readiness.effectiveCredential?.source == .apiKeyEnvironment)
        #expect(readiness.effectiveCredential?.overridesReportedLogin == true)
        #expect(!readiness.redactedDiagnostics().contains("CANARY"))
    }

    /// Diagnostics are meant to be pasted into an issue.
    @Test func diagnosticsOmitIdentity() async {
        let check = ClaudeEnvironmentCheck(probes: Self.probes(
            authStdout: #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "user@example.com", "orgId": "org-123", "orgName": "Example Org", "subscriptionType": "max"}"#))
        let diagnostics = await check.run().redactedDiagnostics()
        #expect(!diagnostics.contains("user@example.com"))
        #expect(!diagnostics.contains("Example Org"))
        #expect(!diagnostics.contains("org-123"))
        #expect(diagnostics.contains("authMethod: claude.ai"))
    }

    @Test func aChosenOverridePathWinsOverTheDefaults() async {
        var probes = Self.probes()
        probes.overridePath = { "/custom/bin/claude" }
        let readiness = await ClaudeEnvironmentCheck(probes: probes).run()
        #expect(readiness.cli.executableURL?.path == "/custom/bin/claude")
    }
}
