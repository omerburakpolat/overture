import Foundation
import SwiftData
import ClaudeKit
import GitKit

/// Per-open-project board state: cards by column, drag handling through
/// BoardEngine, rejection toasts.
@MainActor
@Observable
public final class BoardStore {
    public struct Toast: Identifiable, Sendable, Equatable {
        public var id = UUID()
        public var message: String
    }

    public let project: Project
    public private(set) var toast: Toast?

    private let services: AppServices
    private let coordinator: SessionCoordinator

    public init(project: Project, services: AppServices,
                coordinator: SessionCoordinator) {
        self.project = project
        self.services = services
        self.coordinator = coordinator
    }

    private var context: ModelContext { services.container.mainContext }

    /// Cards for one column, ordered; archived cards excluded.
    public func cards(in column: Column) -> [Card] {
        project.cards
            .filter { $0.column == column && $0.archivedAt == nil }
            .sorted { $0.columnOrder < $1.columnOrder }
    }

    /// A user drag landed. Applies the matrix; rejection becomes a toast.
    public func drop(cardID: UUID, into column: Column) {
        guard let card = project.cards.first(where: { $0.id == cardID }) else {
            return
        }
        do {
            let effects = try BoardEngine.apply(.drag(to: column), to: card,
                                                in: context)
            try context.save()
            Task { await coordinator.execute(effects, for: card) }
        } catch let error as TransitionError {
            toast = Toast(message: error.reason)
            Task { [id = toast?.id] in
                try? await Task.sleep(for: .seconds(4))
                if toast?.id == id { toast = nil }
            }
        } catch {
            toast = Toast(message: "\(error)")
        }
    }

    /// Creates a ticket in Backlog.
    @discardableResult
    public func createCard(title: String, details: String,
                           tags: [Tag]) -> Card {
        let last = cards(in: .backlog).last?.columnOrder
        let card = Card(title: title, details: details, project: project)
        card.columnOrder = ColumnOrdering.between(last, nil)
        card.tags = tags
        context.insert(card)
        context.insert(ActivityEvent(card: card, kind: .cardCreated,
                                     summary: "Ticket created"))
        try? context.save()
        return card
    }

    // MARK: - Approve → Done (spec 04 §9)

    public enum ApproveChoice: Sendable {
        case mergeLocally        // worktree: squash-merge + cleanup
        case openPR              // worktree: push + gh pr create
        case commitSingleDir     // single-dir: stage + commit
        case leaveUncommitted    // single-dir: user owns the commit
        case justMarkDone        // no git action (branch/worktree kept)
    }

    /// Card awaiting the merge sheet; set by the approval entry points.
    public var mergeCandidate: Card?

    public func requestApproval(_ card: Card) {
        guard card.column == .review || card.column == .testing else {
            toast = Toast(message: "Approve from Review (or Testing).")
            return
        }
        mergeCandidate = card
    }

    /// Executes the chosen pipeline, then applies Approve→Done. Returns a
    /// user-facing error (card stays put) or nil on success.
    public func approve(_ card: Card, choice: ApproveChoice) async -> String? {
        let repo = URL(fileURLWithPath: project.path)
        let service = MergeService()
        do {
            switch choice {
            case .mergeLocally:
                guard let branch = card.branchName else {
                    throw MergeService.MergeError.missingBranch
                }
                try await service.mergeLocally(
                    branch: branch, worktreePath: card.worktreePath,
                    cardTitle: card.title, cardBody: card.details,
                    defaultBranch: project.defaultBranch, repo: repo)
                card.worktreePath = nil
            case .openPR:
                guard let branch = card.branchName else {
                    throw MergeService.MergeError.missingBranch
                }
                let body = card.details.isEmpty
                    ? (card.lastAssistantSummary ?? "")
                    : card.details
                let pr = try await service.openPR(
                    branch: branch, worktreePath: card.worktreePath,
                    title: card.title, body: body, repo: repo,
                    github: GitHubService())
                card.prNumber = pr.number
                card.prURL = pr.url
                card.worktreePath = nil
            case .commitSingleDir:
                try await service.commitSingleDir(
                    cardID: card.id, cardTitle: card.title,
                    cardBody: card.details, repo: repo)
            case .leaveUncommitted:
                await service.leaveUncommitted(cardID: card.id, repo: repo)
            case .justMarkDone:
                break
            }
        } catch let error as MergeService.MergeError {
            if case .conflicts(let files) = error {
                try? BoardEngine.apply(.mergeConflictDetected, to: card,
                                       in: context)
                try? context.save()
                return "Merge conflicts in: "
                    + files.prefix(5).joined(separator: ", ")
            }
            return Self.describe(error)
        } catch {
            return "\(error)"
        }
        do {
            let effects = try BoardEngine.apply(.approveToDone, to: card,
                                                in: context)
            try context.save()
            Task { await coordinator.execute(effects, for: card) }
            return nil
        } catch let error as TransitionError {
            return error.reason
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Derived git state (resolution #15: milestone recompute,
    // never FSEvents on agent dirs)

    /// Titles of other active cards touching the same files, per card.
    public private(set) var overlaps: [UUID: [String]] = [:]

    /// Recomputes cached diff stats + overlapping-file warnings for active
    /// cards. Called on board appear and after runs end/cards move.
    public func refreshDerivedGitState() async {
        let repo = URL(fileURLWithPath: project.path)
        let runner = GitRunner()
        let refs = SnapshotRefs(runner: runner)
        let active = project.cards.filter {
            $0.archivedAt == nil
                && [.inProgress, .testing, .review].contains($0.column)
        }
        var changedPaths: [UUID: Set<String>] = [:]

        for card in active {
            let range: String?
            if let branch = card.branchName {
                range = (try? await refs.mergeBase(
                    of: branch, and: project.defaultBranch, in: repo))
                    .map { "\($0)...\(branch)" }
            } else if let base = card.baseRef {
                range = base   // single-dir: snapshot ref vs working tree
            } else {
                range = nil
            }
            guard let range else { continue }
            if let numstat = try? await runner.run(
                ["diff", "--numstat", range], in: repo) {
                let stats = DiffParser.stats(fromNumstat: numstat)
                card.cachedFilesChanged = stats.filesChanged
                card.cachedInsertions = stats.insertions
                card.cachedDeletions = stats.deletions
            }
            if project.executionMode == .worktreePerCard,
               let names = try? await runner.run(
                ["diff", "--name-only", range], in: repo) {
                changedPaths[card.id] = DiffParser.paths(fromNameOnly: names)
            }
        }

        // Pairwise intersection → "overlaps <other card>" chips (spec 04
        // §10): first to merge wins; the second hits the conflict flow.
        var result: [UUID: [String]] = [:]
        for card in active {
            guard let mine = changedPaths[card.id] else { continue }
            let others = active.filter {
                $0.id != card.id
                    && changedPaths[$0.id]?.isDisjoint(with: mine) == false
            }
            if !others.isEmpty {
                result[card.id] = others.map(\.title)
            }
        }
        overlaps = result
        try? context.save()
    }

    /// "Ask Claude to resolve" on a merge-conflicted card: back to
    /// In Progress with a rebase instruction to the primary session.
    public func resolveConflictWithClaude(_ card: Card) {
        _ = try? BoardEngine.apply(.requestChanges, to: card, in: context)
        try? context.save()
        let instruction = "The merge into \(project.defaultBranch) has "
            + "conflicts. Rebase your branch onto \(project.defaultBranch), "
            + "resolve the conflicts preserving both intents, and verify the "
            + "build still passes."
        Task { await coordinator.sendChat(instruction, to: card) }
    }

    private static func describe(_ error: MergeService.MergeError) -> String {
        switch error {
        case .defaultBranchNotCheckedOut(let current):
            "Check out the default branch first (currently on "
            + "\(current ?? "detached HEAD"))."
        case .defaultBranchDirty(let count):
            "The default branch has \(count) uncommitted change"
            + "\(count == 1 ? "" : "s") — commit or stash first."
        case .conflicts:
            "Merge conflicts."
        case .missingBranch:
            "This card has no branch to merge."
        case .github(let detail):
            "GitHub: \(detail)"
        }
    }

    public func reopen(_ card: Card) {
        do {
            let effects = try BoardEngine.apply(.reopen, to: card, in: context)
            try context.save()
            Task { await coordinator.execute(effects, for: card) }
        } catch {}
    }

    public func archive(_ card: Card) {
        try? BoardEngine.apply(.archive, to: card, in: context)
        try? context.save()
    }
}

/// Home screen: projects, add/remove, trust gate, cached git status.
@MainActor
@Observable
public final class ProjectsStore {
    public enum AddError: Error, Equatable {
        case notAGitRepo(URL)
    }

    private let services: AppServices
    public private(set) var gitStatus: [UUID: GitStatus] = [:]
    /// "Last chat" from Claude Code's own store — covers sessions run in a
    /// terminal or Desktop against the same project, not just Overture's.
    public private(set) var lastChat: [UUID: TranscriptSummary] = [:]

    public init(services: AppServices) {
        self.services = services
    }

    private var context: ModelContext { services.container.mainContext }

    public var projects: [Project] {
        let descriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.sortOrder),
                     SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Adds a project folder. Must be a git repo (spec 04 §12) — callers
    /// offer one-click `git init` on `.notAGitRepo`.
    @discardableResult
    public func addProject(at url: URL) throws -> Project {
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".git").path) else {
            throw AddError.notAGitRepo(url)
        }
        let project = Project(name: url.lastPathComponent, path: url.path,
                              sortOrder: projects.count)
        context.insert(project)
        for tag in Tag.defaultTags() {
            tag.project = project
            context.insert(tag)
        }
        try? context.save()
        return project
    }

    public func initializeRepo(at url: URL) async throws {
        let runner = GitRunner()
        try await runner.run(["init", "-b", "main"], in: url)
    }

    /// The per-project trust gate decision (resolution #12).
    public func trust(_ project: Project) {
        project.trustedAt = .now
        try? context.save()
    }

    /// Removes from Overture only — `.overture/` and the repo stay.
    public func remove(_ project: Project) {
        context.delete(project)
        try? context.save()
    }

    /// Milestone-cadence git refresh for visible tiles (resolution #15 —
    /// no FSEvents on agent dirs; tiles refresh on appear + timer).
    public func refreshGitStatus(for project: Project) async {
        let reader = StatusReader(runner: GitRunner())
        if let status = try? await reader.status(
            in: URL(fileURLWithPath: project.path)) {
            gitStatus[project.id] = status
        }
        // Cheap tail-read of the newest transcript in the project's cwd.
        let path = project.path
        let summary = await Task.detached(priority: .utility) {
            TranscriptStore.newestTranscript(forCWD: path)
                .map { TranscriptReader.summary(of: $0) }
        }.value
        if let summary {
            lastChat[project.id] = summary
        }
    }
}
