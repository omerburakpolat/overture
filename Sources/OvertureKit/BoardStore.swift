import Foundation
import SwiftData
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

    public func markDone(_ card: Card) {
        do {
            let effects = try BoardEngine.apply(.approveToDone, to: card,
                                                in: context)
            try context.save()
            Task { await coordinator.execute(effects, for: card) }
        } catch let error as TransitionError {
            toast = Toast(message: error.reason)
        } catch {}
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
    }
}
