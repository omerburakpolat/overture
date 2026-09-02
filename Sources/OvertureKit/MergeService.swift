import Foundation
import GitKit

/// Executes the Approve→Done pipeline (spec 04 §9): local squash-merge or
/// PR in worktree mode; commit or leave-uncommitted in single-dir mode.
/// The board never leaves a repo mid-merge — conflicts abort cleanly.
public struct MergeService: Sendable {
    public enum MergeError: Error, Sendable, Equatable {
        case defaultBranchNotCheckedOut(current: String?)
        case defaultBranchDirty(count: Int)
        case conflicts(files: [String])
        case missingBranch
        case github(String)
    }

    private let runner: GitRunner

    public init(runner: GitRunner = GitRunner()) {
        self.runner = runner
    }

    /// Squash-merges the card's branch into the default branch, commits with
    /// the card title, removes the worktree, deletes the branch.
    public func mergeLocally(branch: String, worktreePath: String?,
                             cardTitle: String, cardBody: String,
                             defaultBranch: String,
                             repo: URL) async throws {
        let status = try await StatusReader(runner: runner).status(in: repo)
        guard status.branch == defaultBranch else {
            throw MergeError.defaultBranchNotCheckedOut(current: status.branch)
        }
        guard status.isClean else {
            throw MergeError.defaultBranchDirty(count: status.dirtyCount)
        }
        do {
            try await runner.run(["merge", "--squash", branch], in: repo)
        } catch {
            // Conflicted squash leaves a dirty index — always reset.
            let conflicted = (try? await runner.run(
                ["diff", "--name-only", "--diff-filter=U"], in: repo)) ?? ""
            try? await runner.run(["reset", "--merge"], in: repo)
            throw MergeError.conflicts(files: conflicted
                .split(separator: "\n").map(String.init))
        }
        let message = cardBody.isEmpty
            ? cardTitle : "\(cardTitle)\n\n\(cardBody)"
        try await runner.run(["commit", "-m", message], in: repo)
        try await cleanup(branch: branch, worktreePath: worktreePath,
                          repo: repo, deleteBranch: true)
    }

    /// Pushes the branch and opens a PR via gh. The branch survives until
    /// the PR merges (spec 04 §9.1); the worktree is removed.
    public func openPR(branch: String, worktreePath: String?,
                       title: String, body: String,
                       repo: URL,
                       github: GitHubService) async throws -> (number: Int, url: String) {
        try await runner.run(["push", "-u", "origin", branch], in: repo)
        let result: (number: Int, url: String)
        do {
            result = try await github.prCreate(head: branch, title: title,
                                               body: body, in: repo)
        } catch let error as GitHubService.ServiceError {
            throw MergeError.github(String(describing: error))
        }
        try await cleanup(branch: branch, worktreePath: worktreePath,
                          repo: repo, deleteBranch: false)
        return result
    }

    /// Single-dir approve: stage everything and commit with the card title;
    /// the snapshot ref is deleted (the diff becomes unavailable).
    public func commitSingleDir(cardID: UUID, cardTitle: String,
                                cardBody: String, repo: URL) async throws {
        try await runner.run(["add", "-A"], in: repo)
        let message = cardBody.isEmpty
            ? cardTitle : "\(cardTitle)\n\n\(cardBody)"
        try await runner.run(["commit", "-m", message], in: repo)
        try? await SnapshotRefs(runner: runner)
            .deleteBase(cardID: cardID, in: repo)
    }

    /// Single-dir approve without committing — user owns the commit.
    public func leaveUncommitted(cardID: UUID, repo: URL) async {
        try? await SnapshotRefs(runner: runner)
            .deleteBase(cardID: cardID, in: repo)
    }

    private func cleanup(branch: String, worktreePath: String?,
                         repo: URL, deleteBranch: Bool) async throws {
        let worktrees = WorktreeManager(runner: runner)
        if let worktreePath {
            try? await worktrees.remove(URL(fileURLWithPath: worktreePath),
                                        force: true, in: repo)
        }
        if deleteBranch {
            try? await runner.run(["branch", "-D", branch], in: repo)
        }
        try? await worktrees.prune(in: repo)
    }
}
