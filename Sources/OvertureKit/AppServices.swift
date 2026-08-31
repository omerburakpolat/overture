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
        if case .ready(let readiness) = onboarding { return readiness.claudeURL }
        return nil
    }

    public var authStatus: AuthStatus? {
        if case .ready(let readiness) = onboarding { return readiness.auth }
        return nil
    }

    public init(inMemory: Bool = false) throws {
        container = try OvertureStore.container(inMemory: inMemory)
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
        processManager = ProcessManager(
            journalURL: supportDir.appendingPathComponent("running-agents.json"))
    }

    public func runOnboarding() async {
        onboarding = await OnboardingCheck.run()
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
