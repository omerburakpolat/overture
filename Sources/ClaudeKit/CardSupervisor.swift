import Foundation
import ProcessCore

/// What a session is doing right now — drives card sub-state visuals.
public enum AgentActivity: Sendable, Equatable {
    case starting
    case idle          // between turns, process alive
    case working       // assistant output flowing
    case needsInput    // pending permission / question
    case ended(SubprocessExit)
}

/// Why this run exists. `result` events move cards ONLY for autonomous kinds
/// (resolution #4) — the supervisor reports, the BoardEngine decides.
public enum RunKind: String, Sendable {
    case interactiveChat
    case planning
    case autonomousRun
    case testRun
}

/// Everything a consumer (store/BoardEngine) needs to react to a live session.
public enum SupervisorEvent: Sendable {
    case activityChanged(AgentActivity)
    /// The CLI asked permission; answer via `answerPermission(requestID:…)`.
    /// ExitPlanMode and AskUserQuestion arrive here too (check the payload).
    case permissionRequested(requestID: String, request: PermissionRequest)
    /// A pending permission request was cancelled CLI-side.
    case permissionCancelled(requestID: String)
    /// One turn finished. `runKind` is the kind AT TURN START.
    case turnCompleted(ClaudeEvent.TurnResult, runKind: RunKind)
    /// Session identity confirmed (first turn's system/init).
    case sessionStarted(ClaudeEvent.SystemInit)
    /// Retry/rate-limit telemetry for queue policy + banners.
    case apiRetry(ClaudeEvent.APIRetry)
    /// Raw decoded event, for transcript rendering. Deltas are coalesced
    /// upstream of this stream (≤ ~30Hz).
    case event(ClaudeEvent)
    /// Process ended (with or without a final result).
    case processEnded(SubprocessExit, stderrTail: [String])
}

/// Owns exactly one `claude` child process and its protocol state.
/// Persistence-ignorant: emits Sendable values, never touches SwiftData.
public actor CardSupervisor {
    public struct SpawnContext: Sendable {
        public var claudeExecutable: URL
        public var workingDirectory: URL
        public var spec: ClaudeCLI.SessionSpec
        public var runKind: RunKind
        /// Extra env markers (`OVERTURE_CARD_ID`…) for orphan diagnostics.
        public var envMarkers: [String: String]

        public init(claudeExecutable: URL, workingDirectory: URL,
                    spec: ClaudeCLI.SessionSpec, runKind: RunKind,
                    envMarkers: [String: String] = [:]) {
            self.claudeExecutable = claudeExecutable
            self.workingDirectory = workingDirectory
            self.spec = spec
            self.runKind = runKind
            self.envMarkers = envMarkers
        }
    }

    public enum SupervisorError: Error, Sendable {
        case alreadyStarted
        case notRunning
        case noSuchRequest(String)
    }

    private let context: SpawnContext
    private var subprocess: Subprocess?
    private var eventContinuation: AsyncStream<SupervisorEvent>.Continuation?
    private(set) public var runKind: RunKind
    /// The kind the in-flight turn was *sent* under. `runKind` is the kind the
    /// NEXT turn will use, and `setPermissionMode` can change it while a turn
    /// is still working — so a result must be reported against this, not
    /// against whatever `runKind` happens to hold when the result arrives.
    private var turnRunKind: RunKind
    private(set) public var activity: AgentActivity = .starting
    private var pendingPermissions: [String: PermissionRequest] = [:]
    /// Host-initiated control requests awaiting a CLI response.
    private var pendingHostRequests: [String: CheckedContinuation<ControlResponse, Never>] = [:]
    private var sawResultThisTurn = false

    // Delta coalescing: stream_event text batched to ~30Hz.
    private var pendingDelta = false

    public init(context: SpawnContext) {
        self.context = context
        self.runKind = context.runKind
        self.turnRunKind = context.runKind
    }

    public var sessionID: UUID { context.spec.sessionID }
    public var pid: Int32? {
        get async { await subprocess?.pid }
    }

    /// Spawns the process and returns the event stream. The `initialize`
    /// handshake doubles as the liveness probe (M0 finding #1: streaming
    /// startup is silent until the first user message).
    public func start() async throws -> AsyncStream<SupervisorEvent> {
        guard subprocess == nil else { throw SupervisorError.alreadyStarted }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in context.envMarkers { env[key] = value }
        let child = Subprocess(configuration: .init(
            executable: context.claudeExecutable,
            arguments: ClaudeCLI.streamingArguments(for: context.spec),
            currentDirectory: context.workingDirectory,
            environment: env,
            strippedEnvPrefixes: ClaudeCLI.strippedEnvPrefixes))
        subprocess = child

        let (stream, continuation) = AsyncStream.makeStream(
            of: SupervisorEvent.self)
        eventContinuation = continuation

        let lines = try await child.start()
        Task { await self.pump(lines: lines, child: child) }
        Task {
            let exit = await child.waitForExit()
            await self.processDidEnd(exit, child: child)
        }

        // Fire-and-forget handshake; the response confirms liveness and
        // carries commands/models/account for the UI.
        _ = try? await sendHostRequest(
            OutboundControl.initialize(requestID: mintRequestID()))
        return stream
    }

    // MARK: - Consumer API

    /// Sends one user turn (text). The composer is always live — mid-run
    /// sends steer the current turn (CLI-native queueing).
    public func send(userText: String) async throws {
        try await write(OutboundControl.userText(userText))
        // Freeze the kind this turn is reported as. A redirect that retargets
        // the session mid-turn calls setPermissionMode while the previous turn
        // is still working; without the freeze that turn's result came back
        // labelled as the *new* run, and the coordinator treated it as the new
        // run finishing — moving the card out of In Progress before any build
        // had run.
        turnRunKind = runKind
        setActivity(.working)
    }

    public func answerPermission(requestID: String,
                                 verdict: OutboundControl.PermissionVerdict) async throws {
        guard pendingPermissions.removeValue(forKey: requestID) != nil else {
            throw SupervisorError.noSuchRequest(requestID)
        }
        try await write(OutboundControl.permissionResponse(
            requestID: requestID, verdict: verdict))
        if pendingPermissions.isEmpty { setActivity(.working) }
    }

    /// Stop button. `cancelQueued` = stop-means-stop (M0 finding #7).
    public func interrupt(cancelQueued: Bool = true) async throws {
        _ = try await sendHostRequest(OutboundControl.interrupt(
            requestID: mintRequestID(), cancelQueued: cancelQueued))
    }

    /// Plan approval / autonomy toggles. Also updates `runKind` so the next
    /// turn's result routes correctly (plan approved ⇒ autonomous build).
    public func setPermissionMode(_ mode: String,
                                  newRunKind: RunKind? = nil) async throws {
        _ = try await sendHostRequest(OutboundControl.setPermissionMode(
            requestID: mintRequestID(), mode: mode))
        if let newRunKind { runKind = newRunKind }
    }

    public func setModel(_ model: String?) async throws {
        _ = try await sendHostRequest(OutboundControl.setModel(
            requestID: mintRequestID(), model: model))
    }

    /// Graceful detach: interrupt if mid-turn, close stdin, escalate.
    /// The session resumes losslessly later via `--resume`.
    public func detach() async -> SubprocessExit {
        guard let child = subprocess else { return .exited(code: -1) }
        if activity == .working {
            try? await interrupt(cancelQueued: true)
            _ = await child.waitForExit(upTo: .seconds(3))
        }
        return await child.terminate()
    }

    public func kill() async -> SubprocessExit {
        guard let child = subprocess else { return .exited(code: -1) }
        return await child.terminate(gracePeriod: .seconds(1))
    }

    public var pendingPermissionRequests: [String: PermissionRequest] {
        pendingPermissions
    }

    // MARK: - Pump

    private func pump(lines: AsyncStream<String>, child: Subprocess) async {
        for await line in lines {
            handle(ClaudeEventDecoder.decode(line: line))
        }
    }

    private func handle(_ event: ClaudeEvent) {
        switch event {
        case .systemInit(let initInfo):
            emit(.sessionStarted(initInfo))
            setActivity(.working)
        case .apiRetry(let retry):
            emit(.apiRetry(retry))
        case .result(let result):
            emit(.turnCompleted(result, runKind: turnRunKind))
            setActivity(.idle)
        case .controlRequest(let request):
            if let permission = request.permissionRequest {
                pendingPermissions[request.requestID] = permission
                emit(.permissionRequested(requestID: request.requestID,
                                          request: permission))
                setActivity(.needsInput)
            } else {
                // Unknown host-directed request (dialogs, hooks): future
                // milestones render these; ignoring is bounded CLI-side.
                emit(.event(.controlRequest(request)))
            }
        case .controlCancel(let requestID):
            if pendingPermissions.removeValue(forKey: requestID) != nil {
                emit(.permissionCancelled(requestID: requestID))
                if pendingPermissions.isEmpty { setActivity(.working) }
            }
        case .controlResponse(let response):
            if let continuation = pendingHostRequests.removeValue(
                forKey: response.requestID) {
                continuation.resume(returning: response)
            } else {
                emit(.event(.controlResponse(response)))
            }
        case .assistant:
            setActivity(.working)
            emit(.event(event))
        case .streamEvent:
            // Coalesce deltas: at most one signal per frame; transcript
            // consumers re-read accumulated text.
            if !pendingDelta {
                pendingDelta = true
                emit(.event(event))
                Task {
                    try? await Task.sleep(for: .milliseconds(33))
                    await self.clearDeltaGate()
                }
            }
        default:
            emit(.event(event))
        }
    }

    private func clearDeltaGate() { pendingDelta = false }

    private func processDidEnd(_ exit: SubprocessExit, child: Subprocess) async {
        let stderr = await child.stderrSnapshot()
        setActivity(.ended(exit))
        for (_, continuation) in pendingHostRequests {
            continuation.resume(returning: ControlResponse(from: .object([
                "response": .object([
                    "subtype": .string("error"),
                    "request_id": .string(""),
                    "error": .string("process ended"),
                ]),
            ])))
        }
        pendingHostRequests.removeAll()
        emit(.processEnded(exit, stderrTail: stderr))
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Plumbing

    private func write(_ value: JSONValue) async throws {
        guard let child = subprocess else { throw SupervisorError.notRunning }
        try await child.writeLine(OutboundControl.encode(value))
    }

    private func sendHostRequest(_ value: JSONValue) async throws -> ControlResponse {
        guard let requestID = value["request_id"]?.stringValue else {
            preconditionFailure("host request without request_id")
        }
        try await write(value)
        return await withCheckedContinuation { continuation in
            pendingHostRequests[requestID] = continuation
        }
    }

    private func mintRequestID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(12).description
    }

    private func setActivity(_ new: AgentActivity) {
        guard new != activity else { return }
        activity = new
        emit(.activityChanged(new))
    }

    private func emit(_ event: SupervisorEvent) {
        eventContinuation?.yield(event)
    }
}
