import Foundation
import ProcessCore

/// App-wide registry of live `CardSupervisor`s: enforces per-project
/// concurrency, owns the orphan journal, and is the only API the UI layer
/// talks to for session lifecycle.
public actor ProcessManager {
    public struct Limits: Sendable {
        /// Hard cap on live CLI processes app-wide (each is a full runtime).
        public var maxLiveProcesses: Int
        public init(maxLiveProcesses: Int = 4) {
            self.maxLiveProcesses = maxLiveProcesses
        }
    }

    /// One row of `running-agents.json` — enough to reconcile after a crash
    /// (resolution #25: journal + executable hint + spawn time is primary).
    public struct JournalEntry: Codable, Sendable, Equatable {
        public var cardID: UUID
        public var sessionID: UUID
        public var pid: Int32
        public var spawnedAt: Date
        public var executablePath: String
    }

    public enum ManagerError: Error, Sendable {
        case capacityExhausted
        case cardAlreadyRunning(UUID)
        case unknownCard(UUID)
    }

    private let limits: Limits
    private let journalURL: URL
    private var supervisors: [UUID: CardSupervisor] = [:]
    private var journal: [JournalEntry] = []

    public init(limits: Limits = .init(), journalURL: URL) {
        self.limits = limits
        self.journalURL = journalURL
        journal = Self.readJournal(at: journalURL)
    }

    // MARK: - Lifecycle

    /// Spawns a supervisor for a card. Callers (OvertureKit's queue policy)
    /// decide WHETHER to start; this enforces only the global cap.
    /// `key` defaults to the card id; auxiliary sessions (test runs) pass a
    /// distinct key so they can coexist with the card's primary supervisor.
    /// The journal always records the real card for orphan reconciliation.
    public func start(cardID: UUID,
                      key explicitKey: UUID? = nil,
                      context: CardSupervisor.SpawnContext)
        async throws -> AsyncStream<SupervisorEvent> {
        let key = explicitKey ?? cardID
        guard supervisors[key] == nil else {
            throw ManagerError.cardAlreadyRunning(cardID)
        }
        guard supervisors.count < limits.maxLiveProcesses else {
            throw ManagerError.capacityExhausted
        }
        var context = context
        context.envMarkers["OVERTURE"] = "1"
        context.envMarkers["OVERTURE_CARD_ID"] = cardID.uuidString

        let supervisor = CardSupervisor(context: context)
        supervisors[key] = supervisor
        do {
            let stream = try await supervisor.start()
            if let pid = await supervisor.pid {
                appendJournal(.init(cardID: cardID,
                                    sessionID: context.spec.sessionID,
                                    pid: pid,
                                    spawnedAt: Date(),
                                    executablePath: context.claudeExecutable.path),
                              key: key)
            }
            // Reap registry + journal when the stream ends.
            return observeEnd(of: stream, key: key)
        } catch {
            supervisors[key] = nil
            throw error
        }
    }

    public func supervisor(for cardID: UUID) -> CardSupervisor? {
        supervisors[cardID]
    }

    public var liveCardIDs: [UUID] { Array(supervisors.keys) }

    /// Graceful detach (session resumable later).
    public func detach(cardID: UUID) async throws {
        guard let supervisor = supervisors[cardID] else {
            throw ManagerError.unknownCard(cardID)
        }
        _ = await supervisor.detach()
    }

    /// Interrupt-&-Quit (resolution #7): interrupt every live session, wait
    /// briefly, then terminate. Returns cards that needed force-kill.
    public func interruptAndQuit(grace: Duration = .seconds(10)) async -> [UUID] {
        var forced: [UUID] = []
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for (cardID, supervisor) in supervisors {
                group.addTask {
                    try? await supervisor.interrupt(cancelQueued: true)
                    let exit = await supervisor.detach()
                    if case .signalled = exit { return (cardID, true) }
                    return (cardID, false)
                }
            }
            for await (cardID, wasForced) in group where wasForced {
                forced.append(cardID)
            }
        }
        supervisors.removeAll()
        journal.removeAll()
        persistJournal()
        return forced
    }

    // MARK: - Orphan reconciliation (app launch)

    public struct Reconciliation: Sendable {
        /// Journal rows whose PID is still a live claude process — stdio is
        /// gone, so the only actions are watch-transcript or terminate.
        public var alive: [JournalEntry]
        /// Rows whose process died while Overture was closed — cards should
        /// surface "session ended — resume?".
        public var dead: [JournalEntry]
    }

    public func reconcile() -> Reconciliation {
        var alive: [JournalEntry] = []
        var dead: [JournalEntry] = []
        for entry in journal {
            if HostEnvironment.isProcessAlive(
                pid: entry.pid,
                executableHint: URL(fileURLWithPath: entry.executablePath)
                    .lastPathComponent) {
                alive.append(entry)
            } else {
                dead.append(entry)
            }
        }
        journal = alive
        persistJournal()
        return .init(alive: alive, dead: dead)
    }

    // MARK: - Journal plumbing

    private func observeEnd(of stream: AsyncStream<SupervisorEvent>,
                            key: UUID) -> AsyncStream<SupervisorEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await event in stream {
                    continuation.yield(event)
                    if case .processEnded = event {
                        await self.reap(key: key)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Journal rows are keyed by registry key; `cardID` stays the real card.
    private var journalKeys: [UUID: UUID] = [:]

    private func reap(key: UUID) {
        supervisors[key] = nil
        if let sessionID = journalKeys.removeValue(forKey: key) {
            journal.removeAll { $0.sessionID == sessionID }
        }
        persistJournal()
    }

    private func appendJournal(_ entry: JournalEntry, key: UUID) {
        journal.removeAll { $0.sessionID == entry.sessionID }
        journal.append(entry)
        journalKeys[key] = entry.sessionID
        persistJournal()
    }

    private func persistJournal() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? encoder.encode(journal).write(to: journalURL, options: .atomic)
    }

    private static func readJournal(at url: URL) -> [JournalEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([JournalEntry].self, from: data)) ?? []
    }
}
