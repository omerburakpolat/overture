import Foundation
import SwiftData

/// Fractional ordering within a column: midpoint insertion, renormalized when
/// gaps collapse (spec 02 §3.1).
public enum ColumnOrdering {
    public static let initialSpacing: Double = 1024
    public static let minimumGap: Double = 1e-9

    /// Order value for inserting between two neighbors (nil = edge).
    public static func between(_ above: Double?, _ below: Double?) -> Double {
        switch (above, below) {
        case (nil, nil): initialSpacing
        case (let a?, nil): a + initialSpacing
        case (nil, let b?): b / 2
        case (let a?, let b?): (a + b) / 2
        }
    }

    /// True when `orders` (sorted) has any gap too small to midpoint again.
    public static func needsRenormalization(_ orders: [Double]) -> Bool {
        zip(orders, orders.dropFirst()).contains { $1 - $0 < minimumGap }
    }

    /// Evenly respaced values preserving order.
    public static func renormalized(count: Int) -> [Double] {
        (1...max(count, 1)).map { Double($0) * initialSpacing }
    }
}

/// Migration machinery from day one (spec 02 §3.4): V1 has no stages; later
/// versions append lightweight/custom stages here.
public enum OvertureMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [OvertureSchemaV1.self]
    }

    public static var stages: [MigrationStage] { [] }
}

public enum OvertureStore {
    /// `~/Library/Application Support/Overture/Overture.store`
    /// (resolution #2 — the single global store).
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
            .appendingPathComponent("Overture.store")
    }

    public static func container(at url: URL? = nil,
                                 inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OvertureSchemaV1.self)
        let configuration = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: url ?? defaultURL())
        return try ModelContainer(for: schema,
                                  migrationPlan: OvertureMigrationPlan.self,
                                  configurations: [configuration])
    }
}

/// The single background writer (spec 02 §3.4): supervisor events land here;
/// SwiftData contexts never cross actors.
@ModelActor
public actor PersistenceWriter {
    public enum WriterError: Error { case cardNotFound(UUID) }

    private func card(_ id: UUID) throws -> Card {
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let card = try? modelContext.fetch(descriptor).first else {
            throw WriterError.cardNotFound(id)
        }
        return card
    }

    /// Appends a curated activity row and updates the denormalized tile
    /// fields in one save.
    public func recordActivity(cardID: UUID, kind: EventKind,
                               summary: String, payload: Data? = nil) throws {
        let card = try card(cardID)
        modelContext.insert(ActivityEvent(card: card, kind: kind,
                                          summary: summary, payload: payload))
        card.lastActivityAt = .now
        try modelContext.save()
    }

    public func updateAgentSnapshot(cardID: UUID, summary: String?,
                                    costDeltaUSD: Double?,
                                    tokenDelta: Int?) throws {
        let card = try card(cardID)
        if let summary { card.lastAssistantSummary = summary }
        if let costDeltaUSD { card.totalCostUSD += costDeltaUSD }
        if let tokenDelta { card.totalTokens += tokenDelta }
        card.lastActivityAt = .now
        try modelContext.save()
    }

    public func updateDiffSnapshot(cardID: UUID, filesChanged: Int,
                                   insertions: Int, deletions: Int) throws {
        let card = try card(cardID)
        card.cachedFilesChanged = filesChanged
        card.cachedInsertions = insertions
        card.cachedDeletions = deletions
        try modelContext.save()
    }

    public func recordTestRun(cardID: UUID, run: SendableTestRun) throws {
        let card = try card(cardID)
        let testRun = TestRun(card: card, startedAt: run.startedAt,
                              finishedAt: run.finishedAt, kind: run.kind,
                              command: run.command, status: run.status,
                              verdict: run.verdict, summary: run.summary,
                              failures: run.failures,
                              outputPath: run.outputPath,
                              agentSessionID: run.agentSessionID)
        modelContext.insert(testRun)
        try modelContext.save()
    }
}

/// Sendable carrier for a finished/starting test run crossing into the writer.
public struct SendableTestRun: Sendable {
    public var startedAt: Date
    public var finishedAt: Date?
    public var kind: TestKind
    public var command: String?
    public var status: TestStatus
    public var verdict: TestVerdict?
    public var summary: String
    public var failures: [TestFailure]
    public var outputPath: String?
    public var agentSessionID: UUID?

    public init(startedAt: Date = .now, finishedAt: Date? = nil,
                kind: TestKind, command: String? = nil,
                status: TestStatus = .running, verdict: TestVerdict? = nil,
                summary: String = "", failures: [TestFailure] = [],
                outputPath: String? = nil, agentSessionID: UUID? = nil) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.kind = kind
        self.command = command
        self.status = status
        self.verdict = verdict
        self.summary = summary
        self.failures = failures
        self.outputPath = outputPath
        self.agentSessionID = agentSessionID
    }
}
