import Accessibility
import Foundation
import SwiftData
import ClaudeKit
import ProcessCore
import GitKit

/// One pending `can_use_tool` surfaced on a card.
public struct PendingPermission: Sendable, Identifiable, Equatable {
    public var id: String            // control request_id
    public var toolName: String
    public var displayInput: String  // command/path excerpt for the sheet
    public var planText: String?     // ExitPlanMode only
    public var suggestionsAvailable: Bool

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// One live transcript row (streamed; history comes from TranscriptReader).
/// `id` is the CLI's own message `uuid` (or `tool_use` id) whenever the
/// stream carries one, so `CardThread` can drop the row the moment the
/// transcript on disk contains it.
public struct LiveChatItem: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case user
        case assistantText
        case toolUse(name: String)
        case notice          // interrupts, errors, budget banners
    }
    public var id: String
    public var kind: Kind
    public var text: String
    public var at: Date = .now

    /// Rows Overture appended itself (the user's own message, before the
    /// CLI echoes it back with its transcript uuid) carry this prefix.
    public static let provisionalPrefix = "local-"
    public var isProvisional: Bool { id.hasPrefix(Self.provisionalPrefix) }
}

/// Bridges CardSupervisor event streams to the board: transitions via
/// BoardEngine, permission requests to the UI, denormalized snapshots to the
/// store. The ONLY component that both talks to ClaudeKit and mutates cards.
@MainActor
@Observable
public final class SessionCoordinator {
    /// Live per-card UI state (cleared when the process ends).
    public struct LiveState: Sendable {
        public var activity: AgentActivity = .starting
        public var pendingPermissions: [PendingPermission] = []
        public var planApproval: PendingPermission?
        public var transcript: [LiveChatItem] = []
        public var streamingText = ""
        public var lastError: String?
        /// Bumped whenever the transcript on disk has likely grown (turn
        /// ended, process ended, session started) — the thread view reloads
        /// history on change and drops the live rows it now finds on disk.
        public var historyGeneration = 0
    }

    public private(set) var live: [UUID: LiveState] = [:]

    /// User-facing moments the app surfaces as system notifications
    /// (posted only when Overture is not frontmost — the app decides).
    public struct Notice: Sendable {
        public enum Kind: Sendable {
            case agentFinished, needsInput, testsFailed, agentErrored
        }
        public var cardID: UUID
        public var cardTitle: String
        public var kind: Kind
        public var body: String
    }

    /// Set by the app target; nil in headless/test contexts.
    public var onNotice: (@MainActor (Notice) -> Void)?

    private let services: AppServices
    private var pumps: [UUID: Task<Void, Never>] = [:]

    public init(services: AppServices) {
        self.services = services
    }

    private var context: ModelContext { services.container.mainContext }

    // MARK: - Entry points (called by BoardStore effect execution / UI)

    /// Starts the card's plan session (Plan column entry).
    public func startPlanSession(for card: Card) async {
        guard let project = card.project else { return }
        let prompt = Self.planPrompt(for: card)
        if let supervisor = await services.processManager.supervisor(for: card.id) {
            // The composer invites a chat before Plan; that process is the
            // card's one primary thread (spec 04 §4), so flip it into plan
            // mode rather than spawning a second one for the same card.
            await redirect(supervisor, card: card, mode: .plan,
                           runKind: .planning, message: prompt,
                           interruptInFlight: true)
            return
        }
        await spawn(card: card, project: project, profile: .plan,
                    runKind: .planning, kind: .plan, initialMessage: prompt)
    }

    /// Cards whose in-flight turn Overture itself cut short (Stop, or a
    /// redirect): the error result that follows is not a failure to report.
    private var interruptsPending: Set<UUID> = []

    /// Re-points a live primary process at a new run kind: optionally cuts
    /// short a turn in flight, flips the permission posture, records the
    /// start, and sends the message that begins the new run.
    ///
    /// `interruptInFlight` is false for the plan→build flip: after an
    /// ExitPlanMode allow the turn in flight already IS the build (spec 04
    /// §6, same session and context), so the message steers it (§7.3)
    /// instead of aborting it. When a turn is cut short, the flip waits for
    /// its error result so that result still carries the old run kind.
    private func redirect(_ supervisor: CardSupervisor, card: Card,
                          mode: ClaudeCLI.PermissionProfile, runKind: RunKind,
                          message: String, interruptInFlight: Bool) async {
        if interruptInFlight, await supervisor.activity == .working {
            interruptsPending.insert(card.id)
            try? await supervisor.interrupt(cancelQueued: true)
            let deadline = ContinuousClock.now + .seconds(5)
            while await supervisor.activity == .working,
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        try? await supervisor.setPermissionMode(mode.modeFlag,
                                                newRunKind: runKind)
        appendLive(card.id, Self.provisionalUserRow(message))
        ActivityLog.record(.agentStarted, Self.startSummary(runKind),
                           on: card, in: context)
        try? context.save()
        try? await supervisor.send(userText: message)
    }

    /// Starts (or resumes) autonomous execution. Enforces the project's run
    /// slots (spec 04 §7.4): single-dir = 1, worktree = maxParallelAgents;
    /// at capacity the card queues and is promoted when a slot frees.
    public func startExecution(for card: Card) async {
        guard let project = card.project else { return }
        let othersRunning = project.cards.filter {
            $0.id != card.id && $0.archivedAt == nil && $0.subState.pinsCard
        }.count
        let slots = project.executionMode == .singleDirectory
            ? 1 : max(1, project.maxParallelAgents)
        if othersRunning >= slots {
            try? BoardEngine.apply(.queued, to: card, in: context)
            try? context.save()
            return
        }
        let profile = project.claudePermissionMode.profile
        let continuation = "Continue working on this ticket:\n\n\(Self.ticketText(card))"
        if let supervisor = await services.processManager.supervisor(for: card.id) {
            // Same process, same context: a plan session flipping to build
            // is told its plan is approved; a chat or finished build is told
            // to carry on with the ticket.
            let wasPlanning = await supervisor.runKind == .planning
            await redirect(supervisor, card: card, mode: profile,
                           runKind: .autonomousRun,
                           message: wasPlanning
                               ? "The plan is approved — implement it now."
                               : continuation,
                           interruptInFlight: !wasPlanning)
            return
        }
        let message = card.sessions.contains(where: { $0.role == .primary })
            ? continuation
            : Self.executionPrompt(for: card)
        await spawn(card: card, project: project, profile: profile,
                    runKind: .autonomousRun, kind: .work,
                    initialMessage: message)
    }

    /// Interactive chat: ensures a manual-mode session and sends the message.
    public func sendChat(_ message: String, to card: Card) async {
        guard let project = card.project else { return }
        if let supervisor = await services.processManager.supervisor(for: card.id) {
            // Mid-turn, the message steers the running agent (spec 04 §7.3)
            // and the run keeps its kind. Between turns it is a chat turn:
            // manual permissions, and its result never moves the card
            // (resolutions #4, #10) — so the idle process is re-posed first.
            if await supervisor.activity == .idle,
               await supervisor.runKind != .interactiveChat {
                try? await supervisor.setPermissionMode(
                    ClaudeCLI.PermissionProfile.askMe.modeFlag,
                    newRunKind: .interactiveChat)
            }
            appendLive(card.id, Self.provisionalUserRow(message))
            try? await supervisor.send(userText: message)
            return
        }
        await spawn(card: card, project: project, profile: .askMe,
                    runKind: .interactiveChat, kind: .work,
                    initialMessage: message)
    }

    public func answerPermission(card: Card, requestID: String,
                                 allow: Bool, always: Bool = false,
                                 denyMessage: String = "") async {
        guard let supervisor = await services.processManager
            .supervisor(for: card.id) else { return }
        let pending = await supervisor.pendingPermissionRequests[requestID]
        let verdict: OutboundControl.PermissionVerdict
        if allow, let pending {
            // "Always allow": echo the CLI's own suggestions back verbatim.
            verdict = .allow(updatedInput: pending.input,
                             updatedPermissions: always
                                ? pending.suggestions : nil)
        } else {
            verdict = .deny(message: denyMessage.isEmpty
                ? "The user declined." : denyMessage)
        }
        try? await supervisor.answerPermission(requestID: requestID,
                                               verdict: verdict)
        let answered = live[card.id]?.pendingPermissions.first { $0.id == requestID }
        live[card.id]?.pendingPermissions.removeAll { $0.id == requestID }
        if card.subState == .needsInput {
            card.subState = .running
        }
        if let answered, let pending {
            ActivityLog.record(
                .toolUse,
                Self.decisionSummary(for: pending, toolName: answered.toolName,
                                     allow: allow, denyMessage: denyMessage),
                on: card, in: context)
            try? context.save()
        }
    }

    /// The persisted one-liner for a permission decision (spec 04 §3.1 lists
    /// them in the activity feed). Only a command or path is kept — never
    /// the model's prose or raw tool input (spec 02 §3.1).
    nonisolated static func decisionSummary(for request: PermissionRequest,
                                            toolName: String, allow: Bool,
                                            denyMessage: String) -> String {
        if request.isAskUserQuestion {
            let answer = Self.oneLine(denyMessage)
            return answer.isEmpty ? "Answered Claude's question"
                                  : "Answered: \(answer.prefix(160))"
        }
        let target = request.input["command"]?.stringValue
            ?? request.input["file_path"]?.stringValue
        let what = target.map { "\(toolName) · \(Self.oneLine($0).prefix(80))" }
            ?? toolName
        return (allow ? "Allowed " : "Denied ") + what
    }

    nonisolated static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Marks the plan a turn ended with (no ExitPlanMode call to answer).
    public static let syntheticPlanID = "synthetic-plan"

    /// Plan approval: allow ExitPlanMode, flip mode, move the card.
    public func approvePlan(card: Card) async {
        guard let approval = live[card.id]?.planApproval,
              let supervisor = await services.processManager
                  .supervisor(for: card.id) else { return }
        if approval.id != Self.syntheticPlanID {
            let pending = await supervisor.pendingPermissionRequests[approval.id]
            try? await supervisor.answerPermission(
                requestID: approval.id,
                verdict: .allow(updatedInput: pending?.input ?? .null))
        }
        live[card.id]?.planApproval = nil
        ActivityLog.record(.userNote, "Plan approved", on: card, in: context)
        if let effects = try? BoardEngine.apply(.approvePlan, to: card,
                                                in: context) {
            await execute(effects, for: card)
        }
        try? context.save()
    }

    public func requestPlanChanges(card: Card, feedback: String) async {
        guard let approval = live[card.id]?.planApproval,
              let supervisor = await services.processManager
                  .supervisor(for: card.id) else { return }
        try? await supervisor.answerPermission(
            requestID: approval.id,
            verdict: .deny(message: feedback))
        live[card.id]?.planApproval = nil
        // Deny reasons reach the model as a tool result, never as an
        // echoed user turn, so the request lives in the activity row.
        ActivityLog.record(.userNote,
                           "Requested plan changes: \(Self.oneLine(feedback).prefix(200))",
                           on: card, in: context)
        try? BoardEngine.apply(.requestPlanChanges, to: card, in: context)
        try? context.save()
    }

    public func interrupt(card: Card) async {
        guard let supervisor = await services.processManager
            .supervisor(for: card.id) else { return }
        interruptsPending.insert(card.id)
        try? await supervisor.interrupt(cancelQueued: true)
        try? BoardEngine.apply(.interrupted, to: card, in: context)
        try? context.save()
    }

    /// Executes BoardEngine effects. BoardStore calls this after user drags.
    public func execute(_ effects: [TransitionEffect], for card: Card) async {
        for effect in effects {
            switch effect {
            case .startPlanSession:
                await startPlanSession(for: card)
            case .startExecution:
                await startExecution(for: card)
            case .createWorktree:
                await createWorktree(for: card)
            case .removeWorktree:
                await removeWorktree(for: card)
            case .promoteNextQueuedCard:
                await promoteNextQueued(project: card.project)
            case .startAgentTests:
                await startAgentTests(for: card)
            case .announceMove(let from, let to):
                announceMove(card: card, from: from, to: to)
            case .resumeSessionForFeedback, .prepareFixMessage,
                 .openMergeSheet, .flyBack:
                // Rendered/driven by the UI layer (composer prefill, sheets,
                // animations).
                continue
            }
        }
    }

    // MARK: - Agent-driven testing (spec 04 §8.3)

    /// Test-session registry keys, distinct from the primary supervisor's.
    private var testSessionKeys: [UUID: UUID] = [:]

    /// Fresh session, role `.test`: verify-don't-fix — Edit/Write excluded
    /// from the tool set (resolution #20), Bash allowlisted so runs never
    /// stall on permissions, budget-capped. Verdict parsed from the final
    /// message's `VERDICT:` line (streaming mode has no --json-schema).
    public func startAgentTests(for card: Card) async {
        guard let project = card.project,
              let claudeURL = services.claudeURL,
              testSessionKeys[card.id] == nil else { return }
        let cwd = card.worktreePath.map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: project.path)
        let sessionID = UUID()
        let key = UUID()
        let spec = ClaudeCLI.SessionSpec(
            sessionID: sessionID,
            profile: .autonomous,
            model: card.model,
            allowedTools: ["Bash"],
            maxBudgetUSD: project.testBudgetUSD > 0 ? project.testBudgetUSD : 3,
            tools: "Bash,Read,Glob,Grep",
            settingSources: ProcessInfo.processInfo
                .environment["OVERTURE_MINIMAL_CLAUDE_ENV"] == "1" ? "" : nil,
            strictMCPConfig: ProcessInfo.processInfo
                .environment["OVERTURE_MINIMAL_CLAUDE_ENV"] == "1")
        do {
            let stream = try await services.processManager.start(
                cardID: card.id, key: key,
                context: .init(claudeExecutable: claudeURL,
                               workingDirectory: cwd,
                               spec: spec, runKind: .testRun))
            testSessionKeys[card.id] = key
            let sessionRef = SessionRef(sessionID: sessionID, card: card,
                                        segments: [.init(cwd: cwd.path,
                                                         transcriptPath: "",
                                                         from: .now)],
                                        kind: .testing, role: .test)
            context.insert(sessionRef)
            card.sessions.append(sessionRef)
            let run = TestRun(card: card, kind: .agentDriven,
                              command: project.testCommand,
                              agentSessionID: sessionID)
            context.insert(run)
            card.testRuns.append(run)
            ActivityLog.record(.agentStarted, "Agent test run started",
                               on: card, in: context)
            try? context.save()
            let cardID = card.id
            let runID = run.id
            Task { [weak self] in
                await self?.pumpTest(stream, cardID: cardID, runID: runID,
                                     key: key)
            }
            if let supervisor = await services.processManager
                .supervisor(for: key) {
                try? await supervisor.send(
                    userText: Self.testPrompt(for: card, project: project))
            }
        } catch {
            // No slot / spawn failure: fall through to Review un-verified.
            if let effects = try? BoardEngine.apply(
                .testsPassed(verdict: .manualPass), to: card, in: context) {
                await execute(effects, for: card)
            }
            try? context.save()
        }
    }

    private func pumpTest(_ stream: AsyncStream<SupervisorEvent>,
                          cardID: UUID, runID: UUID, key: UUID) async {
        for await event in stream {
            guard let card = fetchCard(cardID) else { continue }
            switch event {
            case .turnCompleted(let result, _):
                card.totalCostUSD += result.totalCostUSD ?? 0
                finishTestRun(card: card, runID: runID,
                              resultText: result.resultText,
                              isError: result.isError)
                if let supervisor = await services.processManager
                    .supervisor(for: key) {
                    _ = await supervisor.detach()
                }
            case .permissionRequested(let requestID, _):
                // Test sessions must never stall: deny with steering.
                if let supervisor = await services.processManager
                    .supervisor(for: key) {
                    try? await supervisor.answerPermission(
                        requestID: requestID,
                        verdict: .deny(message: "Not permitted during a test "
                            + "run — verify by other means and report."))
                }
            case .processEnded:
                testSessionKeys[cardID] = nil
            default:
                break
            }
        }
    }

    private func finishTestRun(card: Card, runID: UUID,
                               resultText: String?, isError: Bool) {
        let run = card.testRuns.first { $0.id == runID }
        let verdict = TestVerdictParser.parse(resultText ?? "")
        run?.finishedAt = .now
        run?.summary = verdict.summary
        run?.failures = verdict.failures
        if isError {
            run?.status = .aborted
            run?.verdict = nil
        } else {
            run?.status = verdict.passed ? .passed : .failed
            run?.verdict = verdict.passed ? .pass : .fail
        }
        ActivityLog.record(
            .testRunFinished,
            (verdict.passed && !isError ? "Tests passed" : "Tests failed")
                + (verdict.summary.isEmpty ? "" : " — \(verdict.summary)"),
            on: card, in: context)
        if isError || !verdict.passed {
            onNotice?(.init(cardID: card.id, cardTitle: card.title,
                            kind: .testsFailed,
                            body: verdict.summary))
        }
        let transition: CardTransition = (verdict.passed && !isError)
            ? .testsPassed(verdict: .pass) : .testsFailed
        if let effects = try? BoardEngine.apply(transition, to: card,
                                                in: context) {
            Task { await self.execute(effects, for: card) }
        }
        try? context.save()
    }

    static func testPrompt(for card: Card, project: Project) -> String {
        var prompt = """
        You are verifying finished work — do NOT fix anything. Build/run \
        the checks and verify each acceptance criterion by the cheapest \
        honest means. \

        """
        if let command = project.testCommand, !command.isEmpty {
            prompt += "The project's test command is: \(command)\n"
        }
        prompt += """

        ## Ticket under test
        \(ticketText(card))

        End your final message with exactly one line:
        VERDICT: PASS
        or
        VERDICT: FAIL
        followed (on failure) by one bullet per failure: - <title>: <detail>
        """
        return prompt
    }

    // MARK: - Spawning

    private func spawn(card: Card, project: Project,
                       profile: ClaudeCLI.PermissionProfile,
                       runKind: RunKind, kind: SessionKind,
                       initialMessage: String) async {
        guard let claudeURL = services.claudeURL else { return }
        guard project.trustedAt != nil else {
            live[card.id, default: .init()].lastError =
                "Project not trusted yet — allow Overture to run Claude here first."
            return
        }
        let cwd = card.worktreePath.map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: project.path)

        // Resume the primary session when one exists; mint otherwise.
        let existing = card.sessions.first { $0.role == .primary }
        let sessionID = existing?.sessionID ?? UUID()
        // Debug/test knob: a clean claude environment (no user settings,
        // no MCP) — product sessions load everything (spec 01 §6).
        let minimalEnv = ProcessInfo.processInfo
            .environment["OVERTURE_MINIMAL_CLAUDE_ENV"] == "1"
        let autonomous = profile == .autonomous || profile == .fullAuto
        let spec = ClaudeCLI.SessionSpec(
            sessionID: sessionID,
            resume: existing != nil,
            profile: profile,
            model: card.model,
            effort: card.effort,
            allowedTools: autonomous
                ? ClaudeCLI.defaultAutonomousAllowRules : [],
            maxBudgetUSD: project.runBudgetUSD > 0 ? project.runBudgetUSD : nil,
            settingSources: minimalEnv ? "" : nil,
            strictMCPConfig: minimalEnv)

        do {
            let stream = try await services.processManager.start(
                cardID: card.id,
                context: .init(claudeExecutable: claudeURL,
                               workingDirectory: cwd,
                               spec: spec, runKind: runKind))
            if existing == nil {
                let sessionRef = SessionRef(
                    sessionID: sessionID, card: card,
                    segments: [.init(cwd: cwd.path, transcriptPath: "",
                                     from: .now)],
                    kind: kind, role: .primary, isCurrent: true)
                context.insert(sessionRef)
                card.sessions.append(sessionRef)
            }
            var fresh = LiveState()
            fresh.historyGeneration = (live[card.id]?.historyGeneration ?? 0) + 1
            live[card.id] = fresh
            appendLive(card.id, Self.provisionalUserRow(initialMessage))
            ActivityLog.record(.agentStarted, Self.startSummary(runKind),
                               on: card, in: context)
            try? context.save()
            let cardID = card.id
            pumps[cardID] = Task { [weak self] in
                await self?.pump(stream, cardID: cardID)
            }
            if let supervisor = await services.processManager
                .supervisor(for: card.id) {
                try? await supervisor.send(userText: initialMessage)
            }
        } catch {
            live[card.id, default: .init()].lastError =
                "Could not start Claude: \(error)"
            try? BoardEngine.apply(.errored, to: card, in: context)
            try? context.save()
        }
    }

    // MARK: - Event pump

    private func pump(_ stream: AsyncStream<SupervisorEvent>,
                      cardID: UUID) async {
        for await event in stream {
            handle(event, cardID: cardID)
        }
        pumps[cardID] = nil
    }

    private func handle(_ event: SupervisorEvent, cardID: UUID) {
        guard let card = fetchCard(cardID) else { return }
        switch event {
        case .activityChanged(let activity):
            live[cardID, default: .init()].activity = activity

        case .sessionStarted(let initInfo):
            // Glob the transcript now that the file exists (resolution #5).
            if let session = card.sessions.first(where: {
                $0.sessionID.uuidString.lowercased() == initInfo.sessionID
            }), var segment = session.segments.last,
               segment.transcriptPath.isEmpty,
               let found = TranscriptStore.locate(
                   sessionID: session.sessionID).first {
                segment.transcriptPath = found.path
                var segments = session.segments
                segments[segments.count - 1] = segment
                session.segments = segments
            }
            live[cardID, default: .init()].historyGeneration += 1

        case .permissionRequested(let requestID, let request):
            if request.isExitPlanMode {
                live[cardID, default: .init()].planApproval = PendingPermission(
                    id: requestID, toolName: request.toolName,
                    displayInput: "", planText: request.planText,
                    suggestionsAvailable: false)
                if (try? BoardEngine.apply(.planReady, to: card,
                                           in: context)) != nil {
                    ActivityLog.record(.agentFinished, "Plan ready for review",
                                       on: card, in: context)
                }
            } else {
                live[cardID, default: .init()].pendingPermissions.append(
                    PendingPermission(
                        id: requestID,
                        toolName: request.toolName,
                        displayInput: Self.excerpt(request),
                        planText: nil,
                        suggestionsAvailable:
                            !(request.suggestions.arrayValue ?? []).isEmpty))
                card.subState = .needsInput
                onNotice?(.init(cardID: cardID, cardTitle: card.title,
                                kind: .needsInput,
                                body: "\(request.toolName): "
                                    + Self.excerpt(request).prefix(80)))
            }
            try? context.save()

        case .permissionCancelled(let requestID):
            live[cardID]?.pendingPermissions.removeAll { $0.id == requestID }

        case .turnCompleted(let result, let runKind):
            card.totalCostUSD += result.totalCostUSD ?? 0
            if let text = result.resultText, !text.isEmpty {
                card.lastAssistantSummary = String(text.prefix(200))
            }
            card.lastActivityAt = .now
            live[cardID, default: .init()].historyGeneration += 1
            live[cardID]?.streamingText = ""
            if runKind == .planning, !result.isError,
               live[cardID]?.planApproval == nil, card.column == .plan {
                // The model presented its plan as text without calling
                // ExitPlanMode (models do this) — the final message IS the
                // plan; approval then just flips the session into build.
                live[cardID, default: .init()].planApproval =
                    PendingPermission(id: Self.syntheticPlanID,
                                      toolName: "ExitPlanMode",
                                      displayInput: "",
                                      planText: result.resultText,
                                      suggestionsAvailable: false)
                try? BoardEngine.apply(.planReady, to: card, in: context)
                ActivityLog.record(.agentFinished, "Plan ready for review",
                                   on: card, in: context)
            }
            if runKind == .interactiveChat, card.subState == .running {
                // A chat turn never moves the card (resolution #4), but it
                // must not leave it pinned as "running" with an idle agent.
                card.subState = .idle
            }
            // A user interrupt already shows as the transcript's own
            // interjection line; only genuine failures get a row.
            let interrupted = card.subState == .interrupted
                || (result.isError && interruptsPending.contains(cardID))
            // Consumed by whichever result arrives first, however it ended. A
            // Stop that raced the turn finishing cleanly used to leave the flag
            // set for the life of the process — the supervisor outlives a turn,
            // so the *next* genuine failure was then silently misread as that
            // interrupt: no "Run stopped" row, no notification, and a card left
            // in an error sub-state with nothing to explain it.
            interruptsPending.remove(cardID)
            let buildEnded = runKind == .autonomousRun
                && card.column == .inProgress   // mirrors BoardEngine's guard
            if buildEnded, !interrupted {
                ActivityLog.record(
                    result.isError ? .agentNeedsInput : .agentFinished,
                    result.isError
                        ? "Run stopped: \(Self.describe(result.subtype))"
                        : "Run finished",
                    on: card, in: context)
            } else if result.isError, !interrupted, runKind != .testRun,
                      runKind != .autonomousRun {
                appendLive(cardID, .init(
                    id: UUID().uuidString, kind: .notice,
                    text: "Turn ended: \(Self.describe(result.subtype))"))
            }
            if let effects = try? BoardEngine.apply(
                .runEnded(success: !result.isError,
                          runKind: AgentRunKind(runKind)),
                to: card, in: context) {
                Task { await self.execute(effects, for: card) }
            }
            if buildEnded, !interrupted {
                onNotice?(.init(cardID: cardID, cardTitle: card.title,
                                kind: result.isError ? .agentErrored
                                                     : .agentFinished,
                                body: result.isError
                                    ? "The run failed — see the card."
                                    : "Finished — waiting in "
                                      + card.column.displayName + "."))
            }
            try? context.save()

        case .apiRetry(let retry):
            if retry.errorCategory == "rate_limit" {
                appendLive(cardID, .init(
                    id: UUID().uuidString, kind: .notice,
                    text: "Claude usage limit — retrying automatically."))
            }

        case .event(let claudeEvent):
            renderLive(claudeEvent, cardID: cardID, card: card)

        case .processEnded(let exit, let stderrTail):
            if case .exited(code: 0) = exit {} else if live[cardID]?
                .activity != .ended(exit) {
                live[cardID]?.lastError = stderrTail.suffix(3)
                    .joined(separator: "\n")
            }
            live[cardID]?.activity = .ended(exit)
            live[cardID]?.streamingText = ""
            interruptsPending.remove(cardID)
            live[cardID, default: .init()].historyGeneration += 1
            for session in card.sessions where session.exitReason == nil {
                session.endedAt = .now
                session.exitReason = .completed
            }
            try? context.save()
        }
    }

    private func renderLive(_ event: ClaudeEvent, cardID: UUID, card: Card) {
        switch event {
        case .assistant(let message):
            // Subagent traffic is a sidechain in the transcript — it never
            // shows in the primary thread (spec 01 §2.1).
            guard message.parentToolUseID == nil else { return }
            if !message.text.isEmpty {
                appendLive(cardID, .init(
                    id: message.raw["uuid"]?.stringValue ?? UUID().uuidString,
                    kind: .assistantText, text: message.text))
                live[cardID]?.streamingText = ""
            }
            for tool in message.toolUses {
                appendLive(cardID, .init(
                    id: tool.id, kind: .toolUse(name: tool.name),
                    text: ToolDetail.summary(input: tool.input)))
                card.lastAssistantSummary = "\(tool.name)…"
            }
        case .user(let raw):
            // `--replay-user-messages`: the CLI echoes the user's text back
            // with its transcript uuid — adopt it so the row de-duplicates.
            if var items = live[cardID]?.transcript {
                Self.acknowledgeUserEcho(raw, in: &items)
                live[cardID]?.transcript = items
            }
        case .streamEvent(let raw):
            guard raw["parent_tool_use_id"]?.stringValue == nil else { return }
            if let delta = raw["event"]?["delta"]?["text"]?.stringValue {
                live[cardID, default: .init()].streamingText += delta
            }
        default:
            break
        }
    }

    /// Matches an echoed user message (text blocks only — tool results are
    /// user-role too) to the newest provisional row with the same text and
    /// gives that row the CLI's uuid.
    nonisolated static func acknowledgeUserEcho(_ raw: JSONValue,
                                                in items: inout [LiveChatItem]) {
        guard let uuid = raw["uuid"]?.stringValue else { return }
        let message = raw["message"]
        let text: String
        if let plain = message?["content"]?.stringValue {
            text = plain
        } else {
            let blocks = message?["content"]?.arrayValue ?? []
            guard !blocks.contains(where: {
                $0["type"]?.stringValue == "tool_result"
            }) else { return }
            text = blocks.compactMap { block -> String? in
                block["type"]?.stringValue == "text"
                    ? block["text"]?.stringValue : nil
            }.joined()
        }
        guard !text.isEmpty else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = items.lastIndex(where: {
            $0.kind == .user && $0.isProvisional
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    == normalized
        }) {
            items[index].id = uuid
        }
    }

    nonisolated static func provisionalUserRow(_ text: String) -> LiveChatItem {
        .init(id: LiveChatItem.provisionalPrefix + UUID().uuidString,
              kind: .user, text: text)
    }

    nonisolated static func startSummary(_ runKind: RunKind) -> String {
        switch runKind {
        case .planning: "Planning started"
        case .autonomousRun: "Build started"
        case .interactiveChat: "Chat started"
        case .testRun: "Agent test run started"
        }
    }

    /// Human wording for a `result` subtype (open set; keep the raw for
    /// anything new).
    nonisolated static func describe(_ subtype: String) -> String {
        switch subtype {
        case "error_max_budget_usd": "budget cap reached"
        case "error_max_turns": "turn cap reached"
        case "error_during_execution": "execution error"
        default: subtype.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: - Helpers

    private func createWorktree(for card: Card) async {
        guard let project = card.project,
              project.executionMode == .worktreePerCard,
              card.worktreePath == nil else { return }
        let repo = URL(fileURLWithPath: project.path)
        let branch = BranchNaming.branchName(cardTitle: card.title,
                                             cardID: card.id)
        let root = project.worktreeRoot.map(URL.init(fileURLWithPath:))
            ?? repo.appendingPathComponent(".overture/worktrees")
        let path = root.appendingPathComponent(
            String(branch.split(separator: "/").last ?? "card"))
        let runner = GitRunner()
        let manager = WorktreeManager(runner: runner)
        do {
            try await manager.ensureExcluded(path: ".overture/", in: repo)
            try await manager.create(cardSlugBranch: branch, at: path,
                                     from: project.defaultBranch, in: repo)
            card.branchName = branch
            card.worktreePath = path.path
            try? context.save()
        } catch {
            live[card.id, default: .init()].lastError =
                "Worktree creation failed: \(error)"
        }
    }

    private func removeWorktree(for card: Card) async {
        guard let project = card.project,
              let worktreePath = card.worktreePath else { return }
        let manager = WorktreeManager(runner: GitRunner())
        try? await manager.remove(URL(fileURLWithPath: worktreePath),
                                  in: URL(fileURLWithPath: project.path))
        card.worktreePath = nil
        try? context.save()
    }

    private func promoteNextQueued(project: Project?) async {
        guard let project else { return }
        let queued = project.cards
            .filter { $0.queuePosition != nil && $0.archivedAt == nil }
            .sorted { ($0.queuePosition ?? 0) < ($1.queuePosition ?? 0) }
        guard let next = queued.first else { return }
        if let effects = try? BoardEngine.apply(.runSlotAvailable, to: next,
                                                in: context) {
            await execute(effects, for: next)
        }
        try? context.save()
    }

    private func fetchCard(_ id: UUID) -> Card? {
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func appendLive(_ cardID: UUID, _ item: LiveChatItem) {
        live[cardID, default: .init()].transcript.append(item)
    }

    /// VoiceOver parity for agent-driven moves (spec 03 §8.3): sighted users
    /// see the card travel; VO users hear it.
    private func announceMove(card: Card, from: Column, to: Column) {
        AccessibilityNotification.Announcement(
            "\(card.title) moved to \(to.rawValue)").post()
    }

    // MARK: - Prompt composition

    static func ticketText(_ card: Card) -> String {
        card.details.isEmpty ? card.title : "\(card.title)\n\n\(card.details)"
    }

    static func planPrompt(for card: Card) -> String {
        """
        Plan the implementation of this ticket. Identify acceptance criteria \
        before designing. Keep the plan reviewable. Prefer deciding over \
        asking — make reasonable assumptions and note them in the plan; only \
        ask a question when genuinely blocked. When the plan is complete, \
        exit plan mode to present it for approval.

        ## Ticket
        \(ticketText(card))
        """
    }

    static func executionPrompt(for card: Card) -> String {
        """
        Implement this ticket. Verify your work compiles/passes tests before \
        finishing.

        ## Ticket
        \(ticketText(card))
        """
    }

    static func excerpt(_ request: PermissionRequest) -> String {
        if request.isAskUserQuestion {
            // Render the actual questions; M1 answers them through the
            // banner's text field (deny-with-message steers the model).
            let questions = (request.input["questions"]?.arrayValue ?? [])
                .compactMap { $0["question"]?.stringValue }
            if !questions.isEmpty {
                return questions.joined(separator: "\n")
            }
        }
        if let command = request.input["command"]?.stringValue {
            return command
        }
        if let path = request.input["file_path"]?.stringValue {
            return path
        }
        return String(OutboundControl.encode(request.input).prefix(200))
    }

}
