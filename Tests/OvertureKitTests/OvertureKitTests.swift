import Synchronization
import Foundation
import SwiftData
import Testing
@testable import OvertureKit

/// The container must outlive every model instance a test touches —
/// letting it deinit resets the context and invalidates live models.
@MainActor
private struct TestStore {
    let container: ModelContainer
    let context: ModelContext
    let project: Project

    init() throws {
        container = try OvertureStore.container(inMemory: true)
        context = container.mainContext
        project = Project(name: "Test", path: "/tmp/test-repo")
        context.insert(project)
        for tag in Tag.defaultTags() {
            tag.project = project
            context.insert(tag)
        }
        try context.save()
    }
}

@MainActor
private func makeCard(_ context: ModelContext, _ project: Project,
                      column: Column = .backlog,
                      subState: CardSubState = .idle) -> Card {
    let card = Card(title: "Fix login crash", project: project)
    card.column = column
    card.subState = subState
    context.insert(card)
    return card
}

@Suite @MainActor struct SchemaTests {
    @Test func roundTripAllModels() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let card = makeCard(context, project)
        card.tags = project.tags.filter { $0.name == "bug" }
        let session = SessionRef(
            card: card,
            segments: [.init(cwd: "/tmp/x", transcriptPath: "/tmp/x/t.jsonl",
                             from: .now)],
            kind: .work, role: .primary)
        context.insert(session)
        context.insert(TestRun(card: card, kind: .agentDriven,
                               verdict: .fail, summary: "2 failures",
                               failures: [.init(title: "boom", detail: "d")]))
        context.insert(ActivityEvent(card: card, kind: .cardCreated,
                                     summary: "created"))
        context.insert(DeploymentRef(project: project, card: card,
                                     vercelDeploymentID: "dpl_1",
                                     previewURL: "https://x.vercel.app"))
        try context.save()

        let cards = try context.fetch(FetchDescriptor<Card>())
        #expect(cards.count == 1)
        let fetched = try #require(cards.first)
        #expect(fetched.tags.map(\.name) == ["bug"])
        #expect(fetched.sessions.first?.segments.first?.cwd == "/tmp/x")
        #expect(fetched.testRuns.first?.verdict == .fail)
        #expect(fetched.testRuns.first?.failures.first?.title == "boom")
        #expect(project.tags.count == 10)
    }

    @Test func unknownRawValuesDegradeSafely() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let card = makeCard(context, project)
        card.columnRaw = "future-column"
        card.subStateRaw = "future-state"
        #expect(card.column == .backlog)
        #expect(card.subState == .idle)
    }
}

@Suite @MainActor struct DragMatrixTests {
    // Every ALLOWED drag from spec 04 §2.3.
    @Test(arguments: [
        (Column.backlog, CardSubState.idle, Column.plan),
        (Column.backlog, CardSubState.idle, Column.inProgress),
        (Column.plan, CardSubState.awaitingApproval, Column.backlog),
        (Column.plan, CardSubState.awaitingApproval, Column.inProgress),
        (Column.inProgress, CardSubState.idle, Column.plan),
        (Column.inProgress, CardSubState.queued, Column.backlog),
        (Column.inProgress, CardSubState.idle, Column.testing),
        (Column.inProgress, CardSubState.idle, Column.review),
        (Column.testing, CardSubState.manual, Column.inProgress),
        (Column.testing, CardSubState.manual, Column.review),
        (Column.testing, CardSubState.manual, Column.done),
        (Column.review, CardSubState.idle, Column.inProgress),
        (Column.review, CardSubState.idle, Column.testing),
        (Column.review, CardSubState.idle, Column.done),
        (Column.done, CardSubState.idle, Column.inProgress),
    ])
    func allowedDrags(from: Column, subState: CardSubState, to: Column) throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let card = makeCard(context, project, column: from, subState: subState)
        let effects = try BoardEngine.apply(.drag(to: to), to: card, in: context)
        #expect(card.column == to)
        #expect(effects.contains(.announceMove(from: from, to: to)))
    }

    // Every REJECTED drag from spec 04 §2.3.
    @Test(arguments: [
        (Column.backlog, CardSubState.idle, Column.testing),
        (Column.backlog, CardSubState.idle, Column.review),
        (Column.backlog, CardSubState.idle, Column.done),
        (Column.plan, CardSubState.planning, Column.inProgress), // still streaming
        (Column.plan, CardSubState.awaitingApproval, Column.testing),
        (Column.plan, CardSubState.awaitingApproval, Column.done),
        (Column.inProgress, CardSubState.idle, Column.backlog),  // owns a diff
        (Column.inProgress, CardSubState.idle, Column.done),
        (Column.testing, CardSubState.manual, Column.backlog),
        (Column.review, CardSubState.idle, Column.backlog),
        (Column.review, CardSubState.idle, Column.plan),
        (Column.done, CardSubState.idle, Column.review),
        (Column.done, CardSubState.idle, Column.backlog),
    ])
    func rejectedDrags(from: Column, subState: CardSubState, to: Column) throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let card = makeCard(context, project, column: from, subState: subState)
        #expect(throws: TransitionError.self) {
            try BoardEngine.apply(.drag(to: to), to: card, in: context)
        }
        #expect(card.column == from) // unchanged after rejection
    }

    @Test func runningCardsArePinned() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        for subState in [CardSubState.running, .testingRunning] {
            let card = makeCard(context, project,
                                column: subState == .running ? .inProgress : .testing,
                                subState: subState)
            #expect(throws: TransitionError.self) {
                try BoardEngine.apply(.drag(to: .review), to: card, in: context)
            }
        }
    }

    @Test func backlogStartsCreateWorktreeOnlyInWorktreeMode() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        project.executionMode = .worktreePerCard
        let card = makeCard(context, project)
        let effects = try BoardEngine.apply(.drag(to: .plan), to: card,
                                            in: context)
        #expect(effects.contains(.createWorktree))  // at PLAN entry (res. #1)
        #expect(effects.contains(.startPlanSession))

        project.executionMode = .singleDirectory
        let second = makeCard(context, project)
        let secondEffects = try BoardEngine.apply(.drag(to: .plan), to: second,
                                                  in: context)
        #expect(!secondEffects.contains(.createWorktree))
    }
}

@Suite @MainActor struct AutoTransitionTests {
    @Test func runEndedRoutesByAgentTesting() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        project.agentTestingEnabled = true
        let card = makeCard(context, project, column: .inProgress,
                            subState: .running)
        let effects = try BoardEngine.apply(
            .runEnded(success: true, runKind: .autonomousRun),
            to: card, in: context)
        #expect(card.column == .testing)
        #expect(card.subState == .testingRunning)
        #expect(effects.contains(.startAgentTests))

        project.agentTestingEnabled = false
        let second = makeCard(context, project, column: .inProgress,
                              subState: .running)
        try BoardEngine.apply(.runEnded(success: true, runKind: .autonomousRun),
                              to: second, in: context)
        #expect(second.column == .review)
    }

    @Test func interactiveTurnsNeverMoveCards() throws {
        // Resolution #4: the run/turn distinction.
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let card = makeCard(context, project, column: .inProgress,
                            subState: .running)
        let effects = try BoardEngine.apply(
            .runEnded(success: true, runKind: .interactiveChat),
            to: card, in: context)
        #expect(card.column == .inProgress)
        #expect(effects.isEmpty)
    }

    @Test func fixCycleCapsAtTwoThenForcesReview() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let card = makeCard(context, project, column: .testing,
                            subState: .testingRunning)
        // Cycle 1: back to In Progress with a prepared fix message.
        var effects = try BoardEngine.apply(.testsFailed, to: card, in: context)
        #expect(card.column == .inProgress)
        #expect(card.subState == .needsInput)
        #expect(effects.contains(.prepareFixMessage))
        #expect(card.fixCycleCount == 1)
        // Cycle 2.
        card.column = .testing
        card.subState = .testingRunning
        effects = try BoardEngine.apply(.testsFailed, to: card, in: context)
        #expect(card.column == .inProgress)
        #expect(card.fixCycleCount == 2)
        // Cycle 3: cap hit — forced to Review with the red badge.
        card.column = .testing
        card.subState = .testingRunning
        effects = try BoardEngine.apply(.testsFailed, to: card, in: context)
        #expect(card.column == .review)
        #expect(card.subState == .testsFailed)
        #expect(!effects.contains(.prepareFixMessage))
    }

    @Test func reopenFliesBack() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let card = makeCard(context, project, column: .done)
        let effects = try BoardEngine.apply(.reopen, to: card, in: context)
        #expect(card.column == .inProgress)
        #expect(effects.contains(.flyBack))
        #expect(effects.contains(.startExecution))
    }

    @Test func failuresAreSubStatesNotRegressions() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let card = makeCard(context, project, column: .inProgress,
                            subState: .running)
        try BoardEngine.apply(.errored, to: card, in: context)
        #expect(card.column == .inProgress)   // column unchanged
        #expect(card.subState == .error)
        try BoardEngine.apply(.interrupted, to: card, in: context)
        #expect(card.column == .inProgress)
        #expect(card.subState == .interrupted)
    }

    @Test func queuePromotion() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        project.executionMode = .singleDirectory
        let first = makeCard(context, project, column: .inProgress,
                             subState: .running)
        let second = makeCard(context, project, column: .inProgress)
        let third = makeCard(context, project, column: .inProgress)
        try BoardEngine.apply(.queued, to: second, in: context)
        try BoardEngine.apply(.queued, to: third, in: context)
        #expect(second.queuePosition == 0)
        #expect(third.queuePosition == 1)
        _ = first
        let effects = try BoardEngine.apply(.runSlotAvailable, to: second,
                                            in: context)
        #expect(second.subState == .running)
        #expect(second.queuePosition == nil)
        #expect(effects.contains(.startExecution))
    }

    @Test func resumeRunOnlyFromIdleInProgress() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let idle = makeCard(context, project, column: .inProgress)
        let effects = try BoardEngine.apply(.resumeRun, to: idle, in: context)
        #expect(effects == [.startExecution])
        #expect(idle.subState == .running)
        #expect(idle.column == .inProgress)

        let running = makeCard(context, project, column: .inProgress,
                               subState: .running)
        #expect(throws: TransitionError.self) {
            try BoardEngine.apply(.resumeRun, to: running, in: context)
        }
        let reviewed = makeCard(context, project, column: .review)
        #expect(throws: TransitionError.self) {
            try BoardEngine.apply(.resumeRun, to: reviewed, in: context)
        }
    }

    @Test func columnChangeWritesActivityEvent() throws {
        let store = try TestStore()
        let (context, project) = (store.context, store.project)
        let card = makeCard(context, project, column: .done)
        try BoardEngine.apply(.reopen, to: card, in: context)
        try context.save()
        let events = try context.fetch(FetchDescriptor<ActivityEvent>())
        #expect(events.contains { $0.kind == .columnChanged })
    }
}

@Suite struct ColumnOrderingTests {
    @Test func midpointInsertion() {
        #expect(ColumnOrdering.between(nil, nil) == 1024)
        #expect(ColumnOrdering.between(1024, nil) == 2048)
        #expect(ColumnOrdering.between(nil, 1024) == 512)
        #expect(ColumnOrdering.between(1024, 2048) == 1536)
    }

    @Test func renormalizationTrigger() {
        #expect(!ColumnOrdering.needsRenormalization([1, 2, 3]))
        #expect(ColumnOrdering.needsRenormalization([1, 1 + 1e-12]))
        let fresh = ColumnOrdering.renormalized(count: 3)
        #expect(fresh == [1024, 2048, 3072])
    }
}

@Suite struct TestVerdictParserTests {
    @Test func passVerdict() {
        let outcome = TestVerdictParser.parse(
            "Ran the suite.\nAll good.\nVERDICT: PASS")
        #expect(outcome.passed)
        #expect(outcome.failures.isEmpty)
    }

    @Test func failWithBullets() {
        let outcome = TestVerdictParser.parse("""
        Build works but two checks fail.
        VERDICT: FAIL
        - Login times out: token refresh 401s
        - Missing docs
        """)
        #expect(!outcome.passed)
        #expect(outcome.failures.count == 2)
        #expect(outcome.failures[0].title == "Login times out")
        #expect(outcome.failures[0].detail == "token refresh 401s")
        #expect(outcome.failures[1].detail.isEmpty)
    }

    @Test func markdownAndCaseDrift() {
        #expect(TestVerdictParser.parse("**Verdict:** pass").passed)
        #expect(!TestVerdictParser.parse("verdict FAIL").passed)
    }

    @Test func lastVerdictWins() {
        let outcome = TestVerdictParser.parse(
            "VERDICT: FAIL\n- early: x\nRe-ran flaky test.\nVERDICT: PASS")
        #expect(outcome.passed)
        #expect(outcome.failures.isEmpty)
    }

    @Test func noVerdictFailsClosed() {
        let outcome = TestVerdictParser.parse("Everything looked fine!")
        #expect(!outcome.passed)
        #expect(outcome.summary == "No verdict reported")
    }
}

@Suite struct DevServerManagerTests {
    // 45s, not 20s: a login shell on a cold CI runner spends ~10s sourcing
    // its profile before python is even reached, and that stretches further
    // under swift test's parallel load. Measured on macos-26: the port opened
    // at 12s with the machine otherwise idle. The timeout is a ceiling, not a
    // wait — a ready server still returns in well under a second locally.
    @Test(.timeLimit(.minutes(2)))
    func startsProbesAndStops() async throws {
        let manager = DevServerManager(readinessTimeout: .seconds(45))
        let key = UUID()
        let directory = FileManager.default.temporaryDirectory
        // {port} template substitution is the contract (resolution #26).
        let handle = try await manager.start(
            key: key,
            commandTemplate: "python3 -m http.server {port} --bind 127.0.0.1",
            basePort: 8930 + Int.random(in: 0..<50),
            directory: directory)
        #expect(handle.url.absoluteString.hasPrefix("http://localhost:"))
        // Reuse: same key returns the same handle without respawning.
        let again = try await manager.start(
            key: key, commandTemplate: "irrelevant", basePort: 1,
            directory: directory)
        #expect(again == handle)
        let (_, response) = try await URLSession.shared.data(from: handle.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        await manager.stop(key: key)
        #expect(await manager.handle(for: key) == nil)
    }

    @Test func emptyCommandFailsFast() async {
        let manager = DevServerManager()
        await #expect(throws: DevServerManager.ServerError.self) {
            _ = try await manager.start(
                key: UUID(), commandTemplate: "  ", basePort: 3000,
                directory: FileManager.default.temporaryDirectory)
        }
    }
}

// MARK: - Board store observation

@Suite @MainActor struct BoardStoreObservationTests {
    /// The board renders `store.cards(in:)`, which reads `project.cards`. A
    /// freshly created ticket must notify observers of that array, or the
    /// column never re-renders and "New Ticket" appears to do nothing.
    @Test func creatingACardNotifiesColumnObservers() throws {
        let services = try AppServices(inMemory: true)
        let context = services.container.mainContext
        let project = Project(name: "Obs", path: "/tmp/obs-repo")
        context.insert(project)
        try context.save()
        let store = BoardStore(project: project, services: services,
                               coordinator: SessionCoordinator(services: services))

        let fired = Mutex(false)
        withObservationTracking {
            _ = store.cards(in: .backlog)
        } onChange: {
            fired.withLock { $0 = true }
        }
        store.createCard(title: "New", details: "", tags: [])

        #expect(fired.withLock { $0 })
        #expect(store.cards(in: .backlog).map(\.title) == ["New"])
    }
}
