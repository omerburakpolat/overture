import Foundation

/// Snapshot of a repository's user-visible state. Derived, never persisted.
public struct GitStatus: Sendable, Equatable {
    public var branch: String?
    /// Count of paths with staged or unstaged changes (porcelain v2 rows).
    public var dirtyCount: Int
    public var ahead: Int
    public var behind: Int
    public var hasConflicts: Bool

    public init(branch: String? = nil, dirtyCount: Int = 0,
                ahead: Int = 0, behind: Int = 0, hasConflicts: Bool = false) {
        self.branch = branch
        self.dirtyCount = dirtyCount
        self.ahead = ahead
        self.behind = behind
        self.hasConflicts = hasConflicts
    }

    public var isClean: Bool { dirtyCount == 0 && !hasConflicts }
}

/// One file's diff, parsed from `git diff` output.
public struct DiffFile: Sendable, Equatable, Identifiable {
    public enum Change: String, Sendable {
        case added, deleted, modified, renamed
    }

    public struct Hunk: Sendable, Equatable {
        public enum LineKind: Sendable { case context, addition, deletion }
        public struct Line: Sendable, Equatable {
            public var kind: LineKind
            public var text: String
            public var oldNumber: Int?
            public var newNumber: Int?
            public init(kind: LineKind, text: String,
                        oldNumber: Int?, newNumber: Int?) {
                self.kind = kind
                self.text = text
                self.oldNumber = oldNumber
                self.newNumber = newNumber
            }
        }
        public var header: String
        public var lines: [Line]
        public init(header: String, lines: [Line]) {
            self.header = header
            self.lines = lines
        }
    }

    public var id: String { path }
    public var path: String
    public var oldPath: String?
    public var change: Change
    public var additions: Int
    public var deletions: Int
    public var hunks: [Hunk]

    public init(path: String, oldPath: String? = nil, change: Change,
                additions: Int, deletions: Int, hunks: [Hunk] = []) {
        self.path = path
        self.oldPath = oldPath
        self.change = change
        self.additions = additions
        self.deletions = deletions
        self.hunks = hunks
    }
}

public struct DiffStats: Sendable, Equatable {
    public var filesChanged: Int
    public var insertions: Int
    public var deletions: Int
    public init(filesChanged: Int = 0, insertions: Int = 0, deletions: Int = 0) {
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// A worktree row from `git worktree list --porcelain`.
public struct WorktreeInfo: Sendable, Equatable {
    public var path: String
    public var branch: String?
    public var head: String?
    public init(path: String, branch: String?, head: String?) {
        self.path = path
        self.branch = branch
        self.head = head
    }
}

/// Branch naming per resolution #8: `overture/<slug>-<id8>`.
public enum BranchNaming {
    public static func branchName(cardTitle: String, cardID: UUID) -> String {
        let slug = cardTitle.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, ch in
                if ch == "-" && partial.hasSuffix("-") { return }
                partial.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        let id8 = cardID.uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(8)
        return "overture/\(slug)-\(id8)"
    }
}
