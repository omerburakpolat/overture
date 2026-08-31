import Foundation

/// Reads repository status via `git status --porcelain=v2 --branch`.
///
/// Parsing is a pure static function (golden-testable without a repo); the
/// actor method exists so callers on the git layer's milestone cadence
/// (resolution #15 — no FSEvents on agent dirs) have a one-call refresh.
public actor StatusReader {
    private let runner: GitRunner

    public init(runner: GitRunner) {
        self.runner = runner
    }

    /// One status snapshot of `repo`. Never fetches (resolution #18);
    /// ahead/behind reflect last-known remote refs.
    public func status(in repo: URL) async throws -> GitStatus {
        let output = try await runner.run(
            ["status", "--porcelain=v2", "--branch"], in: repo)
        return Self.parse(output)
    }

    /// Parses porcelain v2 output.
    ///
    /// - `branch`: from `# branch.head`; `(detached)` maps to nil.
    /// - `ahead`/`behind`: from `# branch.ab +A -B`; header absent (no
    ///   upstream) means 0/0.
    /// - `dirtyCount`: entry rows `1` (changed), `2` (renamed/copied),
    ///   `u` (unmerged), and `?` (untracked) — "anything uncommitted", which
    ///   is what tiles and queueing decisions care about. Ignored rows (`!`)
    ///   are not counted.
    /// - `hasConflicts`: any `u` row.
    public nonisolated static func parse(_ porcelain: String) -> GitStatus {
        var status = GitStatus()
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                let name = line.dropFirst("# branch.head ".count)
                status.branch = name == "(detached)" ? nil : String(name)
            } else if line.hasPrefix("# branch.ab ") {
                for token in line.dropFirst("# branch.ab ".count)
                    .split(separator: " ") {
                    if token.hasPrefix("+") {
                        status.ahead = Int(token.dropFirst()) ?? 0
                    } else if token.hasPrefix("-") {
                        status.behind = Int(token.dropFirst()) ?? 0
                    }
                }
            } else if line.hasPrefix("u ") {
                status.hasConflicts = true
                status.dirtyCount += 1
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ")
                || line.hasPrefix("? ") {
                status.dirtyCount += 1
            }
        }
        return status
    }
}
