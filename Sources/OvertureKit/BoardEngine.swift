import Foundation
import SwiftData

/// Every card movement — user drag or automatic — is one `CardTransition`
/// applied through `BoardEngine.apply`. Nothing else mutates `card.column`.
///
/// Drags are commands, not bookkeeping (spec 04 §1): an allowed drag CAUSES
/// what its destination means, expressed as returned `Effect`s the caller
/// (store layer) performs. Rejected drags throw `TransitionError` with the
/// user-facing reason for the bounce-back toast.
public enum CardTransition: Sendable, Equatable {
    // User drags (spec 04 §2.3) — `to` is the drop target.
    case drag(to: Column)
    // Explicit actions.
    case startPlan               // "Plan" button (≡ drag Backlog→Plan)
    case approvePlan             // Plan approval UI
    case requestPlanChanges      // stays in Plan; session iterates
    case abandonPlan             // Plan → Backlog
    case approveToDone           // Review/Testing approval act (resolution #16)
    case requestChanges          // Review → In Progress with feedback
    case reopen                  // Done → In Progress (fly-back)
    case resumeRun               // idle In Progress card: run the agent again
    case archive
    // Automatic (system-triggered, spec 04 §2.2).
    case planReady               // ExitPlanMode arrived
    case runEnded(success: Bool, runKind: AgentRunKind)
    case testsPassed(verdict: TestVerdict)
    case testsFailed
    case queued                  // told to run, no slot free
    case runSlotAvailable        // queue promotion
    case interrupted
    case errored
    case mergeConflictDetected
}

/// What the store layer must do after a transition commits.
public enum TransitionEffect: Sendable, Equatable {
    case startPlanSession
    case startExecution          // spawn/resume autonomous run
    case startAgentTests
    case prepareFixMessage       // composer pre-filled; autoSend per project
    case resumeSessionForFeedback
    case openMergeSheet
    case promoteNextQueuedCard
    case createWorktree          // worktree mode, at Plan entry (resolution #1)
    case removeWorktree
    case announceMove(from: Column, to: Column)  // a11y + toast + animation
    case flyBack                 // the Done→In Progress signature moment
}

public struct TransitionError: Error, Sendable, Equatable {
    /// User-facing bounce-back reason (spec 04 §2.3 wording).
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
}

public enum BoardEngine {
    /// Validates and applies one transition. Mutates the card (column,
    /// subState, stamps, queue fields), appends the ActivityEvent, and
    /// returns effects. The caller owns the ModelContext save.
    @discardableResult
    public static func apply(_ transition: CardTransition, to card: Card,
                             in context: ModelContext) throws -> [TransitionEffect] {
        // Running cards are pinned to their column — no exceptions
        // (spec 04 §2.3 last row). Automatic transitions bypass the pin.
        if case .drag = transition, card.subState.pinsCard {
            throw TransitionError("Interrupt the agent first.")
        }

        let from = card.column
        let effects: [TransitionEffect]

        switch transition {
        case .drag(let to):
            effects = try dragEffects(card: card, from: from, to: to)
        case .startPlan:
            effects = try dragEffects(card: card, from: from, to: .plan)
        case .approvePlan:
            guard from == .plan, card.subState == .awaitingApproval else {
                throw TransitionError("No plan awaiting approval.")
            }
            card.planApprovedAt = .now
            move(card, to: .inProgress, subState: .running)
            effects = [.startExecution, .announceMove(from: from, to: .inProgress)]
        case .requestPlanChanges:
            guard from == .plan else { throw TransitionError("Not planning.") }
            card.subState = .planning
            effects = []
        case .abandonPlan:
            guard from == .plan else { throw TransitionError("Not planning.") }
            move(card, to: .backlog, subState: .idle)
            effects = [.removeWorktree, .announceMove(from: from, to: .backlog)]
        case .approveToDone:
            guard from == .review || from == .testing else {
                throw TransitionError("Approve from Review (or Testing).")
            }
            card.doneAt = .now
            move(card, to: .done, subState: .idle)
            effects = [.openMergeSheet, .promoteNextQueuedCard,
                       .announceMove(from: from, to: .done)]
        case .requestChanges:
            guard from == .review else {
                throw TransitionError("Request changes from Review.")
            }
            move(card, to: .inProgress, subState: .running)
            effects = [.resumeSessionForFeedback,
                       .announceMove(from: from, to: .inProgress)]
        case .reopen:
            guard from == .done else {
                throw TransitionError("Only Done cards reopen.")
            }
            move(card, to: .inProgress, subState: .running)
            effects = [.flyBack, .startExecution,
                       .announceMove(from: from, to: .inProgress)]
        case .resumeRun:
            guard from == .inProgress, !card.subState.pinsCard else {
                throw TransitionError("Already running.")
            }
            card.subState = .running
            effects = [.startExecution]
        case .archive:
            card.archivedAt = .now
            effects = []

        // Automatic transitions.
        case .planReady:
            guard from == .plan else { throw TransitionError("Not planning.") }
            card.subState = .awaitingApproval
            effects = []
        case .runEnded(let success, let runKind):
            // Resolution #4: only autonomous execution runs move cards.
            guard runKind == .autonomousRun else { effects = []; break }
            guard from == .inProgress else { effects = []; break }
            guard success else {
                card.subState = .error
                effects = [.promoteNextQueuedCard]
                break
            }
            if card.project?.agentTestingEnabled == true {
                card.testedAt = .now
                move(card, to: .testing, subState: .testingRunning)
                effects = [.startAgentTests, .promoteNextQueuedCard,
                           .announceMove(from: from, to: .testing)]
            } else {
                card.reviewedAt = .now
                move(card, to: .review, subState: .idle)
                effects = [.promoteNextQueuedCard,
                           .announceMove(from: from, to: .review)]
            }
        case .testsPassed:
            // The verdict itself lands on the TestRun; the card just advances.
            guard from == .testing else { effects = []; break }
            card.reviewedAt = .now
            move(card, to: .review, subState: .idle)
            effects = [.announceMove(from: from, to: .review)]
        case .testsFailed:
            guard from == .testing else { effects = []; break }
            card.fixCycleCount += 1
            if card.fixCycleCount > 2 {
                // Cycle cap (spec 04 §2.2): force Review with the red badge.
                move(card, to: .review, subState: .testsFailed)
                effects = [.announceMove(from: from, to: .review)]
            } else {
                move(card, to: .inProgress, subState: .needsInput)
                effects = [.prepareFixMessage,
                           .announceMove(from: from, to: .inProgress)]
            }
        case .queued:
            card.subState = .queued
            card.queuePosition = nextQueuePosition(for: card, in: context)
            effects = []
        case .runSlotAvailable:
            guard card.subState == .queued else { effects = []; break }
            card.subState = .running
            card.queuePosition = nil
            if card.column != .inProgress {
                move(card, to: .inProgress, subState: .running)
            }
            card.startedAt = card.startedAt ?? .now
            effects = [.startExecution]
        case .interrupted:
            card.subState = .interrupted   // column never regresses on failure
            effects = [.promoteNextQueuedCard]
        case .errored:
            card.subState = .error
            effects = [.promoteNextQueuedCard]
        case .mergeConflictDetected:
            guard from == .review else { effects = []; break }
            card.subState = .mergeConflict
            effects = []
        }

        if card.column != from {
            card.movedAt = .now
            ActivityLog.record(
                .columnChanged,
                "Moved \(from.displayName) → \(card.column.displayName)",
                payload: BlobCoding.encode(
                    ["from": from.rawValue, "to": card.column.rawValue]),
                on: card, in: context)
        }
        return effects
    }

    // MARK: - The drag matrix (spec 04 §2.3, verbatim semantics)

    private static func dragEffects(card: Card, from: Column,
                                    to: Column) throws -> [TransitionEffect] {
        // Same-column drop = reorder, handled by ColumnOrdering upstream.
        if from == to { return [] }
        switch (from, to) {
        case (.backlog, .plan):
            move(card, to: .plan, subState: .planning)
            card.startedAt = card.startedAt ?? .now
            // Worktree created at PLAN entry in worktree mode (resolution #1).
            return worktreeEffects(card) + [.startPlanSession,
                                            .announceMove(from: from, to: .plan)]
        case (.backlog, .inProgress):
            move(card, to: .inProgress, subState: .running)
            card.startedAt = card.startedAt ?? .now
            return worktreeEffects(card) + [.startExecution,
                                            .announceMove(from: from, to: .inProgress)]
        case (.backlog, .done):
            throw TransitionError("Nothing to complete — “won’t do” is Archive.")
        case (.backlog, _):
            throw TransitionError("Nothing to \(to.rawValue) yet.")
        case (.plan, .backlog):
            move(card, to: .backlog, subState: .idle)
            return [.removeWorktree, .announceMove(from: from, to: .backlog)]
        case (.plan, .inProgress):
            guard card.subState == .awaitingApproval else {
                throw TransitionError("Wait for the plan, or interrupt first.")
            }
            card.planApprovedAt = .now
            move(card, to: .inProgress, subState: .running)
            return [.startExecution, .announceMove(from: from, to: .inProgress)]
        case (.plan, _):
            throw TransitionError("Approve or abandon the plan first.")
        case (.inProgress, .plan):
            move(card, to: .plan, subState: .planning)
            return [.startPlanSession, .announceMove(from: from, to: .plan)]
        case (.inProgress, .backlog):
            guard card.subState == .queued else {
                throw TransitionError(
                    "Started cards own changes — use Abandon in the card menu.")
            }
            card.queuePosition = nil
            move(card, to: .backlog, subState: .idle)
            return [.announceMove(from: from, to: .backlog)]
        case (.inProgress, .testing):
            move(card, to: .testing, subState: .manual)
            return [.announceMove(from: from, to: .testing)]
        case (.inProgress, .review):
            move(card, to: .review, subState: .idle)
            return [.announceMove(from: from, to: .review)]
        case (.inProgress, .done):
            throw TransitionError("Review is the approval gate — two-step it.")
        case (.inProgress, .inProgress):
            return []  // unreachable: same-column handled above
        case (.testing, .inProgress):
            move(card, to: .inProgress, subState: .needsInput)
            return [.resumeSessionForFeedback,
                    .announceMove(from: from, to: .inProgress)]
        case (.testing, .review):
            move(card, to: .review, subState: .idle)
            return [.announceMove(from: from, to: .review)]
        case (.testing, .done):
            // Same approval pipeline as Review→Done (resolution #16).
            card.doneAt = .now
            move(card, to: .done, subState: .idle)
            return [.openMergeSheet, .promoteNextQueuedCard,
                    .announceMove(from: from, to: .done)]
        case (.testing, _):
            throw TransitionError("Finish testing first.")
        case (.review, .inProgress):
            move(card, to: .inProgress, subState: .running)
            return [.resumeSessionForFeedback,
                    .announceMove(from: from, to: .inProgress)]
        case (.review, .testing):
            move(card, to: .testing, subState: .manual)
            return [.announceMove(from: from, to: .testing)]
        case (.review, .done):
            card.doneAt = .now
            move(card, to: .done, subState: .idle)
            return [.openMergeSheet, .promoteNextQueuedCard,
                    .announceMove(from: from, to: .done)]
        case (.review, _):
            throw TransitionError("Reviewed work goes forward, not back.")
        case (.done, .inProgress):
            move(card, to: .inProgress, subState: .running)
            return [.flyBack, .startExecution,
                    .announceMove(from: from, to: .inProgress)]
        case (.done, _):
            throw TransitionError("Reopening always goes through In Progress.")
        }
    }

    private static func worktreeEffects(_ card: Card) -> [TransitionEffect] {
        card.project?.executionMode == .worktreePerCard ? [.createWorktree] : []
    }

    private static func move(_ card: Card, to column: Column,
                             subState: CardSubState) {
        card.column = column
        card.subState = subState
    }

    private static func nextQueuePosition(for card: Card,
                                          in context: ModelContext) -> Int {
        guard let projectID = card.project?.id else { return 0 }
        let descriptor = FetchDescriptor<Card>(
            predicate: #Predicate {
                $0.project?.id == projectID && $0.queuePosition != nil
            })
        let existing = (try? context.fetch(descriptor)) ?? []
        return (existing.compactMap(\.queuePosition).max() ?? -1) + 1
    }
}
