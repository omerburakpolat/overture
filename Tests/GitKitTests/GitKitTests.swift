import Foundation
import Testing
@testable import GitKit

/// A throwaway repo built with the real git CLI. Inline -c identity so CI
/// needs no global config; removed on deinit.
private struct FixtureRepo: ~Copyable {
    let url: URL
    let runner = GitRunner()

    init() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-gitkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"])
        try await git(["config", "user.email", "test@overture"])
        try await git(["config", "user.name", "Overture Tests"])
        try "hello\n".write(to: url.appendingPathComponent("README.md"),
                            atomically: true, encoding: .utf8)
        try await git(["add", "-A"])
        try await git(["commit", "-qm", "init"])
    }

    @discardableResult
    func git(_ args: [String]) async throws -> String {
        try await runner.run(args, in: url)
    }

    func write(_ name: String, _ content: String) throws {
        try content.write(to: url.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite struct StatusReaderTests {
    @Test func cleanRepo() async throws {
        let repo = try await FixtureRepo()
        let status = try await StatusReader(runner: repo.runner)
            .status(in: repo.url)
        #expect(status.branch == "main")
        #expect(status.isClean)
        #expect(status.ahead == 0 && status.behind == 0)
    }

    @Test func dirtyAndUntracked() async throws {
        let repo = try await FixtureRepo()
        try repo.write("README.md", "changed\n")
        try repo.write("new.txt", "untracked\n")
        let status = try await StatusReader(runner: repo.runner)
            .status(in: repo.url)
        #expect(status.dirtyCount == 2)
        #expect(!status.hasConflicts)
    }

    @Test func conflictDetection() async throws {
        let repo = try await FixtureRepo()
        try await repo.git(["checkout", "-qb", "feature"])
        try repo.write("README.md", "feature\n")
        try await repo.git(["commit", "-aqm", "feature"])
        try await repo.git(["checkout", "-q", "main"])
        try repo.write("README.md", "main\n")
        try await repo.git(["commit", "-aqm", "main"])
        // The merge conflicts; git exits non-zero — expected.
        _ = try? await repo.git(["merge", "feature"])
        let status = try await StatusReader(runner: repo.runner)
            .status(in: repo.url)
        #expect(status.hasConflicts)
        try await repo.git(["merge", "--abort"])
        let after = try await StatusReader(runner: repo.runner)
            .status(in: repo.url)
        #expect(!after.hasConflicts)  // never leaves the repo mid-merge
    }

    @Test func parseAheadBehindHeader() {
        let status = StatusReader.parse("""
        # branch.oid abc123
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -1
        """)
        #expect(status.ahead == 3)
        #expect(status.behind == 1)
        #expect(status.branch == "main")
    }

    @Test func detachedHeadIsNilBranch() {
        let status = StatusReader.parse("# branch.head (detached)")
        #expect(status.branch == nil)
    }
}

@Suite struct WorktreeTests {
    @Test func createListRemove() async throws {
        let repo = try await FixtureRepo()
        let manager = WorktreeManager(runner: repo.runner)
        let branch = BranchNaming.branchName(cardTitle: "Fix login crash!",
                                             cardID: UUID())
        #expect(branch.hasPrefix("overture/fix-login-crash-"))
        let path = repo.url.appendingPathComponent(".overture/worktrees/wt1")

        try await manager.create(cardSlugBranch: branch, at: path,
                                 from: "main", in: repo.url)
        let listed = try await manager.list(in: repo.url)
        #expect(listed.count == 2)  // main + the new one
        #expect(listed.contains { $0.branch == branch })

        try await manager.remove(path, in: repo.url)
        let after = try await manager.list(in: repo.url)
        #expect(after.count == 1)
        try await manager.prune(in: repo.url)
    }

    @Test func excludeIsIdempotentAndNeverTouchesGitignore() async throws {
        let repo = try await FixtureRepo()
        let manager = WorktreeManager(runner: repo.runner)
        try await manager.ensureExcluded(path: ".overture/worktrees/",
                                         in: repo.url)
        try await manager.ensureExcluded(path: ".overture/worktrees/",
                                         in: repo.url)
        let exclude = try String(
            contentsOf: repo.url.appendingPathComponent(".git/info/exclude"),
            encoding: .utf8)
        let occurrences = exclude.components(
            separatedBy: ".overture/worktrees/").count - 1
        #expect(occurrences == 1)
        #expect(!FileManager.default.fileExists(
            atPath: repo.url.appendingPathComponent(".gitignore").path))
    }

    @Test func parseListPorcelain() {
        let listed = WorktreeManager.parseList("""
        worktree /repo
        HEAD abc123
        branch refs/heads/main
        worktree /repo/.overture/worktrees/x
        HEAD def456
        branch refs/heads/overture/x-12345678
        worktree /repo/.overture/worktrees/detached
        HEAD 999999
        detached
        """)
        #expect(listed.count == 3)
        #expect(listed[0].branch == "main")
        #expect(listed[1].branch == "overture/x-12345678")
        #expect(listed[2].branch == nil)
    }
}

@Suite struct SnapshotRefTests {
    @Test func writeReadDeleteRoundTrip() async throws {
        let repo = try await FixtureRepo()
        let refs = SnapshotRefs(runner: repo.runner)
        let cardID = UUID()
        let sha = try await refs.writeBase(cardID: cardID, in: repo.url)
        #expect(sha.count == 40)
        #expect(try await refs.readBase(cardID: cardID, in: repo.url) == sha)
        try await refs.deleteBase(cardID: cardID, in: repo.url)
        #expect(try await refs.readBase(cardID: cardID, in: repo.url) == nil)
    }

    @Test func mergeBaseDiff() async throws {
        let repo = try await FixtureRepo()
        try await repo.git(["checkout", "-qb", "feature"])
        try repo.write("feature.txt", "one\ntwo\n")
        try await repo.git(["add", "-A"])
        try await repo.git(["commit", "-qm", "add feature file"])
        let refs = SnapshotRefs(runner: repo.runner)
        let base = try await refs.mergeBase(of: "feature", and: "main",
                                            in: repo.url)
        let numstat = try await repo.git(
            ["diff", "--numstat", "\(base)...feature"])
        let stats = DiffParser.stats(fromNumstat: numstat)
        #expect(stats.filesChanged == 1)
        #expect(stats.insertions == 2)
    }
}

@Suite struct DiffParserTests {
    static let multiHunk = """
    diff --git a/src/main.swift b/src/main.swift
    index 111..222 100644
    --- a/src/main.swift
    +++ b/src/main.swift
    @@ -1,3 +1,4 @@
     let a = 1
    +let b = 2
     let c = 3
     let d = 4
    @@ -10,2 +11,2 @@ func x() {
    -    old()
    +    new()
    diff --git a/old-name.txt b/new-name.txt
    similarity index 90%
    rename from old-name.txt
    rename to new-name.txt
    diff --git a/logo.png b/logo.png
    index 333..444 100644
    Binary files a/logo.png and b/logo.png differ
    diff --git a/added.txt b/added.txt
    new file mode 100644
    --- /dev/null
    +++ b/added.txt
    @@ -0,0 +1,1 @@
    +fresh
    """

    @Test func parsesFilesHunksAndKinds() {
        let files = DiffParser.files(fromUnified: Self.multiHunk)
        #expect(files.count == 4)

        let main = files[0]
        #expect(main.path == "src/main.swift")
        #expect(main.change == .modified)
        #expect(main.hunks.count == 2)
        #expect(main.additions == 2)
        #expect(main.deletions == 1)
        // Line numbering: the addition in hunk 1 is new line 2.
        let addition = main.hunks[0].lines.first { $0.kind == .addition }
        #expect(addition?.newNumber == 2)
        #expect(addition?.oldNumber == nil)

        let renamed = files[1]
        #expect(renamed.change == .renamed)
        #expect(renamed.oldPath == "old-name.txt")
        #expect(renamed.path == "new-name.txt")

        let binary = files[2]
        #expect(binary.hunks.isEmpty)

        let added = files[3]
        #expect(added.change == .added)
        #expect(added.additions == 1)
    }

    @Test func numstatWithBinaryRows() {
        let stats = DiffParser.stats(fromNumstat: "10\t2\ta.swift\n-\t-\tlogo.png\n")
        #expect(stats.filesChanged == 2)
        #expect(stats.insertions == 10)
        #expect(stats.deletions == 2)
    }

    @Test func overlapPaths() {
        let paths = DiffParser.paths(fromNameOnly: "a.swift\nb/c.swift\n")
        #expect(paths == ["a.swift", "b/c.swift"])
    }
}

@Suite struct GitHubParsingTests {
    @Test func prStatusRollup() throws {
        let status = try GitHubService.parsePRStatus("""
        {"state": "OPEN", "mergeable": "MERGEABLE",
         "reviewDecision": "APPROVED",
         "statusCheckRollup": [
           {"status": "COMPLETED", "conclusion": "SUCCESS"},
           {"status": "COMPLETED", "conclusion": "FAILURE"},
           {"status": "IN_PROGRESS", "conclusion": null},
           {"state": "SUCCESS"}
         ]}
        """)
        #expect(status.state == "OPEN")
        #expect(status.checks == .init(passed: 2, failed: 1, pending: 1))
        #expect(status.reviewDecision == "APPROVED")
    }

    @Test func malformedJSONThrows() {
        #expect(throws: GitHubService.ServiceError.self) {
            _ = try GitHubService.parsePRStatus("not json")
        }
    }
}
