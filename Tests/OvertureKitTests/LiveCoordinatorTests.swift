import Foundation
import SwiftData
import Testing
@testable import OvertureKit
import ClaudeKit
import GitKit

/// The M1 end-to-end: a real card through Backlog → Plan → approve →
/// build → Review with a live claude session, entirely through the same
/// store/engine path the UI calls. Costs tokens — OVERTURE_LIVE_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OVERTURE_LIVE_TESTS"] == "1"))
@MainActor
struct LiveCoordinatorTests {
    @Test(.timeLimit(.minutes(8)))
    func cardRunsPlanApproveBuildReview() async throws {
        // Scratch repo.
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }
        let runner = GitRunner()
        try await runner.run(["init", "-q", "-b", "main"], in: repoURL)
        try await runner.run(["config", "user.email", "e2e@overture"], in: repoURL)
        try await runner.run(["config", "user.name", "e2e"], in: repoURL)
        try "hello\n".write(to: repoURL.appendingPathComponent("README.md"),
                            atomically: true, encoding: .utf8)
        try await runner.run(["add", "-A"], in: repoURL)
        try await runner.run(["commit", "-qm", "init"], in: repoURL)

        // Services + project + card.
        let services = try AppServices(inMemory: true)
        await services.runOnboarding()
        guard case .ready = services.onboarding else {
            Issue.record("onboarding not ready on dev machine")
            return
        }
        let coordinator = SessionCoordinator(services: services)
        let context = services.container.mainContext
        let project = Project(name: "e2e", path: repoURL.path,
                              executionMode: .singleDirectory)
        project.trustedAt = .now
        project.agentTestingEnabled = false
        context.insert(project)
        let card = Card(title: "Add the word DONE to README.md",
                        details: "Append a line containing exactly DONE to "
                            + "README.md. Keep everything else unchanged.",
                        project: project)
        card.model = "haiku"
        context.insert(card)
        try context.save()

        // Backlog → Plan (the drag IS the command).
        let effects = try BoardEngine.apply(.drag(to: .plan), to: card,
                                            in: context)
        #expect(effects.contains(.startPlanSession))
        await coordinator.execute(effects, for: card)

        // Plan streams; ExitPlanMode arrives → awaiting approval. Any
        // question the agent asks is answered the way a decisive user would.
        try await poll(timeout: .seconds(300), label: "plan ready") {
            if let pending = coordinator.live[card.id]?.pendingPermissions.first {
                Task {
                    await coordinator.answerPermission(
                        card: card, requestID: pending.id, allow: false,
                        denyMessage: "Use your best judgment — do not ask "
                            + "further questions. Finish the plan and exit "
                            + "plan mode.")
                }
            }
            return coordinator.live[card.id]?.planApproval != nil
        }
        #expect(card.column == .plan)
        #expect(card.subState == .awaitingApproval)
        #expect(coordinator.live[card.id]?.planApproval?.planText?
            .isEmpty == false)

        // Approve: same session flips into the build.
        await coordinator.approvePlan(card: card)
        #expect(card.column == .inProgress)

        // Build completes → Review (agent testing off).
        try await poll(timeout: .seconds(300), label: "review") {
            card.column == .review
        }
        let readme = try String(
            contentsOf: repoURL.appendingPathComponent("README.md"),
            encoding: .utf8)
        #expect(readme.contains("DONE"))
        #expect(card.totalCostUSD > 0)

        // Session bookkeeping: one primary session, transcript located.
        let session = try #require(card.sessions.first)
        #expect(session.role == .primary)
        #expect(!TranscriptStore.locate(sessionID: session.sessionID).isEmpty)

        // Approve → Done.
        _ = try BoardEngine.apply(.approveToDone, to: card, in: context)
        #expect(card.column == .done)

        _ = await services.processManager.interruptAndQuit(grace: .seconds(5))
    }

    private func poll(timeout: Duration, label: String,
                      _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("timed out waiting for \(label)")
        throw CancellationError()
    }
}

/// Worktree-mode pipeline: card builds on its own branch in an isolated
/// worktree while main stays untouched, then squash-merges into main.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OVERTURE_LIVE_TESTS"] == "1"))
@MainActor
struct LiveWorktreeTests {
    @Test(.timeLimit(.minutes(8)))
    func worktreeCardBuildsInIsolationAndMerges() async throws {
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }
        let runner = GitRunner()
        try await runner.run(["init", "-q", "-b", "main"], in: repoURL)
        try await runner.run(["config", "user.email", "e2e@overture"], in: repoURL)
        try await runner.run(["config", "user.name", "e2e"], in: repoURL)
        try "hello\n".write(to: repoURL.appendingPathComponent("README.md"),
                            atomically: true, encoding: .utf8)
        try await runner.run(["add", "-A"], in: repoURL)
        try await runner.run(["commit", "-qm", "init"], in: repoURL)

        let services = try AppServices(inMemory: true)
        await services.runOnboarding()
        guard case .ready = services.onboarding else {
            Issue.record("onboarding not ready")
            return
        }
        let coordinator = SessionCoordinator(services: services)
        let context = services.container.mainContext
        let project = Project(name: "wt", path: repoURL.path,
                              executionMode: .worktreePerCard)
        project.trustedAt = .now
        project.agentTestingEnabled = false
        context.insert(project)
        let card = Card(title: "Create NOTES.md",
                        details: "Create a file NOTES.md containing the single "
                            + "line WORKTREE-OK, commit it with message "
                            + "'add notes'. Do nothing else.",
                        project: project)
        card.model = "haiku"
        context.insert(card)
        try context.save()

        // Backlog → In Progress directly (skip plan): worktree + branch.
        let effects = try BoardEngine.apply(.drag(to: .inProgress), to: card,
                                            in: context)
        #expect(effects.contains(.createWorktree))
        await coordinator.execute(effects, for: card)
        #expect(card.worktreePath != nil)
        #expect(card.branchName?.hasPrefix("overture/create-notes-md") == true)

        try await poll(timeout: .seconds(300), label: "review") {
            // Safety net: allow anything the allowlist didn't cover.
            if let pending = coordinator.live[card.id]?.pendingPermissions.first {
                Task {
                    await coordinator.answerPermission(
                        card: card, requestID: pending.id, allow: true)
                }
            }
            return card.column == .review
        }
        // Isolation: the file exists in the worktree, NOT in main's checkout.
        let worktree = try #require(card.worktreePath
            .map(URL.init(fileURLWithPath:)))
        #expect(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("NOTES.md").path))
        #expect(!FileManager.default.fileExists(
            atPath: repoURL.appendingPathComponent("NOTES.md").path))

        // Approve → squash-merge into main.
        let branch = try #require(card.branchName)
        try await MergeService(runner: runner).mergeLocally(
            branch: branch, worktreePath: card.worktreePath,
            cardTitle: card.title, cardBody: "", defaultBranch: "main",
            repo: repoURL)
        let merged = try String(
            contentsOf: repoURL.appendingPathComponent("NOTES.md"),
            encoding: .utf8)
        #expect(merged.contains("WORKTREE-OK"))
        // Branch + worktree cleaned up.
        let leftover = try await runner.run(["branch", "--list", branch],
                                            in: repoURL)
        #expect(leftover.isEmpty)
        _ = await services.processManager.interruptAndQuit(grace: .seconds(5))
    }

    private func poll(timeout: Duration, label: String,
                      _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("timed out waiting for \(label)")
        throw CancellationError()
    }
}
