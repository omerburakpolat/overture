import Foundation

/// Parses the CLI's `--version` output. Overture enforces a tested
/// minimum and warns (never blocks) on anything newer (spec 01 §7.1).
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts "2.1.231 (Claude Code)" and bare "2.1.231".
    public init?(parsing string: String) {
        let pattern = /(\d+)\.(\d+)\.(\d+)/
        guard let match = string.firstMatch(of: pattern),
              let major = Int(match.1), let minor = Int(match.2),
              let patch = Int(match.3) else { return nil }
        self.init(major, minor, patch)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
