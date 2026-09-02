import Foundation
import SwiftData
import ClaudeKit
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
public struct LiveChatItem: Sendable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case user
        case assistantText
        case toolUse(name: String)
        case notice          // interrupts, errors, budget banners
    }
    public var id: String
    public var kind: Kind
    public var text: String
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
        await spawn(card: card, project: project, profile: .plan,
                    runKind: .planning, kind: .plan, initialMessage: prompt)
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
        if let supervisor = await services.processManager.supervisor(for: card.id) {
            // Plan session flipping to build: same process, same context.
            try? await supervisor.setPermissionMode(
                project.claudePermissionMode.profile.modeFlag,
                newRunKind: .autonomousRun)
            try? await supervisor.send(userText:
                "The plan is approved — implement it now.")
            return
        }
        let profile = project.claudePermissionMode.profile
        let message = card.sessions.contains(where: { $0.role == .primary })
            ? "Continue working on this ticket:\n\n\(Self.ticketText(card))"
            : Self.executionPrompt(for: card)
        await spawn(card: card, project: project, profile: profile,
                    runKind: .autonomousRun, kind: .work,
                    initialMessage: message)
    }

    /// Interactive chat: ensures a manual-mode session and sends the message.
    public func sendChat(_ message: String, to card: Card) async {
        guard let project = card.project else { return }
        if let supervisor = await services.processManager.supervisor(for: card.id) {
            appendLive(card.id, .init(id: UUID().uuidString, kind: .user,
                                      text: message))
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
        live[card.id]?.pendingPermissions.removeAll { $0.id == requestID }
        if card.subState == .needsInput {
            card.subState = .running
        }
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
        try? BoardEngine.apply(.requestPlanChanges, to: card, in: context)
        try? context.save()
    }

    public func interrupt(card: Card) async {
        guard let supervisor = await services.processManager
            .supervisor(for: card.id) else { return }
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
            case .resumeSessionForFeedback, .prepareFixMessage,
                 .openMergeSheet, .announceMove, .flyBack:
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
            let run = TestRun(card: card, kind: .agentDriven,
                              command: project.testCommand,
                              agentSessionID: sessionID)
            context.insert(run)
            try? context.save()
            appendLive(card.id, .init(id: UUID().uuidString, kind: .notice,
                                      text: "Agent test run started."))
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
        appendLive(card.id, .init(
            id: UUID().uuidString, kind: .notice,
            text: "Agent tests: \(verdict.passed && !isError ? "passed" : "failed") — \(verdict.summary)"))
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
        let spec = ClaudeCLI.SessionSpec(
            sessionID: sessionID,
            resume: existing != nil,
            profile: profile,
            model: card.model,
            effort: card.effort,
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
            }
            live[card.id] = LiveState()
            appendLive(card.id, .init(id: UUID().uuidString, kind: .user,
                                      text: initialMessage))
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

        case .permissionRequested(let requestID, let request):
            if request.isExitPlanMode {
                live[cardID, default: .init()].planApproval = PendingPermission(
                    id: requestID, toolName: request.toolName,
                    displayInput: "", planText: request.planText,
                    suggestionsAvailable: false)
                try? BoardEngine.apply(.planReady, to: card, in: context)
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
            }
            if let effects = try? BoardEngine.apply(
                .runEnded(success: !result.isError,
                          runKind: AgentRunKind(runKind)),
                to: card, in: context) {
                Task { await self.execute(effects, for: card) }
            }
            if runKind == .autonomousRun {
                onNotice?(.init(cardID: cardID, cardTitle: card.title,
                                kind: result.isError ? .agentErrored
                                                     : .agentFinished,
                                body: result.isError
                                    ? "The run failed — see the card."
                                    : "Finished — waiting in "
                                      + card.column.rawValue + "."))
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
            if !message.text.isEmpty {
                appendLive(cardID, .init(id: UUID().uuidString,
                                         kind: .assistantText,
                                         text: message.text))
                live[cardID]?.streamingText = ""
            }
            for tool in message.toolUses {
                appendLive(cardID, .init(
                    id: tool.id, kind: .toolUse(name: tool.name),
                    text: Self.toolSummary(tool)))
                card.lastAssistantSummary = "\(tool.name)…"
            }
        case .streamEvent(let raw):
            if let delta = raw["event"]?["delta"]?["text"]?.stringValue {
                live[cardID, default: .init()].streamingText += delta
            }
        default:
            break
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

    static func toolSummary(_ tool: ClaudeEvent.AssistantMessage.ToolUse) -> String {
        if let command = tool.input["command"]?.stringValue { return command }
        if let path = tool.input["file_path"]?.stringValue { return path }
        return ""
    }
}
