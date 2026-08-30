import Foundation

/// Host-environment helpers: login-shell PATH resolution, binary discovery,
/// and PID liveness with reuse guarding.
public enum HostEnvironment {
    /// Resolves the user's login-shell PATH once (GUI apps inherit a minimal
    /// PATH; toolchains live in Homebrew/nvm paths). Cached by the caller.
    public static func loginShellPATH() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let subprocess = Subprocess(configuration: .init(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-lc", "echo $PATH"]))
        guard let lines = try? await subprocess.start() else { return nil }
        var last: String?
        for await line in lines where !line.isEmpty { last = line }
        _ = await subprocess.waitForExit()
        return last
    }

    /// Finds an executable by searching the given PATH string.
    public static func find(executable name: String, path: String) -> URL? {
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Well-known claude install locations checked before PATH search,
    /// in order: Homebrew (Apple Silicon), npm-global, local installer.
    public static var claudeCandidatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
        ]
    }

    /// True when `pid` is alive AND its executable path contains
    /// `executableHint` — the hint guards against PID reuse.
    public static func isProcessAlive(pid: Int32, executableHint: String) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        return path.contains(executableHint)
    }
}
