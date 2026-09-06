import Foundation
import SwiftData
import ClaudeKit
import GitKit
import VercelKit

/// Composition root the app target builds once and injects. Owns the store,
/// the process manager, and the onboarding outcome.
@MainActor
@Observable
public final class AppServices {
    public let container: ModelContainer
    public let processManager: ProcessManager
    public private(set) var onboarding: OnboardingCheck.Outcome?

    /// Resolved claude executable — nil until onboarding reaches `.ready`.
    public var claudeURL: URL? {
        if let claudeURLOverride { return claudeURLOverride }
        if case .ready(let readiness) = onboarding { return readiness.claudeURL }
        return nil
    }

    /// Test seam: a stand-in `claude` (a script replaying recorded
    /// stream-json shapes) so coordinator flows run offline. Never set by
    /// the app.
    public var claudeURLOverride: URL?

    public var authStatus: AuthStatus? {
        if case .ready(let readiness) = onboarding { return readiness.auth }
        return nil
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

    public func runOnboarding() async {
        onboarding = await OnboardingCheck.run()
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
