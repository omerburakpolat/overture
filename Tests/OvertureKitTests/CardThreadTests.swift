import Foundation
import SwiftData
import Synchronization
import Testing
@testable import OvertureKit
import ClaudeKit
import ProcessCore

// A card's thread merges the transcript on disk, the live stream, activity
// rows and test verdicts into one ordered stream — and shows each message
// exactly once across the live→disk handoff.

private func jsonl(_ lines: [String]) -> String { lines.joined(separator: "\n") }

private func userLine(uuid: String, parent: String?, text: String,
                      at: String) -> String {
    let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
    return """
    {"parentUuid":\(parentJSON),"isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"\(text)"}]},"uuid":"\(uuid)","timestamp":"\(at)"}
    """
}

private func assistantLine(uuid: String, parent: String, text: String,
                           at: String) -> String {
    """
    {"parentUuid":"\(parent)","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]},"uuid":"\(uuid)","timestamp":"\(at)"}
    """
}

private func toolLine(uuid: String, parent: String, toolID: String,
                      at: String) -> String {
    """
    {"parentUuid":"\(parent)","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\(toolID)","name":"Bash","input":{"command":"swift test"}}]},"uuid":"\(uuid)","timestamp":"\(at)"}
    """
}

private func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

@Suite struct CardThreadMergeTests {
    private let history = TranscriptReader.items(fromJSONL: jsonl([
        userLine(uuid: "u1", parent: nil, text: "Fix the crash",
                 at: "2026-09-01T10:00:00Z"),
        assistantLine(uuid: "a1", parent: "u1", text: "On it.",
                      at: "2026-09-01T10:00:05Z"),
        toolLine(uuid: "t1", parent: "a1", toolID: "toolu_1",
                 at: "2026-09-01T10:00:07Z"),
        assistantLine(uuid: "a2", parent: "t1", text: "Done.",
                      at: "2026-09-01T10:00:20Z"),
    ]))

    @Test func historyRendersInTranscriptOrder() {
        let entries = CardThread.entries(history: history)
        #expect(entries.map(\.id) == ["u1", "a1", "t1", "a2"])
        #expect(entries.allSatisfy { !$0.isPending })
        #expect(entries[0].kind == .user("Fix the crash"))
        #expect(entries[2].kind == .tool(name: "Bash", detail: "swift test"))
    }

    @Test func liveRowsAlreadyOnDiskAreDropped() {
        // The stream delivered a2 and toolu_1 seconds ago; the transcript
        // now has both. Only the genuinely new row survives, as pending.
        let live: [LiveChatItem] = [
            .init(id: "a2", kind: .assistantText, text: "Done."),
            .init(id: "toolu_1", kind: .toolUse(name: "Bash"), text: "swift test"),
            .init(id: "a3", kind: .assistantText, text: "Anything else?"),
        ]
        let entries = CardThread.entries(history: history, live: live)
        #expect(entries.map(\.id) == ["u1", "a1", "t1", "a2", "live-a3"])
        #expect(entries.last?.isPending == true)
    }

    @Test func provisionalUserRowsSurviveUntilEchoed() {
        let live: [LiveChatItem] = [
            .init(id: LiveChatItem.provisionalPrefix + "x", kind: .user,
                  text: "Also add tests"),
        ]
        let entries = CardThread.entries(history: history, live: live)
        #expect(entries.last?.kind == .user("Also add tests"))
        #expect(entries.last?.isPending == true)
    }

    @Test func provisionalUserRowsMatchTheirTranscriptTwinByTextAndTime() {
        // The transcript already holds the message (it is written at turn
        // start) but the uuid-carrying echo has not arrived: one row, not
        // a confirmed one plus a dimmed twin.
        let sent = date("2026-09-01T10:00:00Z").addingTimeInterval(-0.5)
        let live: [LiveChatItem] = [
            .init(id: LiveChatItem.provisionalPrefix + "p", kind: .user,
                  text: "Fix the crash", at: sent),
        ]
        let entries = CardThread.entries(history: history, live: live)
        #expect(entries.map(\.id) == ["u1", "a1", "t1", "a2"])
    }

    @Test func repeatedIdenticalMessagesStayOneToOne() {
        // Two "yes" sent, one on disk so far: exactly one stays pending.
        let base = date("2026-09-01T11:00:00Z")
        let items = TranscriptReader.items(fromJSONL: jsonl([
            userLine(uuid: "y1", parent: nil, text: "yes",
                     at: "2026-09-01T11:00:00Z"),
        ]))
        let live: [LiveChatItem] = [
            .init(id: LiveChatItem.provisionalPrefix + "1", kind: .user,
                  text: "yes", at: base.addingTimeInterval(-1)),
            .init(id: LiveChatItem.provisionalPrefix + "2", kind: .user,
                  text: "yes", at: base.addingTimeInterval(30)),
        ]
        let entries = CardThread.entries(history: items, live: live)
        #expect(entries.map(\.id) == ["y1", "live-local-2"])
        // A row written long before the message was sent is not its twin.
        let stale: [LiveChatItem] = [
            .init(id: LiveChatItem.provisionalPrefix + "3", kind: .user,
                  text: "yes", at: base.addingTimeInterval(3600)),
        ]
        #expect(CardThread.entries(history: items, live: stale).count == 2)
    }

    @Test func activityAndTestRunsInterleaveByTime() {
        let events = [
            ActivityRow(at: date("2026-09-01T10:00:06Z"), kind: .columnChanged,
                        summary: "Moved Backlog → Plan"),
            ActivityRow(at: date("2026-09-01T09:59:00Z"), kind: .cardCreated,
                        summary: "Ticket created"),
        ]
        let runs = [
            TestRunSummary(startedAt: date("2026-09-01T10:00:21Z"),
                           finishedAt: date("2026-09-01T10:00:30Z"),
                           status: .passed, verdict: .pass, summary: "3 checks"),
        ]
        let entries = CardThread.entries(history: history, events: events,
                                         testRuns: runs)
        let summaries = entries.map { entry -> String in
            switch entry.kind {
            case .user(let t), .assistant(let t): t
            case .tool(let name, _): name
            case .system(_, let s): s
            case .testRun(let run): "test:\(run.summary)"
            case .notice(let n): n
            }
        }
        #expect(summaries == ["Ticket created", "Fix the crash", "On it.",
                              "Moved Backlog → Plan", "Bash", "Done.",
                              "test:3 checks"])
    }

    @Test func pendingRowsSortAfterEverythingOnDisk() {
        let live: [LiveChatItem] = [
            .init(id: "a9", kind: .assistantText, text: "Streaming now"),
        ]
        let events = [ActivityRow(at: date("2026-09-01T10:00:25Z"),
                                  kind: .agentFinished, summary: "Run finished")]
        let entries = CardThread.entries(history: history, events: events,
                                         live: live)
        #expect(entries.last?.id == "live-a9")
    }

    @Test func testVerdictRowsStayOutOfTheThread() {
        // The TestRun card is the verdict; the activity row is for the
        // Activity tab only, so a verdict never shows twice.
        let at = date("2026-09-01T10:00:30Z")
        let events = [ActivityRow(at: at, kind: .testRunFinished,
                                  summary: "Tests passed — 3 checks")]
        let runs = [TestRunSummary(startedAt: at, finishedAt: at,
                                   status: .passed, verdict: .pass,
                                   summary: "3 checks")]
        let entries = CardThread.entries(history: [], events: events,
                                         testRuns: runs)
        #expect(entries.count == 1)
        if case .testRun = entries[0].kind {} else {
            Issue.record("expected the inline test-run card")
        }
    }

    @Test func digestMatchesTheItemBasedMerge() {
        let digest = CardThread.HistoryDigest(history)
        #expect(digest.ids == ["u1", "a1", "t1", "a2"])
        #expect(digest.toolIDs == ["toolu_1"])
        #expect(CardThread.entries(digest: digest)
                == CardThread.entries(history: history))
    }

    @Test func cliInterjectionsReadAsNotices() {
        let items = TranscriptReader.items(fromJSONL: jsonl([
            userLine(uuid: "i1", parent: nil,
                     text: "[Request interrupted by user]",
                     at: "2026-09-01T10:00:00Z"),
        ]))
        let entries = CardThread.entries(history: items)
        #expect(entries.first?.kind == .notice("Interrupted"))
    }

    @Test func toolDetailPrefersCommandThenPath() {
        #expect(ToolDetail.summary(inputJSON: #"{"command":"ls -la"}"#) == "ls -la")
        #expect(ToolDetail.summary(inputJSON: #"{"file_path":"/a/b.swift"}"#)
                == "/a/b.swift")
        #expect(ToolDetail.summary(inputJSON: "not json") == "")
    }
}

@Suite struct UserEchoTests {
    private func echo(_ text: String, uuid: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data("""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"\(text)"}]},"uuid":"\(uuid)","session_id":"s"}
        """.utf8))
    }

    @Test func echoAdoptsTheTranscriptUUID() {
        var items = [SessionCoordinator.provisionalUserRow("hello")]
        SessionCoordinator.acknowledgeUserEcho(echo("hello", uuid: "real-1"),
                                               in: &items)
        #expect(items.map(\.id) == ["real-1"])
        #expect(items[0].isProvisional == false)
    }

    @Test func echoMatchesTheNewestProvisionalRowWithThatText() {
        var items = [
            SessionCoordinator.provisionalUserRow("yes"),
            LiveChatItem(id: "already", kind: .user, text: "yes"),
            SessionCoordinator.provisionalUserRow("yes"),
        ]
        SessionCoordinator.acknowledgeUserEcho(echo("yes", uuid: "real-2"),
                                               in: &items)
        #expect(items[2].id == "real-2")
        #expect(items[0].isProvisional)
    }

    @Test func toolResultEchoesAreIgnored() {
        var items = [SessionCoordinator.provisionalUserRow("run it")]
        let raw = try! JSONDecoder().decode(JSONValue.self, from: Data("""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"run it"}]},"uuid":"tr-1"}
        """.utf8))
        SessionCoordinator.acknowledgeUserEcho(raw, in: &items)
        #expect(items[0].isProvisional)
    }
}

@Suite @MainActor struct CardThreadLoaderTests {
    /// A fake `~/.claude` with one transcript, found by glob when the stored
    /// path is empty (resolution #5) and by path when it is set.
    private func makeConfigRoot(sessionID: UUID) throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-thread-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("projects/-tmp-x")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(
            "\(sessionID.uuidString.lowercased()).jsonl")
        try jsonl([
            userLine(uuid: "u1", parent: nil, text: "Hi",
                     at: "2026-09-01T10:00:00Z"),
            assistantLine(uuid: "a1", parent: "u1", text: "Hello",
                          at: "2026-09-01T10:00:01Z"),
        ]).write(to: file, atomically: true, encoding: .utf8)
        return (root, file)
    }

    @Test func locatesByGlobWhenPathUnknown() async throws {
        let sessionID = UUID()
        let (root, _) = try makeConfigRoot(sessionID: sessionID)
        defer { try? FileManager.default.removeItem(at: root) }
        let items = await CardThreadLoader.history(
            for: [.init(sessionID: sessionID, transcriptPath: "",
                        startedAt: .now)],
            configRoot: root)
        #expect(items.map(\.id) == ["u1", "a1"])
    }

    @Test func prefersTheStoredPath() throws {
        let sessionID = UUID()
        let (root, file) = try makeConfigRoot(sessionID: sessionID)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = CardThreadLoader.transcriptURL(
            for: .init(sessionID: sessionID, transcriptPath: file.path,
                       startedAt: .now),
            configRoot: URL(fileURLWithPath: "/nonexistent"))
        #expect(url?.path == file.path)
    }

    @Test func missingTranscriptYieldsNoRowsNotAnError() async {
        let items = await CardThreadLoader.history(
            for: [.init(sessionID: UUID(), transcriptPath: "/nope.jsonl",
                        startedAt: .now)],
            configRoot: URL(fileURLWithPath: "/nonexistent"))
        #expect(items.isEmpty)
    }
}

@Suite @MainActor struct TicketEditTests {
    private func makeStore() throws -> (BoardStore, Card) {
        let services = try AppServices(inMemory: true)
        let context = services.container.mainContext
        let project = Project(name: "Edit", path: "/tmp/edit-repo")
        context.insert(project)
        for tag in Tag.defaultTags() {
            tag.project = project
            context.insert(tag)
        }
        try context.save()
        let store = BoardStore(project: project, services: services,
                               coordinator: SessionCoordinator(services: services))
        let card = store.createCard(title: "Old title", details: "", tags: [])
        return (store, card)
    }

    @Test func editingRecordsOneActivityRowNamingWhatChanged() throws {
        let (store, card) = try makeStore()
        let bug = try #require(store.project.tags.first { $0.name == "bug" })
        #expect(store.updateTicket(card, title: "New title",
                                   details: "Steps to reproduce…", tags: [bug]))
        #expect(card.title == "New title")
        #expect(card.details == "Steps to reproduce…")
        #expect(card.tags.map(\.name) == ["bug"])
        let edits = card.events.filter { $0.kind == .ticketEdited }
        #expect(edits.count == 1)
        #expect(edits.first?.summary == "Edited title, description, tags")
    }

    @Test func titleOnlyEditsDoNotClaimTheDescriptionChanged() throws {
        let (store, card) = try makeStore()
        // Descriptions saved before trimming existed carry a trailing newline.
        card.details = "Steps:\n- one\n"
        #expect(store.updateTicket(card, title: "Renamed", details: card.details,
                                   tags: card.tags))
        // Relationship arrays are unordered — look for the row, not at .last.
        let edits = card.events.filter { $0.kind == .ticketEdited }
        #expect(edits.map(\.summary) == ["Edited title"])
    }

    @Test func overlongTitlesAreRejectedWithAToast() throws {
        let (store, card) = try makeStore()
        let long = String(repeating: "x", count: BoardStore.titleLimit + 1)
        #expect(!store.updateTicket(card, title: long, details: "", tags: []))
        #expect(card.title == "Old title")
        #expect(store.toast?.message.contains("120") == true)
        let created = store.createCard(title: long, details: "  body \n",
                                       tags: [])
        #expect(created.title.count == BoardStore.titleLimit)
        #expect(created.details == "body")
    }

    @Test func noOpEditsRecordNothing() throws {
        let (store, card) = try makeStore()
        #expect(!store.updateTicket(card, title: "Old title", details: "",
                                    tags: []))
        #expect(!store.updateTicket(card, title: "   ", details: "x", tags: []))
        #expect(card.events.filter { $0.kind == .ticketEdited }.isEmpty)
        #expect(card.title == "Old title")
    }

    @Test func activityRowsNotifyObserversOfTheCardsEvents() throws {
        let (store, card) = try makeStore()
        let fired = Mutex(false)
        withObservationTracking {
            _ = card.events.count
        } onChange: {
            fired.withLock { $0 = true }
        }
        store.perform(.startPlan, on: card)
        #expect(fired.withLock { $0 })
        #expect(card.column == .plan)
        #expect(card.events.contains {
            $0.kind == .columnChanged && $0.summary == "Moved Backlog → Plan"
        })
        // Each row is inserted once even though it is appended through the
        // observed array as well.
        #expect(card.events.filter { $0.kind == .columnChanged }.count == 1)
    }
}
