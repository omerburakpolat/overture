import Foundation
import ProcessCore

/// Reports credential variables the user's login shell defines but Overture
/// does not see.
///
/// A GUI-launched `.app` inherits launchd's environment, not `.zshrc`. So an
/// `ANTHROPIC_API_KEY` exported from a shell profile is active in the user's
/// terminal and invisible here — `claude` in Terminal and agents in Overture
/// can authenticate as different things, which is confusing and, when it
/// flips a subscription onto metered billing, expensive.
///
/// Overture **detects and reports** that divergence. It deliberately does not
/// import the shell environment:
///
/// - Importing would hold the user's credentials in Overture's own process
///   memory, making `SECURITY.md`'s "never reads … your Claude credentials"
///   false.
/// - It would make agent behaviour depend on a `.zshrc` that can change
///   underneath it; an `ANTHROPIC_BASE_URL` pointed at a proxy would silently
///   reroute every agent.
/// - The divergence is more useful surfaced than papered over.
///
/// Do not "fix" this by inheriting the login shell.
public enum ShellEnvironmentProbe {
    public struct Finding: Sendable, Equatable {
        /// Credential-relevant variables the login shell defines that the
        /// child environment lacks. Names only, always.
        public var names: [EnvVarName]
        /// False when the shell could not be probed — the UI must not claim
        /// "no divergence" on the strength of a failed probe.
        public var probeSucceeded: Bool

        public init(names: [EnvVarName], probeSucceeded: Bool) {
            self.names = names
            self.probeSucceeded = probeSucceeded
        }

        public var hasDivergence: Bool { probeSucceeded && !names.isEmpty }
    }

    /// Runs `env | cut -d= -f1` in a login shell.
    ///
    /// The `cut` runs **in the child**: piping `env` unfiltered would stream
    /// every value in the user's shell through Overture's process, which is
    /// precisely what this design exists to avoid. Only names cross the pipe.
    public static func credentialVariableNames(
        watching watched: [EnvVarName] = ClaudeChildEnvironment.credentialRelevant,
        absentFrom childEnvironment: [String: String],
        timeout: Duration = .seconds(5)
    ) async -> Finding {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let subprocess = Subprocess(configuration: .init(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-lc", "env | cut -d= -f1"]))
        guard let lines = try? await subprocess.start() else {
            return Finding(names: [], probeSucceeded: false)
        }
        let collector = Task { () -> Set<String> in
            var names: Set<String> = []
            for await line in lines {
                names.insert(line.trimmingCharacters(in: .whitespaces))
            }
            return names
        }
        guard let exit = await subprocess.waitForExit(upTo: timeout),
              case .exited(code: 0) = exit else {
            _ = await subprocess.terminate(gracePeriod: .seconds(1))
            collector.cancel()
            return Finding(names: [], probeSucceeded: false)
        }
        let shellNames = await collector.value

        let diverging = watched.filter { name in
            shellNames.contains(name.rawValue)
                && (childEnvironment[name.rawValue] ?? "").isEmpty
        }
        return Finding(names: diverging, probeSucceeded: true)
    }
}
