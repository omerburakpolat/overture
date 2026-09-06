import Foundation
import SwiftData
import ClaudeKit
import GitKit
import VercelKit

/// Composition root the app target builds once and injects. Owns the store,
/// the process manager, and what Overture knows about the Claude Code CLI.
@MainActor
@Observable
public final class AppServices {
    public let container: ModelContainer
    public let processManager: ProcessManager

    /// The last probe of the CLI: where it is, whether it is usable, who it
    /// is signed in as, and which credential the app's own spawns will use.
    /// Nil until the first probe completes.
    public private(set) var claude: ClaudeReadiness?

    /// Set when a running session failed to authenticate, so the board can
    /// offer a sign-in rather than showing a stack trace. Cleared by a probe
    /// that finds a working credential.
    public private(set) var authInterrupted = false

    private var environmentCheck = ClaudeEnvironmentCheck()
    private var lastRefresh: Date?
    private var refreshInFlight = false

    /// Resolved `claude` executable. Present whenever a binary was found —
    /// including when it is signed out or too old, because sign-in and the
    /// path override both need something to run.
    public var claudeURL: URL? {
        claudeURLOverride ?? claude?.cli.executableURL
    }

    /// Test seam: a stand-in `claude` (a script replaying recorded
    /// stream-json shapes) so coordinator flows run offline. Never set by
    /// the app.
    public var claudeURLOverride: URL?

    public var account: ClaudeAccount? { claude?.auth.account }

    /// Whether a session can start right now.
    public var canSpawn: Bool { claudeURLOverride != nil || claude?.canSpawn == true }

    /// Resolution #13: dollars are shown as real money only when the user is
    /// actually billed per token. Keyed off the resolved credential rather
    /// than `subscriptionType`, because an `ANTHROPIC_API_KEY` in this app's
    /// environment overrides a subscription and makes the dollars real again.
    public var showsExactCosts: Bool {
        guard let credential = claude?.effectiveCredential else { return false }
        switch credential.source {
        case .apiKeyEnvironment, .apiKeyHelper, .authTokenEnvironment,
             .cloudProvider:
            return true
        case .oauthTokenEnvironment, .profile, .storedLogin, .none:
            return account?.isSubscription == false
        }
    }

    /// `journalURL` lets tests keep their orphan journal away from the real
    /// one in Application Support (a test teardown must never clear rows the
    /// running app owns).
    public init(inMemory: Bool = false, journalURL: URL? = nil) throws {
        container = try OvertureStore.container(inMemory: inMemory)
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
        processManager = ProcessManager(
            journalURL: journalURL
                ?? supportDir.appendingPathComponent("running-agents.json"))
    }

    /// Why a probe is happening. Only `.manual` bypasses the debounce — the
    /// rest fire on app focus and wake, which can arrive in bursts.
    public enum RefreshReason: Sendable {
        case launch, manual, becameActive, wake, afterSignIn, afterAuthFailure

        var bypassesDebounce: Bool {
            switch self {
            case .manual, .afterSignIn, .afterAuthFailure, .launch: true
            case .becameActive, .wake: false
            }
        }
    }

    public static let refreshDebounce: TimeInterval = 30

    @discardableResult
    public func refreshClaude(reason: RefreshReason = .manual) async -> ClaudeReadiness? {
        if !reason.bypassesDebounce, let lastRefresh,
           Date().timeIntervalSince(lastRefresh) < Self.refreshDebounce {
            return claude
        }
        guard !refreshInFlight else { return claude }
        refreshInFlight = true
        defer { refreshInFlight = false }

        let readiness = await environmentCheck.run()
        claude = readiness
        lastRefresh = Date()
        if readiness.canSpawn { authInterrupted = false }
        return readiness
    }

    /// Runs `claude auth logout`. This signs the CLI out everywhere on the
    /// machine, not just for Overture — the caller must have confirmed that.
    public func signOutOfClaude() async -> Result<Void, ProbeFailure> {
        guard let claudeURL = claude?.cli.executableURL else {
            return .failure(ProbeFailure(kind: .launchFailed("no CLI found")))
        }
        let result = await environmentCheck.signOut(claudeURL: claudeURL)
        await refreshClaude(reason: .manual)
        return result
    }

    /// A session reported an authentication failure. Never auto-retried
    /// (spec 01 §7.4) — re-probe and let the UI offer a sign-in.
    public func handleAuthenticationFailure() async {
        authInterrupted = true
        await refreshClaude(reason: .afterAuthFailure)
    }

    /// Test seam: installs a readiness snapshot without running a probe.
    public func applyForTesting(_ readiness: ClaudeReadiness) {
        claude = readiness
    }

    /// Lets tests inject a probe set instead of touching the real machine.
    public func useEnvironmentCheck(_ check: ClaudeEnvironmentCheck) {
        environmentCheck = check
    }

    /// Done cards leave the board after 14 days (spec 04 assumption #7);
    /// archived cards stay queryable via "Show archived". Run at launch.
    public func autoArchiveDoneCards(olderThan days: Int = 14) {
        let context = container.mainContext
        let cutoff = Calendar.current.date(byAdding: .day, value: -days,
                                           to: .now) ?? .now
        let descriptor = FetchDescriptor<Card>(
            predicate: #Predicate {
                $0.archivedAt == nil && $0.doneAt != nil && $0.doneAt! < cutoff
            })
        for card in (try? context.fetch(descriptor)) ?? [] {
            card.archivedAt = .now
        }
        try? context.save()
    }

    /// Relaunch reconciliation (resolution #7/#25): dead journal rows mark
    /// their cards resumable; still-alive orphans are reported for the UI.
    public func reconcileOrphans() async -> ProcessManager.Reconciliation {
        let reconciliation = await processManager.reconcile()
        let context = container.mainContext
        for entry in reconciliation.dead {
            let target = entry.cardID
            var descriptor = FetchDescriptor<Card>(
                predicate: #Predicate { $0.id == target })
            descriptor.fetchLimit = 1
            if let card = try? context.fetch(descriptor).first {
                if card.subState.pinsCard || card.subState == .needsInput {
                    card.subState = .interrupted
                }
                for session in card.sessions where session.exitReason == nil {
                    session.exitReason = .orphaned
                    session.endedAt = .now
                }
            }
        }
        try? context.save()
        return reconciliation
    }
}
