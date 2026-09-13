import Foundation
import Testing
import ClaudeKit
@testable import OvertureKit

/// Small thread-safe counter — the probe closures are `@Sendable`.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// A probe set that finds a CLI and reports the given login, counting one
/// increment per full check (`--version` runs once per check).
private func stubCheck(counter: ProbeCounter? = nil,
                       loggedIn: Bool = true) -> ClaudeEnvironmentCheck {
    ClaudeEnvironmentCheck(probes: .init(
        candidatePaths: { ["/usr/bin/claude"] }, overridePath: { nil },
        isExecutable: { _ in true }, loginShellPATH: { nil },
        childEnvironment: { [:] },
        shellDivergence: { _ in .init(names: [], probeSucceeded: true) },
        capture: { _, arguments, _ in
            if arguments == ["--version"] {
                counter?.increment()
                return .init(stdout: "2.1.236 (Claude Code)", exit: .exited(code: 0))
            }
            return loggedIn
                ? .init(stdout: #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "user@example.com", "subscriptionType": "max"}"#,
                        exit: .exited(code: 0))
                : .init(stdout: #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#,
                        exit: .exited(code: 1))
        },
        now: { Date() }))
}

/// Resolution #13 says dollar figures are gated on "auth type". Keying that
/// off `subscriptionType` alone is wrong: an `ANTHROPIC_API_KEY` in this
/// app's environment overrides a subscription, and Overture spawns every
/// agent headless where Claude Code always prefers the key — so a Max user
/// with a stray key really is being billed per token.
@Suite @MainActor struct EffectiveCostGatingTests {
    private func services(account: ClaudeAccount,
                          environment: [String: String]) throws -> AppServices {
        let services = try AppServices(inMemory: true)
        services.applyForTesting(ClaudeReadiness(
            cli: CLIStatus(installation: .found(URL(fileURLWithPath: "/usr/bin/claude")),
                           version: .supported(SemanticVersion(2, 1, 231))),
            auth: .signedIn(account),
            effectiveCredential: CredentialPrecedence.resolve(
                account: account, childEnvironment: environment),
            checkedAt: Date()))
        return services
    }

    private var maxSubscriber: ClaudeAccount {
        ClaudeAccount(loggedIn: true, authMethod: .claudeAI,
                      email: "user@example.com", subscriptionType: "max")
    }

    @Test func aSubscriptionAloneShowsEstimatesNotExactDollars() throws {
        let services = try services(account: maxSubscriber, environment: [:])
        #expect(services.showsExactCosts == false)
    }

    /// Same subscription, but a key in the environment: the dollars are real.
    @Test func anAPIKeyOverrideMakesTheDollarsReal() throws {
        var account = maxSubscriber
        account.apiKeySource = "ANTHROPIC_API_KEY"
        let services = try services(account: account,
                                    environment: ["ANTHROPIC_API_KEY": "sk-ant-x"])
        #expect(services.showsExactCosts)
    }

    @Test func plainAPIKeyBillingShowsExactDollars() throws {
        let account = ClaudeAccount(loggedIn: true, authMethod: .apiKey,
                                    apiKeySource: "ANTHROPIC_API_KEY")
        let services = try services(account: account,
                                    environment: ["ANTHROPIC_API_KEY": "sk-ant-x"])
        #expect(services.showsExactCosts)
    }

    /// `claude setup-token` tokens bill a subscription. Their status shape has
    /// no plan, which used to read as "not a subscription" → exact dollars.
    @Test func aLongLivedOAuthTokenShowsEstimates() throws {
        let account = ClaudeAccount(loggedIn: true, authMethod: .oauthToken)
        let services = try services(account: account,
                                    environment: ["CLAUDE_CODE_OAUTH_TOKEN": "t"])
        #expect(services.showsExactCosts == false)
    }

    @Test func noProbeYetShowsEstimates() throws {
        let services = try AppServices(inMemory: true)
        #expect(services.showsExactCosts == false)
        #expect(services.canSpawn == false)
    }
}

@Suite @MainActor struct AuthInterruptionTests {
    /// Never auto-retried (spec 01 §7.4): it raises a flag the UI turns into a
    /// sign-in affordance.
    @Test func anAuthFailureRaisesTheSignInFlag() async throws {
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(stubCheck(loggedIn: false))
        await services.handleAuthenticationFailure()
        #expect(services.authInterrupted)
        #expect(services.canSpawn == false)
    }

    /// A rejected API key still reports as signed in, so the automatic probe
    /// after a failure must not declare it fixed — and neither may a focus
    /// event. A person checking again does.
    @Test func onlyADeliberateCheckClearsTheFlag() async throws {
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(stubCheck())
        await services.handleAuthenticationFailure()
        #expect(services.canSpawn, "the probe reports signed in")
        #expect(services.authInterrupted, "but that doesn't prove the credential works")
        await services.refreshClaude(reason: .becameActive)
        #expect(services.authInterrupted)
        await services.refreshClaude(reason: .manual)
        #expect(services.authInterrupted == false)
    }

    @Test func aSuccessfulTurnClearsTheFlag() async throws {
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(stubCheck())
        await services.handleAuthenticationFailure()
        services.noteSuccessfulTurn()
        #expect(services.authInterrupted == false)
    }

    /// Focus and wake events arrive in bursts; only deliberate refreshes
    /// should spawn a process every time.
    @Test func backgroundRefreshesAreDebounced() async throws {
        let services = try AppServices(inMemory: true)
        let counter = ProbeCounter()
        services.useEnvironmentCheck(stubCheck(counter: counter))
        await services.refreshClaude(reason: .launch)
        await services.refreshClaude(reason: .becameActive)
        await services.refreshClaude(reason: .wake)
        #expect(counter.value == 1)
        await services.refreshClaude(reason: .manual)
        #expect(counter.value == 2)
    }
}

/// Before any agent starts, Overture confirms Claude Code can authenticate.
/// A dead login otherwise surfaces only after a run has begun — for an
/// unattended run, possibly hours later.
@Suite @MainActor struct PreflightTests {
    @Test func aFreshAnswerIsReusedAndAStaleOneIsRechecked() async throws {
        let counter = ProbeCounter()
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(stubCheck(counter: counter))
        var clock = Date(timeIntervalSince1970: 1_000_000)
        services.now = { clock }

        #expect(await services.ensureReadyToRun())
        #expect(counter.value == 1)
        clock.addTimeInterval(60)
        #expect(await services.ensureReadyToRun())
        #expect(counter.value == 1, "a one-minute-old answer should be reused")
        clock.addTimeInterval(AppServices.preflightMaxAge)
        #expect(await services.ensureReadyToRun())
        #expect(counter.value == 2)
    }

    /// `auth status` reports an expired, unrefreshable login as signed out.
    @Test func anExpiredLoginIsCaughtBeforeAnythingStarts() async throws {
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(stubCheck(loggedIn: false))
        #expect(await services.ensureReadyToRun() == false)
    }

    @Test func anAuthenticationFailureBlocksUntilADeliberateCheck() async throws {
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(stubCheck())
        await services.handleAuthenticationFailure()
        #expect(await services.ensureReadyToRun() == false)
        await services.refreshClaude(reason: .manual)
        #expect(await services.ensureReadyToRun())
    }

    /// Offline coordinator tests drive a stand-in `claude`; they must not
    /// probe the real machine.
    @Test func theTestStandInSkipsTheProbe() async throws {
        let counter = ProbeCounter()
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(stubCheck(counter: counter))
        services.claudeURLOverride = URL(fileURLWithPath: "/bin/echo")
        #expect(await services.ensureReadyToRun())
        #expect(counter.value == 0)
    }
}
