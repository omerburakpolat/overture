import Foundation
import ProcessCore

/// A failed `git` invocation. Carries enough context (arguments, exit code,
/// stderr tail) to render a useful diagnostic without re-running anything.
public struct GitError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// The git executable could not be spawned (missing, not executable).
        case launchFailed(String)
        case exited(code: Int32)
        case signalled(signal: Int32)
    }

    public var kind: Kind
    public var arguments: [String]
    /// Last stderr lines from the child, bounded upstream by `Subprocess`.
    public var stderrTail: [String]

    public init(kind: Kind, arguments: [String], stderrTail: [String]) {
        self.kind = kind
        self.arguments = arguments
        self.stderrTail = stderrTail
    }

    /// Exit code when the process exited normally; nil for launch failures
    /// and signals.
    public var exitCode: Int32? {
        if case .exited(let code) = kind { return code }
        return nil
    }

    public var description: String {
        let cmd = (["git"] + arguments).joined(separator: " ")
        switch kind {
        case .launchFailed(let reason):
            return "`\(cmd)` failed to launch: \(reason)"
        case .exited(let code):
            return "`\(cmd)` exited \(code): \(stderrTail.suffix(3).joined(separator: " | "))"
        case .signalled(let signal):
            return "`\(cmd)` killed by signal \(signal)"
        }
    }
}

/// The one place GitKit shells out to `git`. Every higher-level feature
/// (status, worktrees, diffs, snapshot refs) routes through `run`, so the
/// executable path, environment hardening, and error shape are decided once.
///
/// No libgit2 — spec 02 §5. The system git is authoritative because agents
/// and the user run the same binary against the same repo.
public actor GitRunner {
    public let gitPath: URL

    /// - Parameter gitPath: git executable; `/usr/bin/git` (Xcode CLT shim)
    ///   by default, configurable for Homebrew installs.
    public init(gitPath: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.gitPath = gitPath
    }

    /// Runs `git <args>` with `repo` as cwd and returns stdout (newline
    /// joined, no trailing newline). Throws `GitError` on non-zero exit,
    /// signal, or launch failure.
    ///
    /// Environment hardening: `GIT_TERMINAL_PROMPT=0` so a credential-needing
    /// command fails fast instead of wedging on a hidden prompt (fetch is
    /// never automatic per resolution #18, but push/merge can still want
    /// credentials), and `GIT_OPTIONAL_LOCKS=0` so background status reads
    /// never contend with user-initiated operations for index locks.
    @discardableResult
    public func run(_ args: [String], in repo: URL) async throws -> String {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"

        let subprocess = Subprocess(configuration: .init(
            executable: gitPath,
            arguments: args,
            currentDirectory: repo,
            environment: env))

        let lines: AsyncStream<String>
        do {
            lines = try await subprocess.start()
        } catch {
            throw GitError(kind: .launchFailed(String(describing: error)),
                           arguments: args, stderrTail: [])
        }

        var output: [String] = []
        for await line in lines { output.append(line) }
        let exit = await subprocess.waitForExit()

        switch exit {
        case .exited(code: 0):
            return output.joined(separator: "\n")
        case .exited(let code):
            throw GitError(kind: .exited(code: code), arguments: args,
                           stderrTail: await subprocess.stderrSnapshot())
        case .signalled(let signal):
            throw GitError(kind: .signalled(signal: signal), arguments: args,
                           stderrTail: await subprocess.stderrSnapshot())
        case .failedToLaunch(let reason):
            throw GitError(kind: .launchFailed(reason), arguments: args,
                           stderrTail: [])
        }
    }
}
