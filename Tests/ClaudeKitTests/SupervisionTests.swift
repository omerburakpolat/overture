import Foundation
import Testing
@testable import ClaudeKit
import ProcessCore

@Suite struct TranscriptReaderTests {
    private func sample() throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures/transcript-sample", withExtension: "jsonl"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func realTranscriptParses() throws {
        let items = TranscriptReader.items(fromJSONL: try sample())
        #expect(!items.isEmpty)
        // Scenario A: three user turns are on the active branch.
        let userTexts = items.filter { $0.role == .user }.map(\.text)
        #expect(userTexts.contains { $0.contains("touch m0-touch.txt") })
        // Tool uses render as tool rows, not user/assistant text.
        #expect(items.contains {
            if case .toolUse(let name) = $0.role { return name == "Bash" }
            return false
        })
        // Chronology is preserved.
        let stamps = items.compactMap(\.timestamp)
        #expect(stamps == stamps.sorted())
    }

    @Test func garbageLinesNeverThrow() {
        let content = """
        not json at all
        {"type":"mystery","uuid":"x"}
        {"type":"user","uuid":"u1","message":{"role":"user","content":"hi"}}
        """
        let items = TranscriptReader.items(fromJSONL: content)
        #expect(items.count == 1)
        #expect(items[0].text == "hi")
    }

    @Test func summaryTailReadFindsSnippet() throws {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures/transcript-sample", withExtension: "jsonl"))
        let summary = TranscriptReader.summary(of: url)
        #expect(summary.lastMessageSnippet?.isEmpty == false)
        #expect(summary.sessionID?.isEmpty == false)
    }

    @Test func locateFindsNothingForUnknownSession() {
        let hits = TranscriptStore.locate(
            sessionID: UUID(),
            configRoot: URL(fileURLWithPath: "/nonexistent"))
        #expect(hits.isEmpty)
    }
}

@Suite struct ProcessManagerTests {
    private func tempJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-test-\(UUID().uuidString)")
            .appendingPathComponent("running-agents.json")
    }

    @Test func journalPersistsAndReconciles() async throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(
            at: url.deletingLastPathComponent()) }

        // Seed a journal with one dead PID (spawn a process that exits).
        let entry = ProcessManager.JournalEntry(
            cardID: UUID(), sessionID: UUID(),
            pid: 99999, spawnedAt: Date(), executablePath: "/opt/x/claude")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try encoder.encode([entry]).write(to: url)

        let manager = ProcessManager(journalURL: url)
        let reconciliation = await manager.reconcile()
        #expect(reconciliation.dead.map(\.cardID) == [entry.cardID])
        #expect(reconciliation.alive.isEmpty)

        // Journal file was rewritten without the dead row.
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remaining = try decoder.decode(
            [ProcessManager.JournalEntry].self, from: data)
        #expect(remaining.isEmpty)
    }

    @Test func capacityIsEnforced() async throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(
            at: url.deletingLastPathComponent()) }
        let manager = ProcessManager(
            limits: .init(maxLiveProcesses: 0), journalURL: url)
        await #expect(throws: ProcessManager.ManagerError.self) {
            _ = try await manager.start(cardID: UUID(), context: .init(
                claudeExecutable: URL(fileURLWithPath: "/usr/bin/true"),
                workingDirectory: FileManager.default.temporaryDirectory,
                spec: .init(profile: .askMe),
                runKind: .interactiveChat))
        }
    }
}

/// Live end-to-end: spawns the real `claude` CLI. Costs tokens — enabled
/// only with OVERTURE_LIVE_TESTS=1 (run explicitly, mirrors spikes/m0).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OVERTURE_LIVE_TESTS"] == "1"))
struct LiveSupervisorTests {
    @Test(.timeLimit(.minutes(5)))
    func permissionRoundTripThroughSwiftStack() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let claude = HostEnvironment.claudeCandidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let claudeURL = try #require(claude.map(URL.init(fileURLWithPath:)))

        let supervisor = CardSupervisor(context: .init(
            claudeExecutable: claudeURL,
            workingDirectory: workDir,
            spec: .init(profile: .askMe, model: "haiku",
                        settingSources: ""),
            runKind: .interactiveChat))
        let events = try await supervisor.start()
        try await supervisor.send(
            userText: "Use the Bash tool to run exactly: touch live-test.txt. "
                + "Then reply DONE and stop.")

        var sawPermission = false
        var sawResult = false
        for await event in events {
            switch event {
            case .permissionRequested(let requestID, let request):
                sawPermission = true
                #expect(request.toolName == "Bash")
                try await supervisor.answerPermission(
                    requestID: requestID,
                    verdict: .allow(updatedInput: request.input))
            case .turnCompleted(let result, let runKind):
                sawResult = true
                #expect(!result.isError)
                #expect(runKind == .interactiveChat)
                _ = await supervisor.detach()
            case .processEnded:
                #expect(sawPermission && sawResult)
                #expect(FileManager.default.fileExists(
                    atPath: workDir.appendingPathComponent("live-test.txt").path))
                return
            default:
                break
            }
        }
        Issue.record("event stream ended without processEnded")
    }
}
