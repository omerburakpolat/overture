import Foundation
import SwiftData

// SwiftData stores enum-typed attributes unreliably across versions, so every
// enum field is persisted as its raw String (`*Raw`) with a computed, tolerant
// typed accessor — unknown raw values (from a future schema) degrade to a safe
// default instead of trapping. Codable collections (session path segments,
// test failures) are persisted as JSON `Data` blobs for the same reason.

/// Version 1 of the single global Overture store (resolution #2 — one store at
/// `~/Library/Application Support/Overture/Overture.store`, no per-repo DB).
public enum OvertureSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [Project.self, Card.self, Tag.self, SessionRef.self,
         ActivityEvent.self, TestRun.self, DeploymentRef.self]
    }

    // MARK: - Project

    @Model
    public final class Project {
        @Attribute(.unique) public var id: UUID
        public var name: String
        /// Absolute path to the repo root.
        public var path: String
        public var createdAt: Date
        /// Manual tile ordering on the home screen.
        public var sortOrder: Int

        /// Storage for ``executionMode``.
        public var executionModeRaw: String
        public var executionMode: ExecutionMode {
            get { ExecutionMode(rawValue: executionModeRaw) ?? .worktreePerCard }
            set { executionModeRaw = newValue.rawValue }
        }
        /// Default `<path>/.overture/worktrees` (excluded via
        /// `.git/info/exclude`, resolution #2); nil in single-dir mode.
        public var worktreeRoot: String?

        /// Template with a literal `{port}` placeholder (resolution #26 —
        /// `$PORT` env injection alone is insufficient, e.g. Vite).
        public var devServerCommand: String?
        public var devServerPort: Int?
        /// Regex matched against dev-server output to detect readiness.
        public var readyPattern: String?

        /// e.g. "npm test" — drives agent-testing default-on detection.
        public var testCommand: String?
        /// Whether execution runs route through Testing (spec 04 §2.2).
        public var agentTestingEnabled: Bool
        /// Auto-send the prepared fix message on a failing verdict
        /// (default off; cycle cap enforced by the engine).
        public var autoFixOnTestFailure: Bool

        /// Per-run budget cap in USD (spec 04 §14: default 10).
        public var runBudgetUSD: Double
        /// Ticket-draft one-shot cap (default 0.50).
        public var draftBudgetUSD: Double
        /// Agent test-run cap (default 3).
        public var testBudgetUSD: Double

        /// Storage for ``mergeStrategy``.
        public var mergeStrategyRaw: String
        public var mergeStrategy: MergeStrategy {
            get { MergeStrategy(rawValue: mergeStrategyRaw) ?? .squashMergeLocally }
            set { mergeStrategyRaw = newValue.rawValue }
        }

        public var vercelProjectID: String?
        public var vercelTeamID: String?
        /// "owner/repo", derived once from origin and cached.
        public var githubRemote: String?
        public var defaultBranch: String

        /// Storage for ``claudePermissionMode``. Configures the *autonomous*
        /// profile only (resolution #10).
        public var claudePermissionModeRaw: String
        public var claudePermissionMode: PermissionMode {
            get { PermissionMode(rawValue: claudePermissionModeRaw) ?? .acceptEdits }
            set { claudePermissionModeRaw = newValue.rawValue }
        }

        /// Worktree mode only; beyond this cap cards queue (spec 04 §7.4).
        public var maxParallelAgents: Int

        /// Per-project trust gate (resolution #12): `-p` skips workspace
        /// trust and runs the project's own hooks/MCP servers — nil means
        /// Overture has never been allowed to spawn here.
        public var trustedAt: Date?

        @Relationship(deleteRule: .cascade, inverse: \Card.project)
        public var cards: [Card]
        /// Tags are per-project (resolution #17).
        @Relationship(deleteRule: .cascade, inverse: \Tag.project)
        public var tags: [Tag]
        @Relationship(deleteRule: .cascade, inverse: \DeploymentRef.project)
        public var deployments: [DeploymentRef]

        public init(id: UUID = UUID(),
                    name: String,
                    path: String,
                    createdAt: Date = .now,
                    sortOrder: Int = 0,
                    executionMode: ExecutionMode = .worktreePerCard,
                    worktreeRoot: String? = nil,
                    devServerCommand: String? = nil,
                    devServerPort: Int? = nil,
                    readyPattern: String? = nil,
                    testCommand: String? = nil,
                    agentTestingEnabled: Bool = false,
                    autoFixOnTestFailure: Bool = false,
                    runBudgetUSD: Double = 10,
                    draftBudgetUSD: Double = 0.50,
                    testBudgetUSD: Double = 3,
                    mergeStrategy: MergeStrategy = .squashMergeLocally,
                    vercelProjectID: String? = nil,
                    vercelTeamID: String? = nil,
                    githubRemote: String? = nil,
                    defaultBranch: String = "main",
                    claudePermissionMode: PermissionMode = .acceptEdits,
                    maxParallelAgents: Int = 3) {
            self.id = id
            self.name = name
            self.path = path
            self.createdAt = createdAt
            self.sortOrder = sortOrder
            self.executionModeRaw = executionMode.rawValue
            self.worktreeRoot = worktreeRoot
            self.devServerCommand = devServerCommand
            self.devServerPort = devServerPort
            self.readyPattern = readyPattern
            self.testCommand = testCommand
            self.agentTestingEnabled = agentTestingEnabled
            self.autoFixOnTestFailure = autoFixOnTestFailure
            self.runBudgetUSD = runBudgetUSD
            self.draftBudgetUSD = draftBudgetUSD
            self.testBudgetUSD = testBudgetUSD
            self.mergeStrategyRaw = mergeStrategy.rawValue
            self.vercelProjectID = vercelProjectID
            self.vercelTeamID = vercelTeamID
            self.githubRemote = githubRemote
            self.defaultBranch = defaultBranch
            self.claudePermissionModeRaw = claudePermissionMode.rawValue
            self.maxParallelAgents = maxParallelAgents
            self.cards = []
            self.tags = []
            self.deployments = []
        }
    }

    // MARK: - Card

    @Model
    public final class Card {
        @Attribute(.unique) public var id: UUID
        public var title: String
        /// Markdown body of the ticket.
        public var details: String

        /// Storage for ``column``. Only ``BoardEngine`` mutates it.
        public var columnRaw: String
        public var column: Column {
            get { Column(rawValue: columnRaw) ?? .backlog }
            set { columnRaw = newValue.rawValue }
        }
        /// Storage for ``subState`` (resolution #6).
        public var subStateRaw: String
        public var subState: CardSubState {
            get { CardSubState(rawValue: subStateRaw) ?? .idle }
            set { subStateRaw = newValue.rawValue }
        }
        /// Fractional ordering within the column (midpoint insertion;
        /// renormalize when the gap shrinks below ``ColumnOrdering/minimumGap``).
        public var columnOrder: Double

        public var createdAt: Date
        /// Last column transition — drives "in review for 2d" badges.
        public var movedAt: Date
        /// Set when the card is archived off the board (resolution #6).
        public var archivedAt: Date?
        public var startedAt: Date?
        public var planApprovedAt: Date?
        public var testedAt: Date?
        public var reviewedAt: Date?
        public var doneAt: Date?

        public var project: Project?
        @Relationship(inverse: \Tag.cards)
        public var tags: [Tag]

        // Execution
        /// Set when work starts (always in worktree mode).
        public var branchName: String?
        /// nil in single-directory mode.
        public var worktreePath: String?
        /// Merge-base (worktree) or snapshot ref (single-dir) — resolution #6.
        public var baseRef: String?
        /// FIFO position while waiting for a run slot; nil when not queued.
        public var queuePosition: Int?
        public var prNumber: Int?
        public var prURL: String?
        /// Per-card model override for spawns (resolution #6).
        public var model: String?
        /// Per-card effort override for spawns (resolution #6).
        public var effort: String?
        /// Completed fail→fix cycles; the engine caps these at 2 and then
        /// forces Review with a `tests-failed` badge (spec 04 §2.2).
        public var fixCycleCount: Int

        @Relationship(deleteRule: .cascade, inverse: \SessionRef.card)
        public var sessions: [SessionRef]
        @Relationship(deleteRule: .cascade, inverse: \ActivityEvent.card)
        public var events: [ActivityEvent]
        @Relationship(deleteRule: .cascade, inverse: \TestRun.card)
        public var testRuns: [TestRun]
        /// Deleting a card keeps the project-level deployment pin.
        @Relationship(deleteRule: .nullify, inverse: \DeploymentRef.card)
        public var deployments: [DeploymentRef]

        // Denormalized snapshot for cheap board rendering — recomputed on
        // supervisor milestones, never by watching worktrees (resolution #15).
        public var lastAssistantSummary: String?
        public var lastActivityAt: Date?
        public var cachedFilesChanged: Int?
        public var cachedInsertions: Int?
        public var cachedDeletions: Int?
        /// Accumulated over all sessions, test runs included.
        public var totalCostUSD: Double
        public var totalTokens: Int

        public init(id: UUID = UUID(),
                    title: String,
                    details: String = "",
                    column: Column = .backlog,
                    subState: CardSubState = .idle,
                    columnOrder: Double = ColumnOrdering.initialSpacing,
                    createdAt: Date = .now,
                    project: Project? = nil) {
            self.id = id
            self.title = title
            self.details = details
            self.columnRaw = column.rawValue
            self.subStateRaw = subState.rawValue
            self.columnOrder = columnOrder
            self.createdAt = createdAt
            self.movedAt = createdAt
            self.project = project
            self.tags = []
            self.fixCycleCount = 0
            self.sessions = []
            self.events = []
            self.testRuns = []
            self.deployments = []
            self.totalCostUSD = 0
            self.totalTokens = 0
        }
    }

    // MARK: - Tag

    @Model
    public final class Tag {
        @Attribute(.unique) public var id: UUID
        /// Unique per project, case-insensitive — enforced in the store layer.
        public var name: String
        /// Token name from the OvertureDesign palette ("tag.red"…), never hex.
        public var colorToken: String
        public var isBuiltIn: Bool
        /// Tags are per-project (resolution #17).
        public var project: Project?
        public var cards: [Card]

        public init(id: UUID = UUID(),
                    name: String,
                    colorToken: String,
                    isBuiltIn: Bool = false,
                    project: Project? = nil) {
            self.id = id
            self.name = name
            self.colorToken = colorToken
            self.isBuiltIn = isBuiltIn
            self.project = project
            self.cards = []
        }

        /// The default per-project set (resolution #17). Callers attach the
        /// returned tags to a project on creation; all are user-deletable.
        public static func defaultTags() -> [Tag] {
            [Tag(name: "bug", colorToken: "tag.red", isBuiltIn: true),
             Tag(name: "feature", colorToken: "tag.blue", isBuiltIn: true),
             Tag(name: "chore", colorToken: "tag.gray", isBuiltIn: true),
             Tag(name: "refactor", colorToken: "tag.purple", isBuiltIn: true),
             Tag(name: "docs", colorToken: "tag.cyan", isBuiltIn: true),
             Tag(name: "urgent", colorToken: "tag.orange", isBuiltIn: true),
             Tag(name: "design", colorToken: "tag.pink", isBuiltIn: true),
             Tag(name: "test", colorToken: "tag.teal", isBuiltIn: true),
             Tag(name: "perf", colorToken: "tag.amber", isBuiltIn: true),
             Tag(name: "idea", colorToken: "tag.green", isBuiltIn: true)]
        }
    }

    // MARK: - SessionRef

    /// The link to Claude Code's own storage — Overture never copies
    /// transcripts, only records where they live.
    @Model
    public final class SessionRef {
        /// Minted by Overture (`--session-id`), so identity is known before
        /// the first byte of output.
        @Attribute(.unique) public var sessionID: UUID
        public var card: Card?

        /// Storage for ``segments`` (JSON blob).
        public var segmentsData: Data
        /// Ordered (cwd, transcriptPath, from, to) spans — resume can move
        /// where new transcript lines land (resolution #5), so this is a
        /// list, not one flat pair. Paths are globbed at creation, not
        /// re-derived (the cwd munging is non-injective).
        public var segments: [SessionPathSegment] {
            get { BlobCoding.decode([SessionPathSegment].self, from: segmentsData) ?? [] }
            set { segmentsData = BlobCoding.encode(newValue) }
        }
        /// The cwd new lines are landing in (last segment).
        public var currentCWD: String? { segments.last?.cwd }
        /// The transcript file new lines are landing in (last segment).
        public var currentTranscriptPath: String? { segments.last?.transcriptPath }

        public var startedAt: Date
        public var endedAt: Date?

        /// Storage for ``kind``.
        public var kindRaw: String
        public var kind: SessionKind {
            get { SessionKind(rawValue: kindRaw) ?? .work }
            set { kindRaw = newValue.rawValue }
        }
        /// Storage for ``role``.
        public var roleRaw: String
        public var role: SessionRole {
            get { SessionRole(rawValue: roleRaw) ?? .primary }
            set { roleRaw = newValue.rawValue }
        }
        /// Storage for ``exitReason``; nil while the session lives.
        public var exitReasonRaw: String?
        public var exitReason: ExitReason? {
            get { exitReasonRaw.flatMap(ExitReason.init(rawValue:)) }
            set { exitReasonRaw = newValue?.rawValue }
        }

        /// For orphan recovery (resolution #25).
        public var lastKnownPID: Int32?
        public var model: String?
        public var inputTokens: Int
        public var outputTokens: Int
        /// From result events, when the auth type surfaces dollars.
        public var costUSD: Double?
        /// The session `--resume` continues; at most one per card.
        public var isCurrent: Bool

        public init(sessionID: UUID = UUID(),
                    card: Card? = nil,
                    segments: [SessionPathSegment] = [],
                    startedAt: Date = .now,
                    endedAt: Date? = nil,
                    kind: SessionKind,
                    role: SessionRole,
                    exitReason: ExitReason? = nil,
                    lastKnownPID: Int32? = nil,
                    model: String? = nil,
                    inputTokens: Int = 0,
                    outputTokens: Int = 0,
                    costUSD: Double? = nil,
                    isCurrent: Bool = false) {
            self.sessionID = sessionID
            self.card = card
            self.segmentsData = BlobCoding.encode(segments)
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.kindRaw = kind.rawValue
            self.roleRaw = role.rawValue
            self.exitReasonRaw = exitReason?.rawValue
            self.lastKnownPID = lastKnownPID
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.costUSD = costUSD
            self.isCurrent = isCurrent
        }
    }

    // MARK: - ActivityEvent

    /// Append-only curated feed per card. `payload` is a small JSON blob
    /// (e.g. `{"from":"plan","to":"inProgress"}`) — never transcript content.
    @Model
    public final class ActivityEvent {
        public var id: UUID
        public var card: Card?
        public var at: Date
        /// Storage for ``kind``.
        public var kindRaw: String
        public var kind: EventKind {
            get { EventKind(rawValue: kindRaw) ?? .userNote }
            set { kindRaw = newValue.rawValue }
        }
        /// One line, human-readable.
        public var summary: String
        public var payload: Data?

        public init(id: UUID = UUID(),
                    card: Card? = nil,
                    at: Date = .now,
                    kind: EventKind,
                    summary: String,
                    payload: Data? = nil) {
            self.id = id
            self.card = card
            self.at = at
            self.kindRaw = kind.rawValue
            self.summary = summary
            self.payload = payload
        }
    }

    // MARK: - TestRun

    @Model
    public final class TestRun {
        public var id: UUID
        public var card: Card?
        public var startedAt: Date
        public var finishedAt: Date?
        /// Storage for ``kind``.
        public var kindRaw: String
        public var kind: TestKind {
            get { TestKind(rawValue: kindRaw) ?? .commandRun }
            set { kindRaw = newValue.rawValue }
        }
        public var command: String?
        /// Storage for ``status``.
        public var statusRaw: String
        public var status: TestStatus {
            get { TestStatus(rawValue: statusRaw) ?? .running }
            set { statusRaw = newValue.rawValue }
        }
        /// Storage for ``verdict``; nil until a verdict lands. Includes
        /// `manual-pass` for the Testing→Review drag (resolution #6).
        public var verdictRaw: String?
        public var verdict: TestVerdict? {
            get { verdictRaw.flatMap(TestVerdict.init(rawValue:)) }
            set { verdictRaw = newValue?.rawValue }
        }
        /// Pass/fail counts or the agent's verdict, one line.
        public var summary: String
        /// Storage for ``failures`` (JSON blob).
        public var failuresData: Data?
        public var failures: [TestFailure] {
            get { failuresData.flatMap { BlobCoding.decode([TestFailure].self, from: $0) } ?? [] }
            set { failuresData = newValue.isEmpty ? nil : BlobCoding.encode(newValue) }
        }
        /// Full captured output lives in Application Support — referenced,
        /// never embedded.
        public var outputPath: String?
        /// When agent-driven, the SessionRef that ran it.
        public var agentSessionID: UUID?

        public init(id: UUID = UUID(),
                    card: Card? = nil,
                    startedAt: Date = .now,
                    finishedAt: Date? = nil,
                    kind: TestKind,
                    command: String? = nil,
                    status: TestStatus = .running,
                    verdict: TestVerdict? = nil,
                    summary: String = "",
                    failures: [TestFailure] = [],
                    outputPath: String? = nil,
                    agentSessionID: UUID? = nil) {
            self.id = id
            self.card = card
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.kindRaw = kind.rawValue
            self.command = command
            self.statusRaw = status.rawValue
            self.verdictRaw = verdict?.rawValue
            self.summary = summary
            self.failuresData = failures.isEmpty ? nil : BlobCoding.encode(failures)
            self.outputPath = outputPath
            self.agentSessionID = agentSessionID
        }
    }

    // MARK: - DeploymentRef

    /// A *pin*, not a mirror — live status always comes from VercelKit.
    @Model
    public final class DeploymentRef {
        public var id: UUID
        public var project: Project?
        /// The card whose branch triggered the deployment, if attributable.
        public var card: Card?
        public var vercelDeploymentID: String
        public var previewURL: String
        public var gitBranch: String?
        public var recordedAt: Date

        public init(id: UUID = UUID(),
                    project: Project? = nil,
                    card: Card? = nil,
                    vercelDeploymentID: String,
                    previewURL: String,
                    gitBranch: String? = nil,
                    recordedAt: Date = .now) {
            self.id = id
            self.project = project
            self.card = card
            self.vercelDeploymentID = vercelDeploymentID
            self.previewURL = previewURL
            self.gitBranch = gitBranch
            self.recordedAt = recordedAt
        }
    }
}

// MARK: - Latest-version aliases

// Call sites never churn on a schema bump (spec 02 §3.4): models are aliased
// to the latest version at the package boundary.
public typealias Project = OvertureSchemaV1.Project
public typealias Card = OvertureSchemaV1.Card
public typealias Tag = OvertureSchemaV1.Tag
public typealias SessionRef = OvertureSchemaV1.SessionRef
public typealias ActivityEvent = OvertureSchemaV1.ActivityEvent
public typealias TestRun = OvertureSchemaV1.TestRun
public typealias DeploymentRef = OvertureSchemaV1.DeploymentRef

// MARK: - Blob coding

/// JSON round-trip for Codable blob attributes. Decode is tolerant: a corrupt
/// or future-shaped blob degrades to nil, never a trap.
enum BlobCoding {
    static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
