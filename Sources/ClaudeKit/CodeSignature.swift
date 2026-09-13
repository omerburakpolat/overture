import Foundation
import ProcessCore

/// Whether the `claude` Overture is about to drive is Anthropic's.
///
/// The honest threat model: anyone who can write to your home folder can
/// already do anything Overture could, so this is no defence against an
/// attacker on your account. It catches the likelier problems — a stale or
/// unrelated `claude` earlier on PATH, or the wrong file picked with Choose… —
/// and gives the path Settings shows a trust signal. It warns and never
/// blocks: a developer build of Claude Code is a legitimate thing to run.
///
/// Shells out to `/usr/bin/codesign` rather than using the Security framework,
/// which keeps `import Security` confined to VercelKit
/// (`RepositoryInvariantTests`); a designated-requirement check is exactly
/// what `codesign` does.
public enum CodeSignature {
    public enum Status: Sendable, Equatable {
        /// Signed with Anthropic's Developer ID.
        case anthropic
        /// Validly signed, by someone else.
        case otherDeveloper
        /// No signature, or one that no longer matches the file.
        case unsignedOrModified
        /// The check itself couldn't run.
        case unverified(String)
    }

    /// `Developer ID Application: Anthropic PBC (Q6L2SF6YDW)` — measured on
    /// the Homebrew binary (docs/specs/06-m0-findings.md, M1 item 18).
    public static let anthropicTeamID = "Q6L2SF6YDW"

    static let requirement =
        #"anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW""#

    /// `codesign --verify -R` exit codes, measured: 0 meets the requirement,
    /// 3 is validly signed but fails it, 1 is unsigned or broken.
    static func status(forExitCode code: Int32) -> Status {
        switch code {
        case 0: .anthropic
        case 3: .otherDeveloper
        case 1: .unsignedOrModified
        default: .unverified("codesign exited \(code)")
        }
    }

    /// Verifies the file a path resolves to (Homebrew's `claude` is a symlink
    /// into the Caskroom). Takes ~0.7 s for the real binary — go through
    /// `CodeSignatureCache` rather than calling this on every probe.
    public static func verify(_ url: URL) async -> Status {
        let target = url.resolvingSymlinksInPath()
        let subprocess = Subprocess(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--strict", "-R=\(requirement)", target.path],
            environment: ["PATH": "/usr/bin:/bin"]))
        guard let lines = try? await subprocess.start() else {
            return .unverified("couldn't run codesign")
        }
        for await _ in lines {}
        switch await subprocess.waitForExit() {
        case .exited(let code): return status(forExitCode: code)
        case .signalled(let signal): return .unverified("codesign stopped by signal \(signal)")
        case .failedToLaunch(let detail): return .unverified(detail)
        }
    }
}

/// Remembers verdicts by file identity — resolved path, size and modification
/// date — so the check runs once per binary instead of on every probe, and
/// again automatically when Homebrew or the native installer replaces it.
public actor CodeSignatureCache {
    public static let shared = CodeSignatureCache()

    private struct Key: Hashable {
        let path: String
        let size: Int
        let modified: Date
    }

    private var verdicts: [Key: CodeSignature.Status] = [:]

    public init() {}

    public func status(for url: URL,
                       verify: @Sendable (URL) async -> CodeSignature.Status)
        async -> CodeSignature.Status {
        let target = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: target.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else {
            return await verify(url)
        }
        let key = Key(path: target.path, size: size, modified: modified)
        if let cached = verdicts[key] { return cached }
        let verdict = await verify(url)
        // A check that couldn't run proves nothing; try again next time.
        if case .unverified = verdict {} else { verdicts[key] = verdict }
        return verdict
    }
}
