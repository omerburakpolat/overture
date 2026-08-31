import Foundation

/// Pure parsers for `git diff` output. Golden-tested; no git invocation here.
public enum DiffParser {
    /// Parses unified diff text (`git diff -U3 [range]`) into files+hunks.
    public static func files(fromUnified text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFileBuilder?
        var hunk: DiffFile.Hunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if let done = hunk { current?.hunks.append(done) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let done = current { files.append(done.build()) }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                flushFile()
                current = DiffFileBuilder(headerLine: line)
            } else if line.hasPrefix("rename from ") {
                current?.oldPath = String(line.dropFirst("rename from ".count))
                current?.change = .renamed
            } else if line.hasPrefix("rename to ") {
                current?.path = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("new file mode") {
                current?.change = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.change = .deleted
            } else if line.hasPrefix("Binary files ") {
                current?.isBinary = true
            } else if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                continue
            } else if line.hasPrefix("@@") {
                flushHunk()
                hunk = DiffFile.Hunk(header: line, lines: [])
                // "@@ -oldStart,count +newStart,count @@ context"
                let numbers = line.split(separator: "@@")[0...]
                _ = numbers
                if let match = line.firstMatch(
                    of: /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
                    oldLine = Int(match.1) ?? 0
                    newLine = Int(match.2) ?? 0
                }
            } else if hunk != nil {
                if line.hasPrefix("+") {
                    hunk?.lines.append(.init(kind: .addition,
                                             text: String(line.dropFirst()),
                                             oldNumber: nil, newNumber: newLine))
                    current?.additions += 1
                    newLine += 1
                } else if line.hasPrefix("-") {
                    hunk?.lines.append(.init(kind: .deletion,
                                             text: String(line.dropFirst()),
                                             oldNumber: oldLine, newNumber: nil))
                    current?.deletions += 1
                    oldLine += 1
                } else if line.hasPrefix(" ") || line.isEmpty {
                    hunk?.lines.append(.init(kind: .context,
                                             text: String(line.dropFirst(min(1, line.count))),
                                             oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1
                    newLine += 1
                }
                // "\ No newline at end of file" rows are ignored.
            }
        }
        flushFile()
        return files
    }

    /// Parses `git diff --numstat [range]` into aggregate stats.
    /// Binary rows report "-\t-\tpath" and count as a changed file with 0/0.
    public static func stats(fromNumstat text: String) -> DiffStats {
        var stats = DiffStats()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            stats.filesChanged += 1
            stats.insertions += Int(parts[0]) ?? 0
            stats.deletions += Int(parts[1]) ?? 0
        }
        return stats
    }

    /// Changed paths for overlap detection (`git diff --name-only base...tip`).
    public static func paths(fromNameOnly text: String) -> Set<String> {
        Set(text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init))
    }

    private struct DiffFileBuilder {
        var path: String
        var oldPath: String?
        var change: DiffFile.Change = .modified
        var additions = 0
        var deletions = 0
        var hunks: [DiffFile.Hunk] = []
        var isBinary = false

        /// "diff --git a/<old> b/<new>" — the b-side is the current path.
        init(headerLine: String) {
            if let match = headerLine.firstMatch(of: /diff --git a\/(.+) b\/(.+)/) {
                path = String(match.2)
                let aSide = String(match.1)
                oldPath = aSide == path ? nil : aSide
            } else {
                path = headerLine
            }
        }

        func build() -> DiffFile {
            DiffFile(path: path, oldPath: oldPath, change: change,
                     additions: additions, deletions: deletions,
                     hunks: isBinary ? [] : hunks)
        }
    }
}

/// Snapshot refs for single-directory Review diffs (spec 04 §9.2):
/// `refs/overture/cards/<id>/base` pins where work started.
public actor SnapshotRefs {
    private let runner: GitRunner

    public init(runner: GitRunner) {
        self.runner = runner
    }

    public static func refName(cardID: UUID) -> String {
        "refs/overture/cards/\(cardID.uuidString.lowercased())/base"
    }

    /// Pins HEAD as the card's diff base at execution start.
    public func writeBase(cardID: UUID, in repo: URL) async throws -> String {
        let sha = try await runner.run(["rev-parse", "HEAD"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await runner.run(["update-ref", Self.refName(cardID: cardID), sha],
                             in: repo)
        return sha
    }

    public func readBase(cardID: UUID, in repo: URL) async throws -> String? {
        try? await runner.run(
            ["rev-parse", "--verify", Self.refName(cardID: cardID)], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Deleted on Done (the diff becomes unavailable — stated in the sheet).
    public func deleteBase(cardID: UUID, in repo: URL) async throws {
        try await runner.run(["update-ref", "-d", Self.refName(cardID: cardID)],
                             in: repo)
    }

    /// Merge-base for worktree-mode Review diffs (spec 02 §5.3).
    public func mergeBase(of branch: String, and base: String,
                          in repo: URL) async throws -> String {
        try await runner.run(["merge-base", base, branch], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
