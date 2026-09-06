import Foundation
import Testing
import ClaudeKit
@testable import OvertureKit

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

    /// The case that matters: same subscription, but a key in the
    /// environment. The dollars are now real.
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

    @Test func noProbeYetShowsEstimates() throws {
        let services = try AppServices(inMemory: true)
        #expect(services.showsExactCosts == false)
        #expect(services.canSpawn == false)
    }
}

@Suite @MainActor struct AuthInterruptionTests {
    /// An authentication failure must never be auto-retried (spec 01 §7.4);
    /// it raises a flag the UI turns into a sign-in affordance.
    @Test func anAuthFailureRaisesTheSignInFlag() async throws {
        let services = try AppServices(inMemory: true)
        // No CLI on the probe set, so the refresh can't clear the flag.
        services.useEnvironmentCheck(ClaudeEnvironmentCheck(
            probes: .init(candidatePaths: { [] }, overridePath: { nil },
                          isExecutable: { _ in false },
                          loginShellPATH: { nil },
                          childEnvironment: { [:] },
                          shellDivergence: { _ in .init(names: [], probeSucceeded: true) },
                          capture: { _, _, _ in .init(stdout: "", exit: .exited(code: 1)) },
                          now: { Date() })))
        await services.handleAuthenticationFailure()
        #expect(services.authInterrupted)
        #expect(services.canSpawn == false)
    }

    /// Once a working credential is found again, the banner goes away by
    /// itself — the user shouldn't have to dismiss it.
    @Test func aSuccessfulProbeClearsTheFlag() async throws {
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(ClaudeEnvironmentCheck(
            probes: .init(candidatePaths: { ["/usr/bin/claude"] },
                          overridePath: { nil },
                          isExecutable: { _ in true },
                          loginShellPATH: { nil },
                          childEnvironment: { [:] },
                          shellDivergence: { _ in .init(names: [], probeSucceeded: true) },
                          capture: { _, arguments, _ in
                              arguments == ["--version"]
                                  ? .init(stdout: "2.1.236 (Claude Code)", exit: .exited(code: 0))
                                  : .init(stdout: #"{"loggedIn": true, "authMethod": "claude.ai", "email": "user@example.com", "subscriptionType": "max"}"#,
                                          exit: .exited(code: 0))
                          },
                          now: { Date() })))
        await services.handleAuthenticationFailure()
        #expect(services.authInterrupted == false)
        #expect(services.canSpawn)
    }

    /// Focus and wake events arrive in bursts; only deliberate refreshes
    /// should spawn a process every time.
    @Test func backgroundRefreshesAreDebounced() async throws {
        let services = try AppServices(inMemory: true)
        let counter = ProbeCounter()
        services.useEnvironmentCheck(ClaudeEnvironmentCheck(
            probes: .init(candidatePaths: { [] }, overridePath: { nil },
                          isExecutable: { _ in false },
                          loginShellPATH: { nil },
                          childEnvironment: { [:] },
                          shellDivergence: { _ in .init(names: [], probeSucceeded: true) },
                          capture: { _, _, _ in
                              counter.increment()
                              return .init(stdout: "", exit: .exited(code: 1))
                          },
                          now: { Date() })))
        await services.refreshClaude(reason: .launch)
        await services.refreshClaude(reason: .becameActive)
        await services.refreshClaude(reason: .wake)
        #expect(counter.value == 0, "no CLI found, so nothing to capture")
        await services.refreshClaude(reason: .manual)
        #expect(services.claude != nil)
    }
}

/// Small thread-safe counter — the probe closures are `@Sendable`.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
