import Foundation
import SwiftData
import ClaudeKit
import ProcessCore

// A card is a ticket with a thread underneath it (spec 04 §3.3, §4.3): the
// primary Claude conversation, the card's curated activity, and its test
// verdicts, in one chronological stream. The transcript on disk stays the
// only copy of the conversation (spec 02 §2, §4.5) — nothing here persists
// message content; it merges what is on disk with what is still streaming.

// MARK: - Activity log

/// Every curated activity row goes through here. SwiftData updates the
/// inverse of `event.card` silently — nothing observing `card.events` (the
/// sheet, the tile) hears about it — so the append goes through the
/// observed array as well.
enum ActivityLog {
    /// Nonisolated like `BoardEngine.apply` — callers own the context.
    @discardableResult
    static func record(_ kind: EventKind, _ summary: String,
                       payload: Data? = nil, on card: Card,
                       in context: ModelContext) -> ActivityEvent {
        let event = ActivityEvent(card: card, kind: kind, summary: summary,
                                  payload: payload)
        context.insert(event)
        card.events.append(event)
        card.lastActivityAt = event.at
        return event
    }
}

// MARK: - Thread entries

/// A finished test run, flattened for rendering off the model graph.
public struct TestRunSummary: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: TestStatus
    public var verdict: TestVerdict?
    public var summary: String
    public var failures: [TestFailure]

    public init(id: UUID = UUID(), startedAt: Date, finishedAt: Date? = nil,
                status: TestStatus, verdict: TestVerdict? = nil,
                summary: String = "", failures: [TestFailure] = []) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.verdict = verdict
        self.summary = summary
        self.failures = failures
    }

    @MainActor
    public init(_ run: TestRun) {
        self.init(id: run.id, startedAt: run.startedAt,
                  finishedAt: run.finishedAt, status: run.status,
                  verdict: run.verdict, summary: run.summary,
                  failures: run.failures)
    }
}

/// One curated activity row, flattened for rendering.
public struct ActivityRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var at: Date
    public var kind: EventKind
    public var summary: String

    public init(id: UUID = UUID(), at: Date, kind: EventKind, summary: String) {
        self.id = id
        self.at = at
        self.kind = kind
        self.summary = summary
    }

    @MainActor
    public init(_ event: ActivityEvent) {
        self.init(id: event.id, at: event.at, kind: event.kind,
                  summary: event.summary)
    }
}

/// One row of a card's thread.
public struct ThreadEntry: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case user(String)
        case assistant(String)
        case tool(name: String, detail: String)
        case system(EventKind, String)
        case testRun(TestRunSummary)
        case notice(String)
    }

    public var id: String
    public var at: Date?
    public var kind: Kind
    /// Streamed but not yet confirmed by the transcript on disk.
    public var isPending: Bool

    public init(id: String, at: Date?, kind: Kind, isPending: Bool = false) {
        self.id = id
        self.at = at
        self.kind = kind
        self.isPending = isPending
    }
}

public enum CardThread {
    /// The transcript on disk, rendered once: rows plus the ids the live
    /// stream is de-duplicated against. Building this decodes every tool
    /// input, so it happens at load time, never per render.
    public struct HistoryDigest: Sendable, Equatable {
        public var rows: [ThreadEntry] = []
        public var ids: Set<String> = []
        public var toolIDs: Set<String> = []

        public init() {}

        public init(_ history: [TranscriptItem]) {
            for item in history {
                ids.insert(item.id)
                if let toolID = item.toolUseID { toolIDs.insert(toolID) }
                guard let kind = CardThread.kind(for: item) else { continue }
                rows.append(ThreadEntry(id: item.id, at: item.timestamp,
                                        kind: kind))
            }
        }
    }

    /// Merges the sources of a card's thread into one ordered stream.
    ///
    /// Live rows are de-duplicated against the transcript by the ids the CLI
    /// gives both (message `uuid`, `tool_use` id — verified identical in the
    /// M0 fixtures), so a row shows exactly once whether it arrived a second
    /// ago on the stream or an hour ago on disk. Rows still pending on the
    /// stream sort last.
    public static func entries(history: [TranscriptItem],
                               events: [ActivityRow] = [],
                               testRuns: [TestRunSummary] = [],
                               live: [LiveChatItem] = []) -> [ThreadEntry] {
        entries(digest: HistoryDigest(history), events: events,
                testRuns: testRuns, live: live)
    }

    public static func entries(digest: HistoryDigest,
                               events: [ActivityRow] = [],
                               testRuns: [TestRunSummary] = [],
                               live: [LiveChatItem] = []) -> [ThreadEntry] {
        var rows = digest.rows
        let seenIDs = digest.ids
        let seenToolIDs = digest.toolIDs

        for event in events {
            // A test verdict is its own inline card (spec 04 §4.3); the
            // activity row stays in the Activity tab only.
            if event.kind == .testRunFinished { continue }
            rows.append(ThreadEntry(id: "event-\(event.id.uuidString)",
                                    at: event.at,
                                    kind: .system(event.kind, event.summary)))
        }
        for run in testRuns {
            rows.append(ThreadEntry(id: "test-\(run.id.uuidString)",
                                    at: run.finishedAt ?? run.startedAt,
                                    kind: .testRun(run)))
        }
        // Provisional user rows: the CLI's replay echo (which carries the
        // uuid) is deferred until the turn's first API response, but the
        // transcript line is on disk milliseconds after `system/init` —
        // exactly when history reloads. Until the echo lands (or never, if
        // the process died mid-turn), match by text and time, consuming
        // each transcript row once so a repeated "yes" stays one-to-one.
        var unclaimedUserRows: [(text: String, at: Date)] = digest.rows.compactMap {
            guard case .user(let text) = $0.kind, let at = $0.at else { return nil }
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), at)
        }
        for item in live {
            if seenIDs.contains(item.id) { continue }
            if case .toolUse = item.kind, seenToolIDs.contains(item.id) {
                continue
            }
            if item.kind == .user, item.isProvisional {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = unclaimedUserRows.firstIndex(where: {
                    $0.text == text
                        && $0.at >= item.at.addingTimeInterval(-echoSlack)
                        && $0.at <= item.at.addingTimeInterval(echoWindow)
                }) {
                    unclaimedUserRows.remove(at: match)
                    continue
                }
            }
            rows.append(ThreadEntry(id: "live-\(item.id)", at: item.at,
                                    kind: kind(for: item), isPending: true))
        }

        // Stable by timestamp; untimed rows keep arrival order at the end.
        return rows.enumerated().sorted { lhs, rhs in
            let l = lhs.element.at ?? .distantFuture
            let r = rhs.element.at ?? .distantFuture
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    /// Clock slack between Overture appending a row and the CLI stamping
    /// its transcript line, and how long a row may wait for its twin.
    static let echoSlack: TimeInterval = 2
    static let echoWindow: TimeInterval = 10 * 60

    static func kind(for item: TranscriptItem) -> ThreadEntry.Kind? {
        switch item.role {
        case .user:
            return userKind(item.text)
        case .assistant:
            return item.text.isEmpty ? nil : .assistant(item.text)
        case .toolUse(let name):
            return .tool(name: name, detail: ToolDetail.summary(inputJSON: item.text))
        case .toolResult:
            return nil   // collapsed; the tool row stands for the call
        }
    }

    private static func kind(for item: LiveChatItem) -> ThreadEntry.Kind {
        switch item.kind {
        case .user: userKind(item.text)
        case .assistantText: .assistant(item.text)
        case .toolUse(let name): .tool(name: name, detail: item.text)
        case .notice: .notice(item.text)
        }
    }

    /// The CLI records its own interjections as user turns
    /// (`[Request interrupted by user]`) — those read as notices, not as
    /// something the user typed.
    static func userKind(_ text: String) -> ThreadEntry.Kind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[Request interrupted") {
            return .notice("Interrupted")
        }
        return .user(text)
    }
}

/// One-line summaries of tool inputs, shared by live rows and history rows.
public enum ToolDetail {
    public static func summary(input: JSONValue) -> String {
        if let command = input["command"]?.stringValue { return command }
        if let path = input["file_path"]?.stringValue { return path }
        if let pattern = input["pattern"]?.stringValue { return pattern }
        if let query = input["query"]?.stringValue { return query }
        if let description = input["description"]?.stringValue {
            return description
        }
        return ""
    }

    /// For transcript rows, where the input arrives re-encoded as JSON text.
    public static func summary(inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return "" }
        return summary(input: value)
    }
}

// MARK: - History loading

/// Enough of a `SessionRef` to find its transcript off the main actor.
public struct SessionLocator: Sendable, Equatable {
    public var sessionID: UUID
    public var transcriptPath: String
    public var startedAt: Date

    public init(sessionID: UUID, transcriptPath: String, startedAt: Date) {
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.startedAt = startedAt
    }

    @MainActor
    public init(_ session: SessionRef) {
        self.init(sessionID: session.sessionID,
                  transcriptPath: session.currentTranscriptPath ?? "",
                  startedAt: session.startedAt)
    }
}

public enum CardThreadLoader {
    /// Reads the card's primary-thread transcripts (oldest session first),
    /// tail-limited, off the main actor. A missing or unreadable file yields
    /// no rows — never an error (spec 01 §7.1: degrade, don't fail).
    /// `history(for:)` rendered off the main actor, ready for the thread.
    public static func digest(for sessions: [SessionLocator],
                              configRoot: URL = TranscriptStore.configRoot(),
                              maxBytesPerSession: Int = 4 * 1024 * 1024)
        async -> CardThread.HistoryDigest {
        let items = await history(for: sessions, configRoot: configRoot,
                                  maxBytesPerSession: maxBytesPerSession)
        return await Task.detached(priority: .userInitiated) {
            CardThread.HistoryDigest(items)
        }.value
    }

    public static func history(for sessions: [SessionLocator],
                               configRoot: URL = TranscriptStore.configRoot(),
                               maxBytesPerSession: Int = 4 * 1024 * 1024)
        async -> [TranscriptItem] {
        let ordered = sessions.sorted { $0.startedAt < $1.startedAt }
        return await Task.detached(priority: .userInitiated) {
            var items: [TranscriptItem] = []
            for session in ordered {
                guard let url = transcriptURL(for: session, configRoot: configRoot),
                      let content = TranscriptStore.readTail(
                          of: url, maxBytes: maxBytesPerSession)
                else { continue }
                items += TranscriptReader.items(fromJSONL: content)
            }
            return items
        }.value
    }

    static func transcriptURL(for session: SessionLocator,
                              configRoot: URL) -> URL? {
        if !session.transcriptPath.isEmpty,
           FileManager.default.fileExists(atPath: session.transcriptPath) {
            return URL(fileURLWithPath: session.transcriptPath)
        }
        // Resume can move where lines land and the encoding is
        // non-injective (resolution #5) — glob, never derive.
        return TranscriptStore.locate(sessionID: session.sessionID,
                                      configRoot: configRoot).first
    }
}
