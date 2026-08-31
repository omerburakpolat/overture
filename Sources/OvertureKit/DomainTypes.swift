import Foundation
import ClaudeKit

// String-backed enums shared by the schema and the engine. Raw values are the
// spec's user-visible spellings (hyphenated where spec 04 §2.1 spells them
// that way) — they are what lands in the store, so they live forever.

/// Board column (spec 02 §3.2). A stored user-facing fact; the agent
/// lifecycle *drives* transitions but never fights the user.
public enum Column: String, Codable, Sendable, CaseIterable, Equatable {
    case backlog, plan, inProgress, testing, review, done
}

/// Runtime sub-state, orthogonal to the column (spec 04 §2.1, full set per
/// resolution #6). Drives the card's live visuals; failures are sub-states,
/// not column regressions.
public enum CardSubState: String, Codable, Sendable, CaseIterable, Equatable {
    case idle
    case drafting
    case planning
    case awaitingApproval = "awaiting-approval"
    case running
    case queued
    case needsInput = "needs-input"
    case interrupted
    case testingRunning = "testing-running"
    case manual
    case testsFailed = "tests-failed"
    case mergeConflict = "merge-conflict"
    case error

    /// Sub-states that pin a card to its column (spec 04 §2.3: "any drag of a
    /// card whose agent is `running`" is rejected; agent test runs count).
    public var pinsCard: Bool { self == .running || self == .testingRunning }
}

/// Why a run exists (resolution #4). The schema stores card *subState*; the
/// engine takes the run kind as an input — `result` events move cards only
/// for autonomous execution runs.
public enum AgentRunKind: String, Codable, Sendable, CaseIterable, Equatable {
    case interactiveChat, planning, autonomousRun, testRun

    /// Bridge from ClaudeKit's supervisor-side kind (same cases by design).
    public init(_ kind: RunKind) {
        self = AgentRunKind(rawValue: kind.rawValue) ?? .interactiveChat
    }
}

/// How a project executes cards (spec 02 §3.1).
public enum ExecutionMode: String, Codable, Sendable, CaseIterable, Equatable {
    case worktreePerCard, singleDirectory
}

/// What a session was spawned for (spec 02 §3.1).
public enum SessionKind: String, Codable, Sendable, CaseIterable, Equatable {
    case work, plan, ticketAuthoring, testing
}

/// A card's one primary thread vs auxiliary runs (spec 04 §4).
public enum SessionRole: String, Codable, Sendable, CaseIterable, Equatable {
    case primary, test
}

/// How a session ended (spec 02 §3.1).
public enum ExitReason: String, Codable, Sendable, CaseIterable, Equatable {
    case completed, interrupted, failed, orphaned
}

/// Curated activity-feed kinds (spec 02 §3.1). Only milestone tool use is
/// persisted — the transcript already has the full record.
public enum EventKind: String, Codable, Sendable, CaseIterable, Equatable {
    case cardCreated, columnChanged, agentStarted, agentFinished
    case agentNeedsInput, toolUse, testRunFinished, prOpened, prMerged
    case deploymentReady, userNote
}

/// Test-run mechanics (spec 02 §3.1).
public enum TestKind: String, Codable, Sendable, CaseIterable, Equatable {
    case commandRun, agentDriven
}

/// Test-run lifecycle (spec 02 §3.1).
public enum TestStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case running, passed, failed, aborted
}

/// Verdict recorded on a finished run — includes `manual-pass` for the
/// Testing→Review "looks good" drag (resolution #6, spec 04 §2.3).
public enum TestVerdict: String, Codable, Sendable, CaseIterable, Equatable {
    case pass, fail
    case manualPass = "manual-pass"
}

/// Approve→Done strategy (spec 04 §9.1; squash is the assumed default).
public enum MergeStrategy: String, Codable, Sendable, CaseIterable, Equatable {
    case squashMergeLocally = "squash-merge-locally"
    case openPullRequest = "open-pull-request"
}

/// Persistable mirror of the CLI permission posture. Configures the
/// *autonomous* profile only (resolution #10); interactive chats always run
/// manual.
public enum PermissionMode: String, Codable, Sendable, CaseIterable, Equatable {
    case manual, plan, acceptEdits, bypassPermissions

    /// The ClaudeKit spawn profile this mode maps to.
    public var profile: ClaudeCLI.PermissionProfile {
        switch self {
        case .manual: .askMe
        case .plan: .plan
        case .acceptEdits: .autonomous
        case .bypassPermissions: .fullAuto
        }
    }
}

/// One (cwd, transcriptPath, from, to) span of a session's life
/// (resolution #5: resume can move where new transcript lines land, so a
/// SessionRef holds an ordered *list* of these, not one flat pair).
public struct SessionPathSegment: Codable, Sendable, Equatable {
    public var cwd: String
    public var transcriptPath: String
    public var from: Date
    /// nil while this segment is the live tail.
    public var to: Date?

    public init(cwd: String, transcriptPath: String, from: Date, to: Date? = nil) {
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.from = from
        self.to = to
    }
}

/// One precise failure from an agent test verdict (resolution #6:
/// `TestRun.verdict` includes `failures[]`).
public struct TestFailure: Codable, Sendable, Equatable {
    public var title: String
    public var detail: String
    public var location: String?

    public init(title: String, detail: String, location: String? = nil) {
        self.title = title
        self.detail = detail
        self.location = location
    }
}
