import Foundation
import SwiftData
import Testing
@testable import OvertureKit
import ClaudeKit

// Authentication failures driven end to end through the coordinator, against
// a stand-in `claude` that emits the shapes measured from CLI 2.1.236 in a
// clean environment. No real CLI, no network, no ~/.claude writes.

/// `__MODE__` is `expired` (an assistant message carrying
/// `error: authentication_failed`, then a result marked `success` and
/// `is_error`) or `retry` (`api_retry` authentication failures until
/// interrupted, as the real CLI does for a rejected key).
private let authFakeScript = #"""
#!/usr/bin/env python3
import sys, json, os, uuid
log = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake.log"), "a")
def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def note(s):
    log.write(s + "\n"); log.flush()
argv = sys.argv
SID = argv[argv.index("--session-id") + 1] if "--session-id" in argv else str(uuid.uuid4())
MODE = "__MODE__"
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    t = o.get("type")
    if t == "control_request":
        st = o["request"]["subtype"]; rid = o["request_id"]
        note("control " + st)
        body = {"commands": [], "models": []} if st == "initialize" else {}
        out({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": body}})
        if st == "interrupt":
            out({"type": "result", "subtype": "error_during_execution", "is_error": True, "duration_ms": 1,
                 "num_turns": 1, "result": None, "session_id": SID, "total_cost_usd": 0, "uuid": str(uuid.uuid4())})
    elif t == "user":
        note("user")
        out({"type": "system", "subtype": "init", "cwd": os.getcwd(), "session_id": SID, "tools": [],
             "model": "fake", "permissionMode": "default", "uuid": str(uuid.uuid4())})
        if MODE == "expired":
            reason = "Failed to authenticate: OAuth session expired and could not be refreshed"
            out({"type": "assistant", "error": "authentication_failed", "is_api_error_message": True,
                 "message": {"role": "assistant", "model": "<synthetic>", "content": [{"type": "text", "text": reason}]},
                 "parent_tool_use_id": None, "session_id": SID, "uuid": str(uuid.uuid4())})
            out({"type": "result", "subtype": "success", "is_error": True, "api_error_status": None, "duration_ms": 1,
                 "num_turns": 1, "result": reason, "session_id": SID, "total_cost_usd": 0, "uuid": str(uuid.uuid4())})
        else:
            for attempt in range(1, 4):
                out({"type": "system", "subtype": "api_retry", "attempt": attempt, "max_retries": 10,
                     "retry_delay_ms": 500, "error": "authentication_failed", "error_status": 401,
                     "session_id": SID, "uuid": str(uuid.uuid4())})
            note("retrying")
note("stdin closed")
"""#

@MainActor
private final class AuthHarness {
    let dir: URL
    let services: AppServices
    let coordinator: SessionCoordinator
    let store: BoardStore
    let project: Project
    var notices: [SessionCoordinator.Notice] = []

    init(mode: String) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-auth-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        try authFakeScript.replacingOccurrences(of: "__MODE__", with: mode)
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        services = try AppServices(
            inMemory: true,
            journalURL: dir.appendingPathComponent("running-agents.json"))
        services.claudeURLOverride = script
        // Never probe the real machine. This stub still *reports* signed in
        // after the failure — exactly the rejected-key case, where no
        // automatic probe may lift the stop.
        let scriptPath = script.path
        services.useEnvironmentCheck(ClaudeEnvironmentCheck(probes: .init(
            candidatePaths: { [scriptPath] }, overridePath: { nil },
            isExecutable: { _ in true }, loginShellPATH: { nil },
            childEnvironment: { [:] },
            shellDivergence: { _ in .init(names: [], probeSucceeded: true) },
            capture: { _, arguments, _ in
                arguments == ["--version"]
                    ? .init(stdout: "2.1.236 (Claude Code)", exit: .exited(code: 0))
                    : .init(stdout: #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max"}"#,
                            exit: .exited(code: 0))
            },
            now: { Date() })))
        coordinator = SessionCoordinator(services: services)
        let context = services.container.mainContext
        project = Project(name: "fake", path: dir.path,
                          executionMode: .singleDirectory)
        project.trustedAt = .now
        project.agentTestingEnabled = false
        context.insert(project)
        try context.save()
        store = BoardStore(project: project, services: services,
                           coordinator: coordinator)
        coordinator.onNotice = { [weak self] notice in self?.notices.append(notice) }
    }

    var log: [String] {
        (try? String(contentsOf: dir.appendingPathComponent("fake.log"),
                     encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    func card(_ title: String) -> Card {
        store.createCard(title: title, details: "", tags: [])
    }

    func authNotices(on card: Card) -> [LiveChatItem] {
        (coordinator.live[card.id]?.transcript ?? []).filter {
            $0.kind == .notice && $0.text.contains("could not authenticate")
        }
    }

    func waitUntil(_ timeout: Duration = .seconds(8),
                   _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    func tearDown() async {
        _ = await services.processManager.interruptAndQuit(grace: .seconds(1))
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite(.serialized) @MainActor struct AuthFailureCoordinatorTests {
    /// Before the fix the card read "Turn ended: success", showed the CLI's
    /// failure as if Claude had said it, and offered no sign-in.
    @Test(.timeLimit(.minutes(1)))
    func anExpiredLoginStopsTheCardWithItsReason() async throws {
        let h = try AuthHarness(mode: "expired")
        defer { Task { await h.tearDown() } }
        let card = h.card("Refactor the parser")

        await h.coordinator.sendChat("hello", to: card)
        #expect(await h.waitUntil {
            String(describing: card.lastAssistantSummary).contains("OAuth session expired")
                && h.services.authInterrupted
        })

        let transcript = h.coordinator.live[card.id]?.transcript ?? []
        #expect(h.authNotices(on: card).count == 1)
        #expect(h.authNotices(on: card).first?.text.contains("OAuth session expired") == true)
        #expect(!transcript.contains { $0.kind == .notice && $0.text.hasPrefix("Turn ended") },
                "the generic row still appeared: \(transcript.map(\.text))")
        #expect(!transcript.contains {
            $0.kind == .assistantText && $0.text.contains("Failed to authenticate")
        }, "the CLI's failure was rendered as Claude speaking")
        #expect(card.subState == .error)
        let summaries = card.events.map(\.summary)
        #expect(summaries.contains("Stopped: Claude Code could not authenticate"))
        #expect(!summaries.contains { $0.hasPrefix("Run stopped") })
    }

    /// A rejected key: the real CLI retries it ten times with growing delays.
    /// Overture stops on the first retry, reports it once, and tells an
    /// unattended user.
    @Test(.timeLimit(.minutes(1)))
    func aRejectedKeyIsInterruptedOnTheFirstRetry() async throws {
        let h = try AuthHarness(mode: "retry")
        defer { Task { await h.tearDown() } }
        let card = h.card("Ship the importer")

        await h.coordinator.startExecution(for: card)
        #expect(await h.waitUntil { h.log.contains("control interrupt") })
        #expect(await h.waitUntil {
            h.notices.contains { $0.body.contains("sign in again") }
        })
        #expect(h.authNotices(on: card).count == 1, "three retries, one notice")
        #expect(h.log.filter { $0 == "control interrupt" }.count == 1)
        #expect(h.services.authInterrupted)
    }

    /// After a failure no new agent starts: every one would fail the same way,
    /// and a rejected key would retry for minutes first.
    @Test(.timeLimit(.minutes(1)))
    func noNewAgentStartsAfterAnAuthenticationFailure() async throws {
        let h = try AuthHarness(mode: "expired")
        defer { Task { await h.tearDown() } }
        let first = h.card("First")
        await h.coordinator.sendChat("hello", to: first)
        #expect(await h.waitUntil { h.services.authInterrupted })

        let second = h.card("Second")
        await h.coordinator.sendChat("hello", to: second)
        #expect(h.log.filter { $0 == "user" }.count == 1, "a second agent was spawned")
        #expect(h.coordinator.live[second.id]?.lastError?
            .contains("could not authenticate") == true)

        // A deliberate check that finds a working login lifts the stop.
        await h.services.refreshClaude(reason: .manual)
        #expect(h.services.authInterrupted == false)
    }
}

@Suite struct FailureWordingTests {
    private func result(_ line: String) -> ClaudeEvent.TurnResult? {
        if case .result(let result) = ClaudeEventDecoder.decode(line: line) { return result }
        return nil
    }

    @Test func aFailedTurnMarkedSuccessIsDescribedByItsReason() throws {
        let failed = try #require(result(#"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate. API Error: 401 API key is invalid."}"#))
        #expect(SessionCoordinator.failureDescription(failed)
                == "Failed to authenticate. API Error: 401 API key is invalid.")
    }

    @Test func knownSubtypesKeepTheirWording() throws {
        let capped = try #require(result(#"{"type":"result","subtype":"error_max_turns","is_error":true}"#))
        #expect(SessionCoordinator.failureDescription(capped) == "turn cap reached")
    }

    @Test func theAuthReasonDropsTheRepeatedPrefixAndPeriod() {
        #expect(SessionCoordinator.authFailureReason(
            "Failed to authenticate: OAuth session expired and could not be refreshed")
            == "OAuth session expired and could not be refreshed")
        #expect(SessionCoordinator.authFailureReason(
            "Failed to authenticate. API Error: 401 API key is invalid.")
            == "API Error: 401 API key is invalid")
        #expect(SessionCoordinator.authFailureReason(nil) == nil)
        #expect(SessionCoordinator.authFailureReason("  ") == nil)
    }
}
