import Foundation
import SwiftData
import ClaudeKit
import GitKit
import VercelKit

/// A CLI chosen by hand in Settings. `UserDefaults` is the right home: this
/// is app configuration, not board data, and nothing credential-bearing is
/// ever stored — only a path.
let claudeOverrideDefaultsKey = "claudeExecutableOverridePath"

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

    private var environmentCheck = ClaudeEnvironmentCheck(probes: AppServices.liveProbes())
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

    public var account: ClaudeAccount? { claude?.auth.signedInAccount }

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
             .cloudProvider, .profile:
            return true
        case .oauthTokenEnvironment:
            // `claude setup-token` tokens authenticate with a subscription.
            // Their status shape carries no plan, which used to read as "not
            // a subscription" and show exact dollars.
            return false
        case .storedLogin, .none:
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

    /// Why a probe is happening. Deliberate checks bypass the debounce; focus
    /// and wake events arrive in bursts and do not.
    public enum RefreshReason: Sendable {
        case launch, manual, becameActive, wake, afterSignIn, afterAuthFailure
        /// Just before an agent process starts (see `ensureReadyToRun`).
        case preflight

        var bypassesDebounce: Bool {
            switch self {
            case .manual, .afterSignIn, .afterAuthFailure, .launch, .preflight: true
            case .becameActive, .wake: false
            }
        }

        /// Only a person acting — signing in, or pressing Check Again — may
        /// clear an authentication failure. An automatic probe can't: a
        /// rejected API key still reports as signed in.
        var clearsAuthInterruption: Bool {
            switch self {
            case .manual, .afterSignIn: true
            case .launch, .becameActive, .wake, .afterAuthFailure, .preflight: false
            }
        }
    }

    public static let refreshDebounce: TimeInterval = 30
    /// How old a readiness answer may be before an agent start re-checks it.
    public static let preflightMaxAge: TimeInterval = 120

    /// Test seam for the debounce and pre-flight clocks.
    @ObservationIgnored public var now: () -> Date = { Date() }

    @discardableResult
    public func refreshClaude(reason: RefreshReason = .manual) async -> ClaudeReadiness? {
        if !reason.bypassesDebounce, let lastRefresh,
           now().timeIntervalSince(lastRefresh) < Self.refreshDebounce {
            return claude
        }
        guard !refreshInFlight else { return claude }
        refreshInFlight = true
        defer { refreshInFlight = false }

        let readiness = await environmentCheck.run()
        claude = readiness
        lastRefresh = now()
        if readiness.canSpawn, reason.clearsAuthInterruption {
            authInterrupted = false
        }
        return readiness
    }

    /// Asked before any agent process starts. A dead login otherwise shows up
    /// only once a run has begun — for an unattended run, possibly hours
    /// later. `claude auth status` reports an expired, unrefreshable login as
    /// signed out in about a quarter of a second, without Overture reading any
    /// credential, so an answer older than `preflightMaxAge` is refreshed
    /// first.
    ///
    /// After an authentication failure this stays false until a person signs
    /// in or checks again: a rejected API key still reports as signed in, so
    /// no probe can prove it was fixed.
    public func ensureReadyToRun() async -> Bool {
        if authInterrupted { return false }
        if claudeURLOverride != nil { return true }
        let stale = lastRefresh.map {
            now().timeIntervalSince($0) >= Self.preflightMaxAge
        } ?? true
        if stale || claude?.canSpawn != true {
            await refreshClaude(reason: .preflight)
        }
        return claude?.canSpawn == true
    }

    /// A turn finished without error, so whatever broke authentication has
    /// recovered — lift the stop.
    public func noteSuccessfulTurn() {
        if authInterrupted { authInterrupted = false }
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

    /// A CLI chosen by hand in Settings, tried before the well-known paths.
    ///
    /// `UserDefaults` is the right home: it is app configuration, not board
    /// data. Nothing credential-bearing is ever stored here — only a path.
    public var hasClaudeExecutableOverride: Bool {
        UserDefaults.standard.string(forKey: claudeOverrideDefaultsKey) != nil
    }

    public func setClaudeExecutableOverride(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path,
                                      forKey: claudeOverrideDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(
                forKey: claudeOverrideDefaultsKey)
        }
        environmentCheck = ClaudeEnvironmentCheck(probes: Self.liveProbes())
    }

    /// The live probe set, with the Settings override wired in.
    static func liveProbes() -> ClaudeEnvironmentCheck.Probes {
        var probes = ClaudeEnvironmentCheck.Probes.live
        probes.overridePath = {
            UserDefaults.standard.string(forKey: claudeOverrideDefaultsKey)
        }
        return probes
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
