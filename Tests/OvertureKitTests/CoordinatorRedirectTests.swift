import Foundation
import SwiftData
import Testing
@testable import OvertureKit
import ClaudeKit

// The coordinator's "one primary thread" flows, driven end to end against a
// fake `claude` that replays the recorded stream-json shapes from
// Tests/ClaudeKitTests/Fixtures (c-plan: ExitPlanMode allow continues the
// SAME turn; b-interrupt: an interrupt yields an is_error result). No real
// CLI, no network, no ~/.claude writes.

/// A python stand-in for `claude`. Logs every control request it serves to
/// `<script dir>/fake.log` so tests can assert on the wire sequence.
private let fakeClaudeScript = #"""
#!/usr/bin/env python3
import sys, json, os, uuid
log = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake.log"), "a")
def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def note(s):
    log.write(s + "\n"); log.flush()
argv = sys.argv
mode = argv[argv.index("--permission-mode") + 1] if "--permission-mode" in argv else "default"
SID = argv[argv.index("--session-id") + 1] if "--session-id" in argv else str(uuid.uuid4())
phase = "init"
def result(is_error):
    out({"type": "result", "subtype": "error_during_execution" if is_error else "success",
         "is_error": is_error, "duration_ms": 10, "num_turns": 1,
         "result": None if is_error else "Done.", "session_id": SID,
         "total_cost_usd": 0.001, "uuid": str(uuid.uuid4())})
def reply(text):
    out({"type": "assistant", "message": {"role": "assistant", "model": "fake",
         "content": [{"type": "text", "text": text}]}, "parent_tool_use_id": None,
         "session_id": SID, "uuid": str(uuid.uuid4())})
    result(False)
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
        if st == "initialize":
            out({"type": "control_response", "response": {"subtype": "success", "request_id": rid,
                 "response": {"commands": [], "models": []}}})
        elif st == "interrupt":
            note("interrupt phase=" + phase)
            out({"type": "control_response", "response": {"subtype": "success", "request_id": rid,
                 "response": {"still_queued": []}}})
            if phase in ("in_turn", "stalled"):
                phase = "idle"
                out({"type": "user", "message": {"role": "user", "content":
                     [{"type": "text", "text": "[Request interrupted by user]"}]},
                     "parent_tool_use_id": None, "session_id": SID, "uuid": str(uuid.uuid4())})
                result(True)
        elif st == "set_permission_mode":
            mode = o["request"]["mode"]
            note("set_permission_mode " + mode + " phase=" + phase)
            out({"type": "control_response", "response": {"subtype": "success", "request_id": rid,
                 "response": {"mode": mode}}})
        else:
            out({"type": "control_response", "response": {"subtype": "success", "request_id": rid,
                 "response": {}}})
    elif t == "control_response":
        r = o["response"].get("response", {})
        if r.get("behavior") == "allow" and phase == "awaiting_plan_approval":
            # c-plan.jsonl: the tool result lands and the SAME turn keeps going.
            note("plan allowed; continuing the turn")
            out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result",
                 "content": "User has approved your plan.", "tool_use_id": "toolu_plan"}]},
                 "parent_tool_use_id": None, "session_id": SID, "uuid": str(uuid.uuid4())})
            phase = "in_turn"
    elif t == "user":
        text = "".join(b.get("text", "") for b in o["message"]["content"] if b.get("type") == "text")
        note("user mode=" + mode + " phase=" + phase + " text=" + text[:30].replace("\n", " "))
        if phase == "init":
            out({"type": "system", "subtype": "init", "cwd": os.getcwd(), "session_id": SID,
                 "tools": [], "model": "fake", "permissionMode": mode, "uuid": str(uuid.uuid4())})
        if mode == "plan" and phase in ("init", "idle"):
            out({"type": "assistant", "message": {"role": "assistant", "model": "fake", "content":
                 [{"type": "tool_use", "id": "toolu_plan", "name": "ExitPlanMode",
                   "input": {"plan": "# Plan\n"}}]}, "parent_tool_use_id": None,
                 "session_id": SID, "uuid": str(uuid.uuid4())})
            out({"type": "control_request", "request_id": "req-plan-" + str(uuid.uuid4())[:8],
                 "request": {"subtype": "can_use_tool", "tool_name": "ExitPlanMode",
                             "input": {"plan": "# Plan\n"}, "tool_use_id": "toolu_plan"}})
            phase = "awaiting_plan_approval"
        elif "stall" in text:
            phase = "stalled"          # a long turn: answers only to an interrupt
        else:
            was_in_turn = phase == "in_turn"
            phase = "idle"
            reply("Implemented." if was_in_turn else "Sure.")
note("stdin closed")
"""#

@MainActor
private struct Harness {
    let dir: URL
    let services: AppServices
    let coordinator: SessionCoordinator
    let store: BoardStore
    let project: Project

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        try fakeClaudeScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        services = try AppServices(
            inMemory: true,
            journalURL: dir.appendingPathComponent("running-agents.json"))
        services.claudeURLOverride = script
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
    }

    var log: [String] {
        (try? String(contentsOf: dir.appendingPathComponent("fake.log"),
                     encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    func card(_ title: String) -> Card {
        store.createCard(title: title, details: "", tags: [])
    }

    /// Polls a condition on the main actor; the fake answers in milliseconds.
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

@Suite(.serialized) @MainActor struct CoordinatorRedirectTests {
    /// Plan approval continues the very turn that presented the plan
    /// (c-plan.jsonl). The flip must steer it, never interrupt it, and the
    /// build's one result must produce exactly one "Run finished".
    @Test(.timeLimit(.minutes(1)))
    func approvingAPlanSteersTheTurnInsteadOfAbortingIt() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        let card = h.card("Add DONE to README")

        h.store.perform(.startPlan, on: card)
        #expect(await h.waitUntil { h.coordinator.live[card.id]?.planApproval != nil })
        #expect(card.column == .plan && card.subState == .awaitingApproval)

        await h.coordinator.approvePlan(card: card)
        #expect(await h.waitUntil { card.column == .review })

        let log = h.log
        #expect(!log.contains { $0.hasPrefix("interrupt") },
                "the approved turn was interrupted: \(log)")
        #expect(log.contains { $0.hasPrefix("set_permission_mode acceptEdits") })
        let summaries = card.events.map(\.summary)
        #expect(summaries.filter { $0 == "Run finished" }.count == 1)
        #expect(summaries.contains("Build started"))
        #expect(summaries.contains("Plan ready for review"))
        #expect(!summaries.contains { $0.hasPrefix("Run stopped") })
        #expect(card.subState == .idle)
        #expect(!(h.coordinator.live[card.id]?.transcript ?? []).contains {
            $0.kind == .notice && $0.text.hasPrefix("Turn ended")
        })
    }

    /// The composer invites a chat on a Backlog ticket; Plan must then
    /// reuse that process (interrupting a turn in flight) — not collide
    /// with it and strand the card in Plan/error.
    @Test(.timeLimit(.minutes(1)))
    func planAfterAChatRedirectsTheLiveProcess() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        let card = h.card("Investigate flaky test")

        // A chat turn the fake never finishes on its own.
        await h.coordinator.sendChat("please stall on this", to: card)
        #expect(await h.waitUntil {
            h.coordinator.live[card.id]?.activity == .working
        })
        #expect(card.column == .backlog)

        h.store.perform(.startPlan, on: card)
        #expect(await h.waitUntil { h.coordinator.live[card.id]?.planApproval != nil })
        #expect(card.column == .plan)
        #expect(card.subState == .awaitingApproval)
        #expect(h.coordinator.live[card.id]?.lastError == nil)

        let log = h.log
        let interruptAt = log.firstIndex { $0.hasPrefix("interrupt") }
        let flipAt = log.firstIndex { $0.hasPrefix("set_permission_mode plan") }
        #expect(interruptAt != nil && flipAt != nil)
        if let interruptAt, let flipAt { #expect(interruptAt < flipAt) }
        // One process for the card's whole life (spec 04 §4).
        #expect(card.sessions.filter { $0.role == .primary }.count == 1)
        // The cut-short chat turn is not reported as a failure.
        #expect(!(h.coordinator.live[card.id]?.transcript ?? []).contains {
            $0.kind == .notice && $0.text.hasPrefix("Turn ended")
        })
    }

    /// A comment on an idle process that last ran a build is a chat turn:
    /// manual permissions, and its result never moves the card.
    @Test(.timeLimit(.minutes(1)))
    func commentingOnAnIdleBuildProcessIsAChatTurn() async throws {
        let h = try Harness()
        defer { Task { await h.tearDown() } }
        let card = h.card("Rename the module")

        h.store.perform(.drag(to: .inProgress), on: card)
        #expect(await h.waitUntil { card.column == .review })

        await h.coordinator.sendChat("What did you change?", to: card)
        #expect(await h.waitUntil {
            h.coordinator.live[card.id]?.activity == .idle
                && (h.coordinator.live[card.id]?.transcript ?? []).contains {
                    $0.kind == .assistantText && $0.text == "Sure."
                }
        })
        #expect(card.column == .review, "a chat turn moved the card")
        #expect(h.log.contains { $0.hasPrefix("set_permission_mode default") })
        #expect(card.events.filter { $0.summary == "Run finished" }.count == 1)
    }
}
