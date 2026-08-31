import Foundation

/// Worktree-per-card lifecycle (spec 02 §5.2): create on Plan entry, list to
/// reconcile the store against reality on launch, remove on Done/delete,
/// prune stale registrations.
public actor WorktreeManager {
    private let runner: GitRunner

    public init(runner: GitRunner) {
        self.runner = runner
    }

    /// `git worktree add <path> -b <branch> <base>` — new branch checked out
    /// at `path`, forked from `base` (normally the project's default branch).
    /// Branch names come from `BranchNaming` (resolution #8).
    public func create(cardSlugBranch branch: String, at path: URL,
                       from base: String, in repo: URL) async throws {
        try await runner.run(
            ["worktree", "add", path.path, "-b", branch, base], in: repo)
    }

    /// Registered worktrees, main worktree first (git's order).
    public func list(in repo: URL) async throws -> [WorktreeInfo] {
        Self.parseList(try await runner.run(
            ["worktree", "list", "--porcelain"], in: repo))
    }

    /// Parses `git worktree list --porcelain`. Records are keyed off
    /// `worktree ` lines rather than blank-line separators — the process
    /// layer's line framer drops empty lines, and porcelain keys are
    /// unambiguous without them. `branch refs/heads/x` is shortened to `x`;
    /// detached and bare worktrees report a nil branch.
    public nonisolated static func parseList(_ porcelain: String) -> [WorktreeInfo] {
        var results: [WorktreeInfo] = []
        var path: String?
        var branch: String?
        var head: String?

        func flush() {
            if let path {
                results.append(WorktreeInfo(path: path, branch: branch, head: head))
            }
            path = nil; branch = nil; head = nil
        }

        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = line.dropFirst("branch ".count)
                branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count))
                    : String(ref)
            }
            // "detached" / "bare" / "locked" / "prunable" rows: no-op, the
            // nil branch already conveys it.
        }
        flush()
        return results
    }

    /// `git worktree remove [--force]`. Force is required when the worktree
    /// is dirty — pass it only from the explicit user confirmation path.
    public func remove(_ path: URL, force: Bool = false, in repo: URL) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path.path)
        try await runner.run(args, in: repo)
    }

    /// `git worktree prune` — drops registrations whose directories vanished
    /// behind our back. Run on app launch per project (spec 02 §5.2).
    public func prune(in repo: URL) async throws {
        try await runner.run(["worktree", "prune"], in: repo)
    }

    /// Idempotently appends `pattern` (e.g. `.overture/worktrees/`) to
    /// `.git/info/exclude`. NEVER the project's `.gitignore` — resolution #2:
    /// Overture must not dirty the repo it manages. Resolves the common git
    /// dir via `rev-parse` so this works from inside a linked worktree too.
    public func ensureExcluded(path pattern: String, in repo: URL) async throws {
        let commonDir = try await runner.run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let infoDir = URL(fileURLWithPath: commonDir).appendingPathComponent("info")
        let excludeFile = infoDir.appendingPathComponent("exclude")

        let existing = (try? String(contentsOf: excludeFile, encoding: .utf8)) ?? ""
        let alreadyPresent = existing
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { $0.trimmingCharacters(in: .whitespaces) == pattern }
        guard !alreadyPresent else { return }

        try FileManager.default.createDirectory(
            at: infoDir, withIntermediateDirectories: true)
        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += pattern + "\n"
        try updated.write(to: excludeFile, atomically: true, encoding: .utf8)
    }
}
