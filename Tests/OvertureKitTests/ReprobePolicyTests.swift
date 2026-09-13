import Foundation
import Testing
import ClaudeKit
@testable import OvertureKit

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// One increment per full check (`--version` runs once per check).
private func countingCheck(_ counter: ProbeCounter, loggedIn: Bool) -> ClaudeEnvironmentCheck {
    ClaudeEnvironmentCheck(probes: .init(
        candidatePaths: { ["/usr/bin/claude"] }, overridePath: { nil },
        isExecutable: { _ in true }, loginShellPATH: { nil },
        childEnvironment: { [:] },
        shellDivergence: { _ in .init(names: [], probeSucceeded: true) },
        capture: { _, arguments, _ in
            if arguments == ["--version"] {
                counter.increment()
                return .init(stdout: "2.1.236 (Claude Code)", exit: .exited(code: 0))
            }
            return loggedIn
                ? .init(stdout: #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty"}"#,
                        exit: .exited(code: 0))
                : .init(stdout: #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#,
                        exit: .exited(code: 1))
        },
        now: { Date() }))
}

/// Switching back to the app shouldn't spawn `claude` every time once
/// everything works — but must keep checking while something is broken,
/// because that is how "sign in from a terminal, ⌘-Tab back" resolves itself.
@Suite @MainActor struct ReprobePolicyTests {
    @Test func switchingBackToAWorkingSetupSpawnsNothing() async throws {
        let counter = ProbeCounter()
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(countingCheck(counter, loggedIn: true))
        var clock = Date(timeIntervalSince1970: 1_000_000)
        services.now = { clock }

        await services.refreshClaude(reason: .launch)
        #expect(counter.value == 1)
        clock.addTimeInterval(60)
        await services.refreshClaude(reason: .becameActive)
        await services.refreshClaude(reason: .wake)
        #expect(counter.value == 1)
        clock.addTimeInterval(AppServices.readyRecheckInterval)
        await services.refreshClaude(reason: .becameActive)
        #expect(counter.value == 2, "a working setup is still re-checked occasionally")
    }

    @Test func switchingBackToABrokenSetupChecksAgain() async throws {
        let counter = ProbeCounter()
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(countingCheck(counter, loggedIn: false))
        var clock = Date(timeIntervalSince1970: 1_000_000)
        services.now = { clock }

        await services.refreshClaude(reason: .launch)
        clock.addTimeInterval(60)
        await services.refreshClaude(reason: .becameActive)
        #expect(counter.value == 2)
    }

    /// After an auth failure the probe may say "ready" (a rejected key does),
    /// so focus keeps checking rather than going quiet.
    @Test func afterAnAuthFailureFocusStillChecks() async throws {
        let counter = ProbeCounter()
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(countingCheck(counter, loggedIn: true))
        var clock = Date(timeIntervalSince1970: 1_000_000)
        services.now = { clock }

        await services.refreshClaude(reason: .launch)
        await services.handleAuthenticationFailure()
        let afterFailure = counter.value
        clock.addTimeInterval(60)
        await services.refreshClaude(reason: .becameActive)
        #expect(counter.value == afterFailure + 1)
        #expect(services.authInterrupted, "an ambient check never lifts the stop")
    }

    /// Settings wants fresh data even when everything works, but a user
    /// flicking between panes shouldn't spawn a process each time.
    @Test func openingSettingsIsDebouncedButNotSilenced() async throws {
        let counter = ProbeCounter()
        let services = try AppServices(inMemory: true)
        services.useEnvironmentCheck(countingCheck(counter, loggedIn: true))
        var clock = Date(timeIntervalSince1970: 1_000_000)
        services.now = { clock }

        await services.refreshClaude(reason: .launch)
        clock.addTimeInterval(10)
        await services.refreshClaude(reason: .settingsOpened)
        #expect(counter.value == 1)
        clock.addTimeInterval(AppServices.refreshDebounce)
        await services.refreshClaude(reason: .settingsOpened)
        #expect(counter.value == 2)
    }
}
